import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import StudioCore

/// The Quick Edit presets. Each one is a sentence the model understands and a
/// promise about what may change: only the selected region, only through the
/// worker's alpha.
enum AIQuickPreset: String, CaseIterable, Identifiable, Codable {
    case removeObject
    case healArea
    case reimagine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .removeObject: return L10n.current.aiRemoveObject
        case .healArea: return L10n.current.aiHealArea
        case .reimagine: return L10n.current.aiReimagine
        }
    }

    var instruction: String {
        switch self {
        case .removeObject: return L10n.current.aiRemoveObjectHelp
        case .healArea: return L10n.current.aiHealAreaHelp
        case .reimagine: return L10n.current.aiReimagineHelp
        }
    }

    /// Which worker path this preset is allowed to use. A small hole is texture
    /// continuation, which the licensed inpaint model does in under a second; a
    /// semantic removal needs the generative model.
    var engine: String {
        switch self {
        case .removeObject, .reimagine: return "patch"
        case .healArea: return "inpaint"
        }
    }

    /// Reimagine redraws the whole frame from the prompt, so it needs no mask
    /// or point. The other two act only on what the owner marks.
    var isFullFrame: Bool { self == .reimagine }

    var needsSelection: Bool { !isFullFrame }

    var prompt: String {
        switch self {
        case .removeObject:
            return "Remove the selected object completely and continue the background behind it: "
                + "same lighting, same texture, same perspective, photorealistic, seamless"
        case .healArea:
            return "Continue the surrounding texture and lighting over the selected area: "
                + "photorealistic, seamless"
        case .reimagine:
            return "Reimagine this photograph with the requested change, keeping the subject "
                + "recognisable: same framing, same lighting, photorealistic"
        }
    }
}

/// Progress the sheet shows. A job is one at a time and never pretends to be
/// instant: the fastest measured masked patch is about 24 s on an idle M3.
enum QuickEditStage: Equatable {
    case idle
    case preparing
    case starting
    case denoising(step: Int)
    case finished(seconds: Double)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .preparing, .starting, .denoising: return true
        case .idle, .finished, .failed: return false
        }
    }

    var text: String { L10n.current.quickEditStatus(self) }
}

/// Runs one Quick Edit as a blocking call on a background queue.
///
/// Everything it produces is a file: the worker writes the edited pixels and
/// their alpha into its own job folder, and `AIEditStore` copies both into the
/// edit's folder before the document learns about the edit. A failure leaves no
/// half-edit behind.
enum QuickEditRunner {

    /// How long a job may take before the app gives up. The measured worst case
    /// for a patch on this machine is ~47 s on a loaded one; a cold model load
    /// adds a few seconds. This is a guard against a wedged helper, not a budget.
    static let timeout: TimeInterval = 300

    static func run(image: CGImage, point: CGPoint?, mask: AIMaskSelection,
                    crop: CGRect?, preset: AIQuickPreset, prompt: String, seed: Int,
                    fullFrame: Bool = false,
                    dilate: Int = 4, feather: Int = 2,
                    onJob: (String) -> Void = { _ in },
                    progress: @escaping (Int) -> Void) throws -> AIEdit {
        try AIWorker.ensureRunning()
        let copy = try AIWorker.writeWorkingCopy(image)
        defer { try? FileManager.default.removeItem(at: copy.url.deletingLastPathComponent()) }

        var params: [String: Any] = [
            "image": ["path": copy.url.path],
            "prompt": prompt,
            "patch": 512,
            "context": 0.25,
            "steps": 4,
            "seed": seed,
            "engine": preset.engine,
            "dilate": dilate,
            "feather": feather,
        ]
        if fullFrame {
            // The helper draws the whole frame from the prompt and ignores a
            // mask entirely; asking for it explicitly is what makes a large
            // masked edit and a deliberate reimagine different requests.
            params["full_frame"] = true
        } else if mask.hasContent {
            guard let plane = AIMaskRenderer.mask(
                size: copy.size, strokes: mask.strokes, box: mask.box,
                refined: mask.refined, inverted: mask.inverted) else {
                throw AIWorkerFailure(code: -32000, message: L10n.current.aiBadReply)
            }
            params["mask"] = ["path": try writeMask(plane, beside: copy.url).path]
        } else if let point {
            params["points"] = [[min(max(0, point.x), 1) * copy.size.width,
                                 min(max(0, point.y), 1) * copy.size.height]]
        } else {
            throw AIWorkerFailure(code: -32002, message: L10n.current.aiSelectHint)
        }

        let model: AIModelID = preset.engine == "patch" ? .flux : .migan
        var used = false
        ModelActivity.shared.begin(model)
        defer { ModelActivity.shared.finish(model, used: used) }

        let id = try WorkerClient.shared.submit("patch_edit", params)
        onJob(id)
        let started = Date()
        let reply = try WorkerClient.shared.wait(job: id, timeout: timeout,
                                                 progress: { step, _ in progress(step) })
        used = true
        let seconds = Date().timeIntervalSince(started)

        guard let payload = reply["result"] as? [String: Any] else {
            throw AIWorkerFailure(code: -32603, message: L10n.current.aiBadReply)
        }
        let mode = payload["mode"] as? String

        // A whole-frame render replaces the picture on purpose. It arrives as
        // one opaque layer over the working frame, so undo and export use the
        // same layer machinery as every other edit.
        if mode == "full-frame" {
            guard let outputPath = payload["output"] as? String else {
                throw AIWorkerFailure(code: -32603, message: L10n.current.aiBadReply)
            }
            // The worker redrew the whole original, so the layer covers the
            // whole original. The compositor maps that box through any crop,
            // which keeps the visible window aligned with what was generated.
            let editID = UUID()
            let files = try AIEditStore.adopt(
                id: editID,
                patch: URL(fileURLWithPath: outputPath),
                alpha: try writeOpaqueAlpha(size: copy.size, beside: copy.url))
            return AIEdit(id: editID,
                          preset: preset.rawValue,
                          prompt: prompt,
                          seed: seed,
                          patchFile: files.patch,
                          alphaFile: files.alpha,
                          box: CGRect(x: 0, y: 0, width: 1, height: 1),
                          imagePixels: copy.size,
                          seconds: seconds,
                          outsidePixelsIdentical: false)
        }

        guard mode == "patch",
              let box = payload["box"] as? [Int], box.count == 4,
              let size = payload["image_size"] as? [Int], size.count == 2,
              let patchPath = payload["patch"] as? String,
              let alphaPath = payload["alpha"] as? String else {
            // A masked edit the helper routed to a whole-frame render is not
            // what this sheet promised, so it says so instead of replacing the
            // picture. Reimagine asks for that path explicitly above.
            if mode == "full-frame" {
                throw AIWorkerFailure(code: -32002, message: L10n.current.aiTooLarge)
            }
            throw AIWorkerFailure(code: -32603, message: L10n.current.aiBadReply)
        }

        let width = max(1, size[0])
        let height = max(1, size[1])
        // The worker measured against the working copy, which may be cropped.
        // The edit is stored against the whole photo so a later crop can still
        // place it, exactly like a healing stamp.
        let frame = crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let working = CGRect(x: CGFloat(box[0]) / CGFloat(width),
                             y: CGFloat(box[1]) / CGFloat(height),
                             width: CGFloat(box[2] - box[0]) / CGFloat(width),
                             height: CGFloat(box[3] - box[1]) / CGFloat(height))
        let editID = UUID()
        let files = try AIEditStore.adopt(id: editID,
                                          patch: URL(fileURLWithPath: patchPath),
                                          alpha: URL(fileURLWithPath: alphaPath))
        return AIEdit(id: editID,
                      preset: preset.rawValue,
                      prompt: prompt,
                      seed: seed,
                      patchFile: files.patch,
                      alphaFile: files.alpha,
                      box: CGRect(x: frame.minX + working.minX * frame.width,
                                  y: frame.minY + working.minY * frame.height,
                                  width: working.width * frame.width,
                                  height: working.height * frame.height),
                      imagePixels: CGSize(width: width, height: height),
                      seconds: seconds,
                      outsidePixelsIdentical: (payload["outside_pixels_identical"] as? Bool) ?? false)
    }

    /// Asks SAM to turn a box into an edge-following mask. The reply is already
    /// at working resolution, so it can be shown and later sent back as-is.
    static func samMask(image: CGImage, box: CGRect) throws -> CGImage {
        try AIWorker.ensureRunning()
        let copy = try AIWorker.writeWorkingCopy(image)
        defer { try? FileManager.default.removeItem(at: copy.url.deletingLastPathComponent()) }

        let x0 = min(max(0, box.minX), 1) * copy.size.width
        let y0 = min(max(0, box.minY), 1) * copy.size.height
        let x1 = min(max(x0 + 1, box.maxX * copy.size.width), copy.size.width)
        let y1 = min(max(y0 + 1, box.maxY * copy.size.height), copy.size.height)
        var used = false
        ModelActivity.shared.begin(.sam)
        defer { ModelActivity.shared.finish(.sam, used: used) }
        let id = try WorkerClient.shared.submit("mask", [
            "image": ["path": copy.url.path],
            "box": [x0, y0, x1, y1],
        ])
        let reply = try WorkerClient.shared.wait(job: id, timeout: 120)
        used = true
        guard let payload = reply["result"] as? [String: Any],
              let path = payload["mask"] as? String,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let mask = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AIWorkerFailure(code: -32603, message: L10n.current.aiBadReply)
        }
        return mask
    }

    private static func writeMask(_ mask: CGImage, beside copy: URL) throws -> URL {
        try writePNG(mask, to: copy.deletingLastPathComponent().appendingPathComponent("mask.png"))
    }

    /// A whole-frame render has no mask of its own; the editor still needs an
    /// alpha layer beside the patch, so it gets one that covers every pixel.
    private static func writeOpaqueAlpha(size: CGSize, beside copy: URL) throws -> URL {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw AIWorkerFailure(code: -32000, message: L10n.current.aiMaskFailed)
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let alpha = context.makeImage() else {
            throw AIWorkerFailure(code: -32000, message: L10n.current.aiMaskFailed)
        }
        return try writePNG(alpha, to: copy.deletingLastPathComponent()
            .appendingPathComponent("alpha.png"))
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws -> URL {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw AIWorkerFailure(code: -32000, message: L10n.current.aiMaskFailed)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AIWorkerFailure(code: -32000, message: L10n.current.aiMaskFailed)
        }
        return url
    }
}

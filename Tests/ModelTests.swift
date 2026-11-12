import AppKit
import CoreGraphics
import CoreImage
import Dispatch
import Foundation
import StudioCore
import UniformTypeIdentifiers

// Model-level regressions. These drive the real `EditorModel` through the same
// load and export paths the UI uses; only the panels are skipped. Every check
// here corresponds to a P0/P1 finding in Docs/TECHNICAL_AUDIT.md.

@MainActor var failures: [String] = []

@MainActor
func check(_ condition: Bool, _ label: String, _ detail: String = "") {
    if condition {
        print("  ✓ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    } else {
        print("  ✗ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        failures.append(label)
    }
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let workDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("retouch-modeltests-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

// Every recovery write in this process goes to one scratch directory, including
// the delayed autosave tasks a model leaves behind. The override is set before
// the first model exists and is never changed again, so a task cannot follow a
// later test into a different directory. The production copy is only read for
// a fingerprint; the isolation test at the end proves it stayed byte-identical.
let recoveryRoot = workDir.appendingPathComponent("recovery", isDirectory: true)
try? FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
let productionRecoveryBefore = RecoveryFingerprint.capture(RecoveryStore.productionDirectory)
RecoveryStore.directoryOverride = recoveryRoot
// AI edit pixels also live in Application Support in production. Redirect
// every adoption in this suite to the same scratch tree so the real store is
// never touched, even by a test that crashes before its cleanup runs.
AIEditStore.rootOverride = workDir.appendingPathComponent("ai-edits", isDirectory: true)

/// Suspends the MainActor task so the model's own load/export tasks can run.
@MainActor
func waitUntil(_ timeout: TimeInterval = 60, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

func makeImage(width: Int, height: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let w = CGFloat(width), h = CGFloat(height)
    ctx.setFillColor(CGColor(srgbRed: 0.72, green: 0.60, blue: 0.52, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(srgbRed: 0.84, green: 0.70, blue: 0.62, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: w * 0.24, y: h * 0.18, width: w * 0.52, height: h * 0.62))
    ctx.setFillColor(CGColor(srgbRed: 0.30, green: 0.22, blue: 0.20, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: w * 0.36, y: h * 0.55, width: w * 0.08, height: h * 0.04))
    ctx.fillEllipse(in: CGRect(x: w * 0.56, y: h * 0.55, width: w * 0.08, height: h * 0.04))
    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                     UTType.png.identifier as CFString,
                                                     1, nil) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

@MainActor
func removeRecentEntries(under directory: URL) {
    for entry in RecentStore.shared.entries where entry.path.hasPrefix(directory.path) {
        RecentStore.shared.remove(entry)
    }
}

/// A counter the batch's file task and the main-actor test can share.
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

// MARK: - P0-1 / C-1

@MainActor
func testExportDoesNotSave() async {
    print("\n[P0-1] an export is a copy, not a saved project")

    let sourceURL = workDir.appendingPathComponent("source.png")
    check(makeImage(width: 480, height: 600).map { writePNG($0, to: sourceURL) } ?? false,
          "fixture written")

    let model = EditorModel()
    model.load(url: sourceURL)
    check(await waitUntil { model.hasImage && !model.isBusy }, "fixture loads")

    model.adjustments.smooth = 40
    check(model.hasUnsavedChanges, "an edit marks the document dirty")

    let firstExport = workDir.appendingPathComponent("first.png")
    model.export(to: firstExport)
    let firstDone = await waitUntil(120) {
        FileManager.default.fileExists(atPath: firstExport.path) && !model.isBusy
    }
    check(firstDone, "export finishes")
    check(model.hasUnsavedChanges, "export leaves the document dirty")

    // A document that was already clean must stay clean: the fix must not
    // invent a dirty flag where there is no unsaved work.
    model.discardUnsavedChanges()
    check(!model.hasUnsavedChanges, "clean baseline is restored")

    let secondExport = workDir.appendingPathComponent("second.png")
    model.export(to: secondExport)
    _ = await waitUntil(120) {
        FileManager.default.fileExists(atPath: secondExport.path) && !model.isBusy
    }
    check(!model.hasUnsavedChanges, "exporting a clean document stays clean")

    // A failed write must not touch the clean baseline either.
    model.adjustments.contrast = 25
    let dirtyBeforeFailure = model.hasUnsavedChanges
    model.export(to: workDir.appendingPathComponent("missing/never.png"))
    _ = await waitUntil(120) { !model.isBusy }
    check(model.hasUnsavedChanges == dirtyBeforeFailure,
          "a failed export leaves the dirty flag unchanged")
}

// MARK: - P0-2 / H-1

/// Every retouch slider carries a distinct sentinel so a cleared field is
/// unmistakable in the comparison.
func sentinelAdjustments() -> Adjustments {
    var a = Adjustments()
    a.smooth = 11; a.blemish = 12; a.wrinkle = 13; a.skinToneEvens = 14
    a.darkCircles = 15; a.skinBrighten = 16; a.texturePreserve = 17
    a.teethWhiten = 18; a.eyeBrighten = 19; a.eyeSharpen = 20
    a.skinFinish = 21; a.shine = 22; a.irisEnhance = 23; a.lashDarken = 24
    a.lensTint = 25; a.teethAlign = 26
    a.exposure = 31; a.contrast = 32; a.blacks = 33; a.whites = 34
    a.saturation = 35; a.vibrance = 36; a.warmth = 37; a.clarity = 38
    a.vignette = 39; a.splitTone = 40
    a.curveShadows = 41; a.curveMidtones = 42; a.curveHighlights = 43
    a.hslHue = Array(repeating: 44, count: HSLBand.allCases.count)
    a.hslSaturation = Array(repeating: 45, count: HSLBand.allCases.count)
    a.hslLuminance = Array(repeating: 46, count: HSLBand.allCases.count)
    a.lipTint = 51; a.blush = 52; a.browDefine = 53
    a.eyeSize = 61; a.noseSize = 62; a.lipSize = 63
    a.bodySmooth = 71; a.bodySlim = 72
    a.backgroundBlur = 81; a.backgroundTone = 82
    a.hairColor = 91; a.hairShine = 92; a.hairVolume = 93
    a.lookStrength = 95; a.grain = 96
    return a
}

func changedRetouchFields(_ before: Adjustments, _ after: Adjustments) -> Adjustments.RetouchField {
    var fields: Adjustments.RetouchField = []
    if before.smooth != after.smooth { fields.insert(.smooth) }
    if before.blemish != after.blemish { fields.insert(.blemish) }
    if before.wrinkle != after.wrinkle { fields.insert(.wrinkle) }
    if before.skinToneEvens != after.skinToneEvens { fields.insert(.skinToneEvens) }
    if before.darkCircles != after.darkCircles { fields.insert(.darkCircles) }
    if before.skinBrighten != after.skinBrighten { fields.insert(.skinBrighten) }
    if before.texturePreserve != after.texturePreserve { fields.insert(.texturePreserve) }
    if before.teethWhiten != after.teethWhiten { fields.insert(.teethWhiten) }
    if before.eyeBrighten != after.eyeBrighten { fields.insert(.eyeBrighten) }
    if before.eyeSharpen != after.eyeSharpen { fields.insert(.eyeSharpen) }
    if before.skinFinish != after.skinFinish { fields.insert(.skinFinish) }
    if before.shine != after.shine { fields.insert(.shine) }
    if before.irisEnhance != after.irisEnhance { fields.insert(.irisEnhance) }
    if before.lashDarken != after.lashDarken { fields.insert(.lashDarken) }
    if before.lensTint != after.lensTint { fields.insert(.lensTint) }
    if before.lensColor != after.lensColor { fields.insert(.lensColor) }
    if before.teethAlign != after.teethAlign { fields.insert(.teethAlign) }
    return fields
}

func changedColorFields(_ before: Adjustments, _ after: Adjustments) -> Adjustments.ColorField {
    var fields: Adjustments.ColorField = []
    if before.exposure != after.exposure { fields.insert(.exposure) }
    if before.contrast != after.contrast { fields.insert(.contrast) }
    if before.blacks != after.blacks { fields.insert(.blacks) }
    if before.whites != after.whites { fields.insert(.whites) }
    if before.saturation != after.saturation { fields.insert(.saturation) }
    if before.vibrance != after.vibrance { fields.insert(.vibrance) }
    if before.warmth != after.warmth { fields.insert(.warmth) }
    if before.clarity != after.clarity { fields.insert(.clarity) }
    if before.vignette != after.vignette { fields.insert(.vignette) }
    if before.splitTone != after.splitTone { fields.insert(.splitTone) }
    if before.curveShadows != after.curveShadows { fields.insert(.curveShadows) }
    if before.curveMidtones != after.curveMidtones { fields.insert(.curveMidtones) }
    if before.curveHighlights != after.curveHighlights { fields.insert(.curveHighlights) }
    if before.hslHue != after.hslHue { fields.insert(.hslHue) }
    if before.hslSaturation != after.hslSaturation { fields.insert(.hslSaturation) }
    if before.hslLuminance != after.hslLuminance { fields.insert(.hslLuminance) }
    return fields
}

func makeFadedImage(width: Int, height: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(srgbRed: 0.47, green: 0.47, blue: 0.47, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(srgbRed: 0.56, green: 0.55, blue: 0.54, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: 20, y: 20, width: CGFloat(width) - 40,
                               height: CGFloat(height) - 40))
    ctx.setFillColor(CGColor(srgbRed: 0.36, green: 0.35, blue: 0.34, alpha: 1))
    ctx.fill(CGRect(x: 0, y: CGFloat(height) * 0.4, width: CGFloat(width) * 0.3, height: 12))
    return ctx.makeImage()
}

@MainActor
func testSmartKeepsUnmeasuredFields() async {
    print("\n[P0-2] Smart Analyze only writes what it measured")

    let base = sentinelAdjustments()
    let zero = Adjustments()

    let retouchApplied = base.applyingRetouch(zero, fields: .smart)
    let retouchChanged = changedRetouchFields(base, retouchApplied)
    check(retouchChanged.isSubset(of: .smart),
          "retouch apply leaves the owner's other fields alone",
          "changed \(retouchChanged.rawValue & ~Adjustments.RetouchField.smart.rawValue) outside")
    for (label, untouched) in [
        ("skin finish", retouchApplied.skinFinish == base.skinFinish),
        ("lens tint", retouchApplied.lensTint == base.lensTint),
        ("lens colour", retouchApplied.lensColor == base.lensColor),
        ("teeth align", retouchApplied.teethAlign == base.teethAlign),
        ("iris enhance", retouchApplied.irisEnhance == base.irisEnhance),
        ("lash darken", retouchApplied.lashDarken == base.lashDarken),
    ] {
        check(untouched, "\(label) survives a Smart apply")
    }
    check(retouchApplied.smooth == 0 && retouchApplied.blemish == 0,
          "a measured zero is still applied")

    let colorApplied = base.applyingColorLight(zero, fields: .autoColorLight)
    let colorChanged = changedColorFields(base, colorApplied)
    check(colorChanged.isSubset(of: .autoColorLight),
          "color apply leaves vignette, curves, split tone and HSL alone",
          "changed \(colorChanged.rawValue & ~Adjustments.ColorField.autoColorLight.rawValue) outside")

    // The field sets must track what the analyzers actually produce.
    let findings: [SmartAnalyzer.Finding] = [
        .init(kind: .texture, severity: 1, detail: .texturePronounced),
        .init(kind: .blemish, severity: 1, detail: .spots(4)),
        .init(kind: .wrinkles, severity: 1, detail: .linesHeavy),
        .init(kind: .darkCircles, severity: 1, detail: .underEyeStrong),
        .init(kind: .shine, severity: 1, detail: .shineHeavy),
        .init(kind: .unevenTone, severity: 1, detail: .tonePatchy),
        .init(kind: .teeth, severity: 1, detail: .teethWarm),
        .init(kind: .eyes, severity: 1, detail: .eyesDim),
    ]
    let retouchPatch = SmartAnalyzer.retouchValues(findings: findings, hasEyes: true,
                                                   scleraLevel: 0.4, skinMedian: 0.40)
    let producedRetouch = changedRetouchFields(Adjustments(), retouchPatch)
    check(!producedRetouch.isEmpty && producedRetouch.isSubset(of: .smart),
          "retouchValues stays inside the smart field set",
          "produced \(producedRetouch.rawValue)")

    if let cg = makeFadedImage(width: 320, height: 240), let buffer = PixelBuffer(cgImage: cg) {
        let colorPatch = AutoAnalyzer.autoColorLight(buffer)
        let producedColor = changedColorFields(Adjustments(), colorPatch)
        check(!producedColor.isEmpty, "the faded fixture actually asks for a correction")
        check(producedColor.isSubset(of: .autoColorLight),
              "autoColorLight stays inside its field set",
              "produced \(producedColor.rawValue)")
    } else {
        check(false, "faded fixture for the color coverage test")
    }
}

// MARK: - P0-3 / H-2

@MainActor
func testResetAllClearsEverything() async {
    print("\n[P0-3] Reset All clears the whole document in one step")

    let sourceURL = workDir.appendingPathComponent("source.png")
    let model = EditorModel()
    model.load(url: sourceURL)
    check(await waitUntil { model.hasImage && !model.isBusy }, "fixture reloads")

    model.adjustments.smooth = 30
    model.tapHeal(at: CGPoint(x: 0.5, y: 0.5))
    model.tapArt(at: CGPoint(x: 0.3, y: 0.3))
    check(await waitUntil { !model.isBusy }, "the stamp preview settles")
    model.cropDraft = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    model.applyCrop()
    check(await waitUntil { !model.isBusy && model.appliedCrop != nil }, "a crop joins the edit")
    // Pins are placed after the crop: applying a crop clears the old endpoints,
    // so a pin set before it would not be part of the document being reset.
    model.analysis.isEnabled = true
    model.analysis.setEndpoint(CGPoint(x: 0.9, y: 0.9), for: .lips)
    check(!model.isDocumentPristine, "a document with every kind of edit is not pristine")

    model.resetAll()
    check(model.adjustments.isIdentity, "sliders are back to zero")
    check(model.healSpots.isEmpty, "heal stamps are gone")
    check(model.stickers.isEmpty, "stickers are gone")
    check(model.analysis == AnalysisSettings(), "analysis overlay is back to default")
    check(model.appliedCrop == nil, "the crop is back to the original framing")
    check(model.isDocumentPristine, "the document reads as pristine")
    check(await waitUntil { !model.isBusy }, "the uncropped pixels finish loading")

    model.undo()
    check(model.adjustments.smooth == 30, "one undo restores the slider")
    check(model.healSpots.count == 1, "one undo restores the stamp")
    check(model.stickers.count == 1, "one undo restores the sticker")
    check(model.analysis.isEnabled && !model.analysis.endpoints.isEmpty,
          "one undo restores the analysis pins")
    check(model.appliedCrop != nil, "one undo restores the crop")
    check(await waitUntil { !model.isBusy }, "the restored crop finishes re-reading")
}

// MARK: - P1-1 / H-3

func readImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// Mean absolute channel difference in 0…255, the same scale a 1/255
/// acceptance threshold is written in.
func meanDelta(_ aURL: URL, _ bURL: URL) -> Double? {
    guard let a = readImage(aURL), let b = readImage(bURL),
          a.width == b.width, a.height == b.height else { return nil }

    func bytes(_ image: CGImage) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let ctx = CGContext(data: &data, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    guard let da = bytes(a), let db = bytes(b) else { return nil }
    var sum = 0.0
    for offset in stride(from: 0, to: da.count, by: 4) {
        for channel in 0..<3 {
            sum += abs(Double(da[offset + channel]) - Double(db[offset + channel]))
        }
    }
    return sum / Double((da.count / 4) * 3)
}

/// How many pixels differ by more than `threshold` on any channel. A small
/// sticker barely moves a whole-image mean, but it is unmistakable per pixel.
func changedPixels(_ aURL: URL, _ bURL: URL, threshold: Int = 8) -> Int? {
    guard let a = readImage(aURL), let b = readImage(bURL),
          a.width == b.width, a.height == b.height else { return nil }

    func bytes(_ image: CGImage) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let ctx = CGContext(data: &data, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    guard let da = bytes(a), let db = bytes(b) else { return nil }
    var count = 0
    for offset in stride(from: 0, to: da.count, by: 4) {
        for channel in 0..<3 where abs(Int(da[offset + channel]) - Int(db[offset + channel])) > threshold {
            count += 1
            break
        }
    }
    return count
}

// MARK: - P0-4

@MainActor
func testBatchExportPolicy() {
    print("\n[P0-4] a batch file keeps only the shared export settings")

    let documentURL = workDir.appendingPathComponent("policy-doc.png")
    let otherURL = workDir.appendingPathComponent("policy-other.png")
    let differentURL = workDir.appendingPathComponent("policy-wide.png")

    var analysis = AnalysisSettings()
    analysis.isEnabled = true
    analysis.regions = [.forehead, .texture]
    analysis.exportMode = .poster
    analysis.setEndpoint(CGPoint(x: 0.21, y: 0.32), for: .forehead)
    analysis.setAnchor(CGPoint(x: 0.42, y: 0.55), for: .forehead)

    var base = ExportSnapshot()
    base.adjustments.contrast = 30
    base.healSpots = [HealSpot(center: CGPoint(x: 0.5, y: 0.5), radius: 0.02)]
    base.stickers = [Sticker(center: CGPoint(x: 0.2, y: 0.2), size: 0.1)]
    base.aiEdits = [AIEdit(preset: "test", prompt: "p", seed: 1,
                           patchFile: "patch.png", alphaFile: "alpha.png",
                           box: CGRect(x: 0, y: 0, width: 1, height: 1),
                           imagePixels: CGSize(width: 10, height: 10))]
    base.analysis = analysis
    base.crop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    base.orientation = DocumentOrientation(quarterTurns: 1)
    base.selectedFaceIndex = 1
    base.format = .png
    base.quality = 0.8
    base.longEdge = 2048
    base.stripsPrivacyMetadata = true
    base.includeStamps = true
    base.includeAnalysis = true
    base.aiUpscale = true
    base.watermark = WatermarkSettings(enabled: true, text: "Studio")

    let document = BatchExportPolicy.snapshot(
        base, fileURL: documentURL, documentURL: documentURL,
        documentAspect: 4.0 / 3.0, fileAspect: 4.0 / 3.0)
    check(document.selectedFaceIndex == 1
            && document.analysis.endpoint(for: .forehead) != nil
            && document.analysis.anchor(for: .forehead) != nil
            && document.crop != nil && document.orientation.quarterTurns == 1
            && !document.aiEdits.isEmpty,
          "the open document keeps its own selection, pins and crop")

    let sameAspect = BatchExportPolicy.snapshot(
        base, fileURL: otherURL, documentURL: documentURL,
        documentAspect: 4.0 / 3.0, fileAspect: 4.0 / 3.0)
    check(sameAspect.selectedFaceIndex == nil && sameAspect.analysis.endpoints.isEmpty
            && sameAspect.analysis.anchors.isEmpty && sameAspect.aiEdits.isEmpty
            && sameAspect.orientation.isIdentity,
          "another same-shape file gets automatic focus and callouts")
    check(sameAspect.crop == nil,
          "a turned document's crop does not leak into another photo")

    var unrotatedBase = base
    unrotatedBase.orientation = .identity
    let unrotatedSameAspect = BatchExportPolicy.snapshot(
        unrotatedBase, fileURL: otherURL, documentURL: documentURL,
        documentAspect: 4.0 / 3.0, fileAspect: 4.0 / 3.0)
    check(unrotatedSameAspect.crop == unrotatedBase.crop,
          "an unturned document's crop travels to a same-shape file")
    check(sameAspect.adjustments == base.adjustments && sameAspect.format == base.format
            && sameAspect.quality == base.quality && sameAspect.longEdge == base.longEdge
            && sameAspect.stripsPrivacyMetadata == base.stripsPrivacyMetadata
            && sameAspect.watermark == base.watermark && sameAspect.aiUpscale == base.aiUpscale
            && sameAspect.includeStamps == base.includeStamps
            && sameAspect.includeAnalysis == base.includeAnalysis,
          "shared look, format and privacy settings are unchanged")
    check(sameAspect.analysis.isEnabled && sameAspect.analysis.exportMode == .poster
            && sameAspect.analysis.regions == base.analysis.regions,
          "the analysis style stays shared, only the pins are cleared")

    let differentAspect = BatchExportPolicy.snapshot(
        base, fileURL: differentURL, documentURL: documentURL,
        documentAspect: 4.0 / 3.0, fileAspect: 1.0)
    check(differentAspect.crop == nil, "a different-shape file exports whole")

    // The policy has no face count input: every file that is not the open
    // document gets automatic focus, which `sameAspect` above already covers.

    // The renderer guards an out-of-range index; the policy must not leak it.
    var invalid = base
    invalid.selectedFaceIndex = 99
    let invalidDocument = BatchExportPolicy.snapshot(
        invalid, fileURL: documentURL, documentURL: documentURL,
        documentAspect: 4.0 / 3.0, fileAspect: 4.0 / 3.0)
    let invalidOther = BatchExportPolicy.snapshot(
        invalid, fileURL: otherURL, documentURL: documentURL,
        documentAspect: 4.0 / 3.0, fileAspect: 4.0 / 3.0)
    check(invalidDocument.selectedFaceIndex == 99 && invalidOther.selectedFaceIndex == nil,
          "an out-of-range selection stays with the document and never leaks")
}

@MainActor
func testBatchMatchesSingleExport() async {
    print("\n[P1-1] batch export equals a single export and respects each file's shape")

    let docURL = workDir.appendingPathComponent("batch-doc.png")
    let sameURL = workDir.appendingPathComponent("batch-same.png")
    let squareURL = workDir.appendingPathComponent("batch-square.png")
    guard let docImage = makeImage(width: 800, height: 600),
          let squareImage = makeImage(width: 600, height: 600) else {
        check(false, "batch fixtures")
        return
    }
    check(writePNG(docImage, to: docURL) && writePNG(docImage, to: sameURL)
          && writePNG(squareImage, to: squareURL), "fixtures written")

    let brokenURL = workDir.appendingPathComponent("batch-broken.txt")
    try? "not a photo".write(to: brokenURL, atomically: true, encoding: .utf8)

    let model = EditorModel()
    model.load(url: docURL)
    check(await waitUntil { model.hasImage && !model.isBusy }, "document loads")

    model.cropDraft = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    model.applyCrop()
    check(await waitUntil { !model.isBusy && model.appliedCrop != nil }, "crop applies")

    model.adjustments.contrast = 30
    model.adjustments.exposure = 8
    model.tapHeal(at: CGPoint(x: 0.5, y: 0.5))
    model.tapArt(at: CGPoint(x: 0.3, y: 0.3))
    model.exportFormat = .png

    let singleURL = workDir.appendingPathComponent("batch-single.png")
    model.export(to: singleURL)
    check(await waitUntil(120) {
        FileManager.default.fileExists(atPath: singleURL.path) && !model.isBusy
    }, "single export finishes")

    let folder = workDir.appendingPathComponent("batch-out")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    model.batchIncludeStamps = true
    model.batchIncludeAnalysis = true
    model.runBatch([sameURL, squareURL, brokenURL], to: folder)
    check(await waitUntil(180) { !model.isBatchRunning && model.batchHasReport },
          "batch finishes")

    check(model.batchTotal == 3, "batch reports all three files", "total \(model.batchTotal)")
    check(model.batchSavedCount == 2 && model.batchSkippedCrops == 1,
          "one file failed and one crop was skipped",
          "saved \(model.batchSavedCount), skipped \(model.batchSkippedCrops)")
    check(!model.isBusy, "isBusy is released once at the end")

    let sameOut = folder.appendingPathComponent("batch-same-retouched.png")
    let squareOut = folder.appendingPathComponent("batch-square-retouched.png")
    if let delta = meanDelta(singleURL, sameOut) {
        check(delta < 1.0, "batch pixels match the single export",
              String(format: "mean delta %.3f/255", delta))
    } else {
        check(false, "same-shape batch file written", sameOut.lastPathComponent)
    }

    if let sameDims = readImage(sameOut) {
        check(sameDims.width == 400 && sameDims.height == 300,
              "same-shape file takes the document crop",
              "\(sameDims.width)×\(sameDims.height)")
    } else {
        check(false, "same-shape output reads back")
    }

    if let squareDims = readImage(squareOut) {
        check(squareDims.width == 600 && squareDims.height == 600,
              "different-shape file exports whole",
              "\(squareDims.width)×\(squareDims.height)")
    } else {
        check(false, "square output reads back")
    }

    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
        .filter { $0.hasSuffix(".tmp") } ?? []
    check(leftovers.isEmpty, "no partial files remain", leftovers.joined(separator: ", "))

    // Stamps are opt-in for batch work, so the same snapshot without them must
    // produce a different picture from the one that carried them.
    let plainFolder = workDir.appendingPathComponent("batch-plain")
    try? FileManager.default.createDirectory(at: plainFolder, withIntermediateDirectories: true)
    model.batchIncludeStamps = false
    model.runBatch([sameURL], to: plainFolder)
    check(await waitUntil(180) { !model.isBatchRunning && model.batchHasReport },
          "batch without stamps finishes")
    let plainOut = plainFolder.appendingPathComponent("batch-same-retouched.png")
    if let stampDelta = meanDelta(sameOut, plainOut) {
        let changed = changedPixels(sameOut, plainOut) ?? 0
        check(stampDelta > 0.1 && changed > 100, "stamps and stickers appear only when asked for",
              String(format: "mean delta %.2f/255, %d pixels changed", stampDelta, changed))
    } else {
        check(false, "batch without stamps written")
    }
}

@MainActor
func testBatchKeepsCropAfterQuarterTurn() async {
    print("\n[P1-1b] a turned document keeps its own crop in a batch")

    let docURL = workDir.appendingPathComponent("turn-doc.png")
    let squareURL = workDir.appendingPathComponent("turn-square.png")
    guard let docImage = makeImage(width: 800, height: 600),
          let squareImage = makeImage(width: 600, height: 600),
          writePNG(docImage, to: docURL), writePNG(squareImage, to: squareURL) else {
        check(false, "turn fixtures")
        return
    }

    // 800×600 cropped by half is a 400×300 frame; a quarter turn swaps it to
    // roughly 300×400 (the crop edges are integral pixels, so the height can
    // differ by one).
    for (label, clockwise, expectedTurns) in [("90°", true, 1), ("270°", false, 3)] {
        let model = EditorModel()
        model.load(url: docURL)
        check(await waitUntil { model.hasImage && !model.isBusy },
              "\(label): document loads")

        model.cropDraft = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        model.applyCrop()
        check(await waitUntil { !model.isBusy && model.appliedCrop != nil },
              "\(label): crop applies")

        if clockwise {
            model.rotateClockwise()
        } else {
            model.rotateCounterClockwise()
        }
        check(await waitUntil(30) {
            !model.isBusy && model.documentOrientation.quarterTurns == expectedTurns
                && model.workingPixelSize.width == 300
        }, "\(label): the document turns and re-crops",
        "\(model.workingPixelSize.width)×\(model.workingPixelSize.height)")

        model.exportFormat = .png
        let singleURL = workDir.appendingPathComponent("turn-\(expectedTurns)-single.png")
        model.export(to: singleURL)
        check(await waitUntil(120) {
            FileManager.default.fileExists(atPath: singleURL.path) && !model.isBusy
        }, "\(label): single export finishes")

        let folder = workDir.appendingPathComponent("turn-\(expectedTurns)-batch")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.runBatch([docURL, squareURL], to: folder)
        check(await waitUntil(180) { !model.isBatchRunning && model.batchHasReport },
              "\(label): batch finishes")
        check(model.batchSavedCount == 2 && model.batchSkippedCrops == 1,
              "\(label): the document is saved and only the square skips the crop",
              "saved \(model.batchSavedCount), skipped \(model.batchSkippedCrops)")

        let docOut = folder.appendingPathComponent("turn-doc-retouched.png")
        if let dims = readImage(docOut), let singleDims = readImage(singleURL) {
            check(dims.width == singleDims.width && dims.height == singleDims.height
                    && dims.width == 300,
                  "\(label): the batch keeps the turned crop",
                  "\(dims.width)×\(dims.height) vs single \(singleDims.width)×\(singleDims.height)")
        } else {
            check(false, "\(label): batch output reads back")
        }

        if let delta = meanDelta(singleURL, docOut) {
            check(delta < 1.0, "\(label): batch pixels match the single export",
                  String(format: "mean delta %.3f/255", delta))
        } else {
            check(false, "\(label): batch pixels comparable")
        }

        let squareOut = folder.appendingPathComponent("turn-square-retouched.png")
        if let squareDims = readImage(squareOut) {
            check(squareDims.width == 600 && squareDims.height == 600,
                  "\(label): a different-shape file still exports whole",
                  "\(squareDims.width)×\(squareDims.height)")
        } else {
            check(false, "\(label): square output reads back")
        }
    }
}

// MARK: - P1-2 / H-5

@MainActor
func testCropIsUndoable() async {
    print("\n[P1-2] crop travels through undo history")

    let url = workDir.appendingPathComponent("crop-undo.png")
    guard let image = makeImage(width: 800, height: 600), writePNG(image, to: url) else {
        check(false, "crop fixture")
        return
    }

    let model = EditorModel()
    model.load(url: url)
    check(await waitUntil { model.hasImage && !model.isBusy }, "fixture loads")
    check(model.workingPixelSize == CGSize(width: 800, height: 600), "original frame is 800×600")

    let half = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    model.cropDraft = half
    model.applyCrop()
    check(await waitUntil { !model.isBusy && model.appliedCrop != nil }, "crop applies")
    check(model.workingPixelSize == CGSize(width: 400, height: 300), "crop re-reads the pixels")
    check(model.hasUnsavedChanges, "a crop-only edit is unsaved work")
    check(model.canUndo, "the crop is an undo step")

    model.undo()
    check(await waitUntil { !model.isBusy }, "undo finishes its re-read")
    check(model.appliedCrop == nil && model.workingPixelSize == CGSize(width: 800, height: 600),
          "undo restores the previous frame")
    check(!model.hasUnsavedChanges, "undo returns to the clean baseline")
    check(model.canRedo, "redo is offered")

    model.redo()
    check(await waitUntil { !model.isBusy }, "redo finishes its re-read")
    check(model.appliedCrop != nil && model.workingPixelSize == CGSize(width: 400, height: 300),
          "redo re-applies the crop")

    // The re-read must not clear the stack: one undo gives the frame back, a
    // second undo still reaches the slider edit made before the crop.
    model.undo()
    _ = await waitUntil { !model.isBusy }
    model.adjustments.contrast = 24
    model.commitAdjustments()
    model.cropDraft = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    model.applyCrop()
    _ = await waitUntil { !model.isBusy }
    check(model.appliedCrop != nil, "second crop applies")

    model.undo()
    _ = await waitUntil { !model.isBusy }
    check(model.adjustments.contrast == 24 && model.appliedCrop == nil,
          "one undo removes only the crop")
    model.undo()
    _ = await waitUntil { !model.isBusy }
    check(model.adjustments.contrast == 0, "the next undo reaches the slider")
    check(model.workingPixelSize == CGSize(width: 800, height: 600), "back at the original frame")

    // Reset Crop is its own step too.
    model.cropDraft = half
    model.applyCrop()
    _ = await waitUntil { !model.isBusy }
    model.resetCrop()
    check(await waitUntil { !model.isBusy && model.appliedCrop == nil }, "reset crop applies")
    model.undo()
    check(await waitUntil { !model.isBusy }, "undo after reset finishes")
    check(model.appliedCrop != nil && model.workingPixelSize == CGSize(width: 400, height: 300),
          "undo of Reset Crop brings the crop back")

    // A second undo arriving while the first re-read is still running must win:
    // the stale load is discarded by the generation guard.
    model.cropDraft = CGRect(x: 0.05, y: 0.05, width: 0.5, height: 0.5)
    model.applyCrop()
    model.undo()
    model.undo()
    check(await waitUntil { !model.isBusy }, "overlapping undos settle")
    check(model.appliedCrop == nil && model.workingPixelSize == CGSize(width: 800, height: 600),
          "a stale crop reload never installs")
}

// MARK: - P1-3 / H-4 / M-9

@MainActor
func writeProject(_ project: RetouchProject, to url: URL) -> Bool {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(project) else { return false }
    return (try? data.write(to: url, options: .atomic)) != nil
}

@MainActor
func testProjectRelink() async {
    print("\n[P1-3] a moved photo is found again")

    let folderA = workDir.appendingPathComponent("relink-a-\(UUID().uuidString)")
    let folderB = workDir.appendingPathComponent("relink-b-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
    let originalPhoto = folderA.appendingPathComponent("portrait.png")
    let movedPhoto = folderB.appendingPathComponent("portrait.png")
    let projectURL = folderA.appendingPathComponent("portrait.retouch")

    guard let image = makeImage(width: 480, height: 600), writePNG(image, to: originalPhoto) else {
        check(false, "relink fixture")
        return
    }
    // The bookmark is made where the photo lives today. Moving the file must
    // not invalidate it.
    let bookmark = try? originalPhoto.bookmarkData(options: [],
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil)
    let project = RetouchProject(imagePath: originalPhoto.path,
                                 imageBookmark: bookmark,
                                 adjustments: .zero,
                                 exportFormat: "jpeg",
                                 exportQuality: 0.9,
                                 autoRetouchStrength: 70)
    check(writeProject(project, to: projectURL), "project written next to the photo")
    try? FileManager.default.moveItem(at: originalPhoto, to: movedPhoto)
    check(!FileManager.default.fileExists(atPath: originalPhoto.path),
          "photo moved away from the recorded path")

    let model = EditorModel()
    model.openProject(at: projectURL)
    check(await waitUntil { model.hasImage && !model.isBusy }, "project opens with the photo missing")
    check(model.statusToken == .projectRelinked, "the status says the photo was relinked",
          "\(model.statusToken)")
    check(model.workingPixelSize == CGSize(width: 480, height: 600), "the moved photo is the one loaded")

    // The project was rewritten with the new path, so opening it again resolves
    // without asking anyone.
    let rewritten = (try? Data(contentsOf: projectURL))
        .flatMap { try? JSONDecoder().decode(RetouchProject.self, from: $0) }
    let recordedURL = rewritten.map { URL(fileURLWithPath: $0.imagePath).resolvingSymlinksInPath() }
    check(recordedURL == movedPhoto.resolvingSymlinksInPath(),
          "the project now records the new path", rewritten?.imagePath ?? "unreadable")
    check(rewritten?.imageBookmark != nil, "the rebuilt bookmark is stored")
    if let rewritten {
        let resolved = model.resolveProjectImage(rewritten, projectURL: projectURL)
        check(resolved?.standardizedFileURL == movedPhoto.standardizedFileURL,
              "a second open resolves straight to the photo")
    }

    // A whole folder move (photo + project together) needs no bookmark at all:
    // the sibling next to the project is the photo.
    let folderC = workDir.appendingPathComponent("relink-c-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folderC, withIntermediateDirectories: true)
    let movedFolder = workDir.appendingPathComponent("relink-d-\(UUID().uuidString)")
    try? FileManager.default.moveItem(at: folderC, to: movedFolder)
    let siblingPhoto = movedFolder.appendingPathComponent("sibling.png")
    check(makeImage(width: 120, height: 120).map { writePNG($0, to: siblingPhoto) } ?? false,
          "sibling fixture written")
    let siblingProject = RetouchProject(imagePath: folderC.appendingPathComponent("sibling.png").path,
                                        adjustments: .zero,
                                        exportFormat: "jpeg",
                                        exportQuality: 0.9,
                                        autoRetouchStrength: 70)
    let siblingURL = movedFolder.appendingPathComponent("sibling.retouch")
    let siblingResolved = model.resolveProjectImage(
        siblingProject, projectURL: siblingURL)
    check(siblingResolved?.standardizedFileURL == siblingPhoto.standardizedFileURL,
          "a moved folder resolves through the sibling path")

    let gone = RetouchProject(imagePath: "/nonexistent/\(UUID().uuidString).png",
                              adjustments: .zero,
                              exportFormat: "jpeg",
                              exportQuality: 0.9,
                              autoRetouchStrength: 70)
    check(model.resolveProjectImage(gone, projectURL: movedFolder.appendingPathComponent("gone.retouch")) == nil,
          "a photo that is truly gone goes to Locate")
}

@MainActor
func testProjectVersionGuard() async {
    print("\n[P1-3] future projects are refused, old ones still open")

    let folder = workDir.appendingPathComponent("version-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let photoURL = folder.appendingPathComponent("photo.png")
    let projectURL = folder.appendingPathComponent("future.retouch")
    guard let image = makeImage(width: 240, height: 300), writePNG(image, to: photoURL) else {
        check(false, "version fixture")
        return
    }

    var future = RetouchProject(imagePath: photoURL.path,
                                adjustments: .zero,
                                exportFormat: "jpeg",
                                exportQuality: 0.9,
                                autoRetouchStrength: 70)
    future.version = RetouchProject.currentVersion + 1
    check(writeProject(future, to: projectURL), "a version-2 project is written")

    let model = EditorModel()
    model.openProject(at: projectURL)
    // The guard runs synchronously before the load, so no sleep is needed.
    check(model.statusToken == .projectTooNew(RetouchProject.currentVersion + 1),
          "the version guard explains why it was refused", "\(model.statusToken)")
    check(!model.hasImage, "nothing was loaded from the newer project")

    // A project written before the version key existed is version 1.
    let encoder = JSONEncoder()
    guard var object = (try? encoder.encode(future)).flatMap({
        try? JSONSerialization.jsonObject(with: $0)
    }) as? [String: Any] else {
        check(false, "fixture JSON")
        return
    }
    object.removeValue(forKey: "version")
    object.removeValue(forKey: "imageBookmark")
    guard let legacyData = try? JSONSerialization.data(withJSONObject: object),
          let legacy = try? JSONDecoder().decode(RetouchProject.self, from: legacyData) else {
        check(false, "a project without a version key decodes")
        return
    }
    check(legacy.version == RetouchProject.currentVersion,
          "a missing version decodes as the current one", "v\(legacy.version)")
    check(legacy.imageBookmark == nil, "a project without a bookmark still opens")

    let chosen = RetouchProject(imagePath: photoURL.path,
                                adjustments: .zero,
                                exportFormat: "png",
                                exportQuality: 1,
                                autoRetouchStrength: 70,
                                selectedFace: 1)
    let reopened = (try? JSONEncoder().encode(chosen))
        .flatMap { try? JSONDecoder().decode(RetouchProject.self, from: $0) }
    check(reopened?.selectedFace == 1, "the chosen face survives save and reopen",
          "selectedFace=\(reopened?.selectedFace.map(String.init) ?? "nil")")
}

// MARK: - R4.3 Project v3 baseline

/// Freezes what the current encoder writes before the codec is extracted. The
/// fixture covers all 16 stored fields; decoding it and re-encoding with the
/// same settings must reproduce its bytes. Any difference is a format change.
@MainActor
func testProjectV3BaselineByteIdentity() {
    print("\n[R4.3] the project v3 fixture re-encodes byte for byte")

    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ProjectV3/project-v3-full.retouch")
    guard let original = try? Data(contentsOf: fixtureURL) else {
        check(false, "the v3 fixture is readable", fixtureURL.path)
        return
    }
    guard let project = try? JSONDecoder().decode(RetouchProject.self, from: original) else {
        check(false, "the v3 fixture decodes")
        return
    }

    check(project.version == 3, "the fixture is written at version 3")
    check(!project.imagePath.isEmpty, "the fixture records the photo path")
    check(project.imageBookmark?.isEmpty == false, "the fixture carries a bookmark")
    check(project.adjustments != Adjustments(), "the fixture carries real adjustments")
    check(project.exportFormat == "jpeg" && project.exportQuality == 0.87,
          "the fixture carries the export format and quality")
    check(project.exportLongEdge == 4096, "the fixture carries the long edge")
    check(project.autoRetouchStrength == 65 && project.autoColorStrength == 80,
          "the fixture carries both auto strengths")
    check(project.crop != nil, "the fixture carries a crop")
    check((project.healSpots?.count ?? 0) == 2, "the fixture carries healing stamps")
    check((project.stickers?.count ?? 0) == 1, "the fixture carries a sticker")
    check((project.aiEdits?.count ?? 0) == 1, "the fixture carries an AI edit")
    check(project.analysis?.isEnabled == true, "the fixture carries analysis settings")
    check(project.selectedFace == 2, "the fixture carries the chosen face")
    check(project.orientation?.isIdentity == false, "the fixture carries the orientation")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let encoded = try? encoder.encode(project) else {
        check(false, "the fixture encodes")
        return
    }

    if encoded != original {
        let shared = min(encoded.count, original.count)
        var offset = 0
        while offset < shared && encoded[offset] == original[offset] { offset += 1 }
        print("   byte difference at offset \(offset): encoded \(encoded.count) bytes,"
              + " fixture \(original.count) bytes")
        print("   encoded: \(hexSnippet(encoded, around: offset))")
        print("   fixture: \(hexSnippet(original, around: offset))")
    }
    check(encoded == original, "decoding and re-encoding reproduces the fixture bytes",
          "encoded \(encoded.count) bytes, fixture \(original.count) bytes")
}

private func hexSnippet(_ data: Data, around offset: Int) -> String {
    let start = max(0, offset - 12)
    let end = min(data.count, offset + 12)
    guard start < end else { return "<empty>" }
    return data[start..<end].map { String(format: "%02x", $0) }.joined(separator: " ")
}

// MARK: - R4.3 Project codec

private struct StubSources: ProjectSourceAccess {
    var paths: Set<String>

    func fileExists(at url: URL) -> Bool { paths.contains(url.path) }
}

private struct StubBookmarks: ProjectBookmarkStore {
    var made: [String: Data] = [:]
    var resolved: [Data: URL] = [:]

    func bookmark(for url: URL) -> Data? { made[url.path] }
    func resolveBookmark(_ data: Data) -> URL? { resolved[data] }
}

private func projectV3Fixture() -> (url: URL, data: Data) {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ProjectV3/project-v3-full.retouch")
    return (url, (try? Data(contentsOf: url)) ?? Data())
}

private func makeCodecInput(imageURL: URL) -> ProjectInput {
    ProjectInput(imageURL: imageURL,
                 state: DocumentState(),
                 exportFormat: "jpeg",
                 exportQuality: 0.9,
                 exportLongEdge: 0,
                 autoRetouchStrength: 70,
                 autoColorStrength: 0)
}

@MainActor
func testProjectCodecFieldMapping() {
    print("\n[R4.3] the codec maps every input field onto the project")

    let imageURL = URL(fileURLWithPath: "/codec/photos/portrait.jpg")
    let bookmark = Data([0xAA, 0xBB])
    var state = DocumentState()
    state.adjustments.exposure = 12
    state.healSpots = [HealSpot(center: CGPoint(x: 0.4, y: 0.5), radius: 0.02)]
    state.stickers = [Sticker(kind: .heart, center: CGPoint(x: 0.3, y: 0.6), size: 0.1)]
    state.aiEdits = [AIEdit(preset: "retouch", prompt: "smooth the wall", seed: 7,
                            patchFile: "patch.png", alphaFile: "alpha.png",
                            box: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                            imagePixels: CGSize(width: 64, height: 64))]
    state.analysis.isEnabled = true
    state.crop = CGRect(x: 0.05, y: 0.1, width: 0.8, height: 0.7)
    state.orientation = DocumentOrientation(quarterTurns: 1, flipped: true, angle: 2)
    state.selectedFaceIndex = 3

    let input = ProjectInput(imageURL: imageURL, state: state,
                             exportFormat: "tiff", exportQuality: 0.75,
                             exportLongEdge: 2048, autoRetouchStrength: 55,
                             autoColorStrength: 45)
    let project = ProjectCodec.makeProject(
        input, bookmarks: StubBookmarks(made: [imageURL.path: bookmark]))

    check(project.version == RetouchProject.currentVersion, "the codec writes the current version")
    check(project.imagePath == imageURL.path, "the photo path is recorded")
    check(project.imageBookmark == bookmark, "the bookmark comes from the store")
    check(project.adjustments == state.adjustments, "adjustments are copied")
    check(project.exportFormat == "tiff" && project.exportQuality == 0.75,
          "export format and quality are copied")
    check(project.exportLongEdge == 2048, "a real long edge is kept")
    check(project.autoRetouchStrength == 55 && project.autoColorStrength == 45,
          "both auto strengths are copied")
    check(project.crop == state.crop, "the crop is copied")
    check(project.healSpots == state.healSpots, "healing stamps are copied")
    check(project.stickers == state.stickers, "stickers are copied")
    check(project.aiEdits == state.aiEdits, "AI edits are copied")
    check(project.analysis == state.analysis, "analysis settings are copied")
    check(project.selectedFace == 3, "the chosen face is copied")
    check(project.orientation == state.orientation, "the orientation is copied")
}

@MainActor
func testProjectCodecNormalization() {
    print("\n[R4.3] the codec normalizes empty values to nil")

    let input = makeCodecInput(imageURL: URL(fileURLWithPath: "/codec/defaults.jpg"))
    let project = ProjectCodec.makeProject(input, bookmarks: StubBookmarks())

    check(project.imageBookmark == nil, "no bookmark stays nil")
    check(project.exportLongEdge == nil, "a zero long edge becomes nil")
    check(project.crop == nil, "no crop stays nil")
    check(project.healSpots == nil, "no healing stamps become nil")
    check(project.stickers == nil, "no stickers become nil")
    check(project.aiEdits == nil, "no AI edits become nil")
    check(project.analysis == nil, "default analysis becomes nil")
    check(project.selectedFace == nil, "no chosen face stays nil")
    check(project.orientation == nil, "identity orientation becomes nil")
}

@MainActor
func testProjectCodecLegacyDecode() {
    print("\n[R4.3] the codec keeps older projects readable")

    guard let adjustments = try? JSONSerialization.jsonObject(
            with: JSONEncoder().encode(Adjustments())) else {
        check(false, "adjustments fixture")
        return
    }
    let legacy: [String: Any] = [
        "imagePath": "/codec/legacy.jpg",
        "adjustments": adjustments,
        "exportFormat": "png",
        "exportQuality": 1.0,
        "autoRetouchStrength": 70.0,
        "unknownFutureKey": ["kept": "out of the way"]
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: legacy),
          let project = try? ProjectCodec.decode(data) else {
        check(false, "a legacy project decodes")
        return
    }

    check(project.version == RetouchProject.currentVersion,
          "a missing version decodes as the current one")
    check(project.imageBookmark == nil && project.exportLongEdge == nil,
          "fields added after v1 decode as nil")
    check(project.crop == nil && project.orientation == nil
            && project.healSpots == nil && project.stickers == nil
            && project.aiEdits == nil && project.analysis == nil,
          "every later optional decodes as nil")
    check(project.autoColorStrength == nil, "the auto color strength predates as nil")
    check(project.selectedFace == nil, "the chosen face predates as nil")
}

@MainActor
func testProjectCodecVersionGuard() {
    print("\n[R4.3] the codec refuses a newer project")

    let input = makeCodecInput(imageURL: URL(fileURLWithPath: "/codec/version.jpg"))
    let project = ProjectCodec.makeProject(input, bookmarks: StubBookmarks())
    guard let encoded = try? ProjectCodec.encode(project),
          var object = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] else {
        check(false, "version fixture")
        return
    }
    object["version"] = RetouchProject.currentVersion + 1
    guard let newer = try? JSONSerialization.data(withJSONObject: object) else {
        check(false, "newer fixture")
        return
    }

    do {
        _ = try ProjectCodec.decode(newer)
        check(false, "a newer project is refused")
    } catch ProjectCodecError.tooNew(let version) {
        check(version == RetouchProject.currentVersion + 1,
              "the refusal carries the file version", "v\(version)")
    } catch {
        check(false, "the refusal is a version error", "\(error)")
    }

    check((try? ProjectCodec.decode(encoded)) != nil, "the current version still decodes")

    object["version"] = 1
    if let old = try? JSONSerialization.data(withJSONObject: object) {
        check((try? ProjectCodec.decode(old)) != nil, "an old version still decodes")
    }
}

@MainActor
func testProjectCodecReproducesBaseline() {
    print("\n[R4.3] the codec reproduces the v3 baseline bytes")

    let fixture = projectV3Fixture()
    guard let project = try? ProjectCodec.decode(fixture.data) else {
        check(false, "the codec decodes the baseline fixture")
        return
    }
    guard let encoded = try? ProjectCodec.encode(project) else {
        check(false, "the codec encodes the baseline project")
        return
    }
    check(encoded == fixture.data, "codec bytes match the fixture",
          "encoded \(encoded.count) bytes, fixture \(fixture.data.count) bytes")
}

@MainActor
func testProjectSourceResolverOrder() {
    print("\n[R4.3] the resolver trusts the bookmark first")

    let recorded = URL(fileURLWithPath: "/codec/original/photo.jpg")
    let bookmarked = URL(fileURLWithPath: "/codec/moved/photo.jpg")
    let sibling = URL(fileURLWithPath: "/codec/folder/photo.jpg")
    let projectFile = URL(fileURLWithPath: "/codec/folder/photo.retouch")
    let bookmark = Data([0x0A])

    var project = RetouchProject(imagePath: recorded.path, imageBookmark: bookmark,
                                 adjustments: .zero, exportFormat: "jpeg",
                                 exportQuality: 0.9, autoRetouchStrength: 70)
    let bookmarks = StubBookmarks(resolved: [bookmark: bookmarked])

    var resolver = ProjectSourceResolver(
        sources: StubSources(paths: [bookmarked.path, recorded.path]), bookmarks: bookmarks)
    check(resolver.resolve(project, projectURL: projectFile)?.path == bookmarked.path,
          "the bookmark wins when both files exist")

    resolver = ProjectSourceResolver(sources: StubSources(paths: [recorded.path]),
                                     bookmarks: bookmarks)
    check(resolver.resolve(project, projectURL: projectFile)?.path == recorded.path,
          "a missing bookmark target falls back to the absolute path")

    project.imageBookmark = Data([0x0B])
    resolver = ProjectSourceResolver(sources: StubSources(paths: [recorded.path]),
                                     bookmarks: bookmarks)
    check(resolver.resolve(project, projectURL: projectFile)?.path == recorded.path,
          "an unresolvable bookmark falls back to the absolute path")

    project.imageBookmark = nil
    resolver = ProjectSourceResolver(sources: StubSources(paths: [sibling.path]),
                                     bookmarks: bookmarks)
    check(resolver.resolve(project, projectURL: projectFile)?.path == sibling.path,
          "a moved folder falls back to the sibling next to the project")

    resolver = ProjectSourceResolver(sources: StubSources(paths: []), bookmarks: bookmarks)
    check(resolver.resolve(project, projectURL: projectFile) == nil,
          "nothing on disk means the owner has to locate the photo")
}

@MainActor
func testProjectCodecRelinkRewrite() {
    print("\n[R4.3] a relinked project records the new photo")

    let oldURL = URL(fileURLWithPath: "/codec/a/photo.jpg")
    let newURL = URL(fileURLWithPath: "/codec/b/photo.jpg")
    let oldBookmark = Data([0x01])
    let newBookmark = Data([0x02])
    let bookmarks = StubBookmarks(made: [oldURL.path: oldBookmark,
                                         newURL.path: newBookmark])

    var input = makeCodecInput(imageURL: oldURL)
    let before = ProjectCodec.makeProject(input, bookmarks: bookmarks)
    input.imageURL = newURL
    let after = ProjectCodec.makeProject(input, bookmarks: bookmarks)

    check(before.imagePath == oldURL.path && before.imageBookmark == oldBookmark,
          "the first project records the old location")
    check(after.imagePath == newURL.path && after.imageBookmark == newBookmark,
          "the rewritten project records the new location")

    let reopened = (try? ProjectCodec.encode(after))
        .flatMap { try? ProjectCodec.decode($0) }
    check(reopened?.imagePath == newURL.path && reopened?.imageBookmark == newBookmark,
          "the rewrite survives a round trip")

    let first = try? ProjectCodec.encode(after)
    let second = try? ProjectCodec.encode(after)
    check(first != nil && first == second, "encoding the same project is deterministic")
}

// MARK: - R4.4 Document restoration

@MainActor
func testDocumentRestorationFromProject() {
    print("\n[R4.4] a project restores the document fields")

    let projectURL = URL(fileURLWithPath: "/codec/restore.retouch")
    var analysis = AnalysisSettings()
    analysis.isEnabled = true
    analysis.regions = [.lips]
    var project = RetouchProject(
        imagePath: "/codec/photo.jpg",
        adjustments: .zero,
        exportFormat: "tiff",
        exportQuality: 0.75,
        exportLongEdge: 2048,
        autoRetouchStrength: 55,
        autoColorStrength: 45,
        crop: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5),
        healSpots: [HealSpot(center: CGPoint(x: 0.3, y: 0.4), radius: 0.01)],
        stickers: [Sticker(kind: .heart, center: CGPoint(x: 0.5, y: 0.5), size: 0.1)],
        aiEdits: [AIEdit(preset: "cleanup", prompt: "wall", seed: 1,
                         patchFile: "patch.png", alphaFile: "alpha.png",
                         box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                         imagePixels: CGSize(width: 32, height: 32))],
        analysis: analysis,
        selectedFace: 2,
        orientation: DocumentOrientation(quarterTurns: 2, angle: 1))
    project.adjustments.exposure = 9

    let restoration = DocumentRestoration.project(project, url: projectURL)
    check(restoration.isProject && restoration.projectURL == projectURL,
          "the restoration knows it came from a project")
    check(restoration.exportFormat == .tiff && restoration.exportQuality == 0.75
            && restoration.exportLongEdge == 2048,
          "the export settings are restored")
    check(restoration.autoRetouchStrength == 55 && restoration.autoColorStrength == 45,
          "both auto strengths are restored")
    check(restoration.state.adjustments == project.adjustments, "adjustments are restored")
    check(restoration.state.healSpots == project.healSpots, "healing stamps are restored")
    check(restoration.state.stickers == project.stickers, "stickers are restored")
    check(restoration.state.aiEdits == project.aiEdits, "AI edits are restored")
    check(restoration.state.analysis == project.analysis, "analysis is restored")
    check(restoration.state.crop == project.crop, "the crop is restored")
    check(restoration.state.orientation == project.orientation, "the orientation is restored")
    check(restoration.state.selectedFaceIndex == 2, "the chosen face is restored")
}

@MainActor
func testDocumentRestorationDefaultsAndPhoto() {
    print("\n[R4.4] legacy projects and plain photos restore the right defaults")

    let legacy = RetouchProject(imagePath: "/codec/legacy.jpg",
                                adjustments: .zero,
                                exportFormat: "not-a-format",
                                exportQuality: 0.5,
                                autoRetouchStrength: 70)
    let restored = DocumentRestoration.project(legacy, url: nil)
    check(restored.exportFormat == .jpeg, "an unknown export format falls back to jpeg")
    check(restored.exportLongEdge == 0 && restored.autoColorStrength == 100,
          "missing export preferences gain the v3 defaults")
    check(restored.state == DocumentState(),
          "a project without document fields restores an empty document")
    check(restored.isProject && restored.projectURL == nil,
          "a project without a URL is still a project")

    var oriented = legacy
    oriented.autoColorStrength = 30
    let withColor = DocumentRestoration.project(oriented, url: nil)
    check(withColor.autoColorStrength == 30 && withColor.exportLongEdge == 0,
          "a recorded auto color strength is kept")

    let photo = DocumentRestoration.photo()
    check(photo.exportFormat == nil && photo.exportQuality == nil && photo.exportLongEdge == nil
            && photo.autoRetouchStrength == nil && photo.autoColorStrength == nil,
          "a plain photo keeps the owner's export settings")
    check(photo.state == DocumentState() && !photo.isProject && photo.projectURL == nil,
          "a plain photo starts from an empty document")
}

// MARK: - R4.5 Export planner

private func makeExportPlanner() -> ExportPlanner {
    ExportPlanner(adjustments: .zero, healSpots: [], stickers: [], aiEdits: [],
                  analysis: AnalysisSettings(), crop: nil, orientation: .identity,
                  selectedFaceIndex: nil, imageName: "portrait.jpg", faceCount: 2,
                  workingPixelSize: CGSize(width: 800, height: 600),
                  format: .jpeg, quality: 0.9, longEdge: 0, aiUpscale: false,
                  stripsMetadata: true, watermark: .disabled)
}

@MainActor
func testExportPlannerNaming() {
    print("\n[R4.5] the planner names the file and picks the format")

    var planner = makeExportPlanner()
    check(planner.suggestedFileName() == "portrait-retouched.jpg",
          "a plain export keeps the format extension", planner.suggestedFileName())
    check(planner.effectiveFormat == .jpeg, "no analysis keeps the chosen format")

    planner.imageName = ""
    check(planner.suggestedFileName() == "retouched.jpg", "an unnamed photo gets a fallback name")
    planner.imageName = "portrait"

    var onPhoto = AnalysisSettings()
    onPhoto.isEnabled = true
    onPhoto.exportMode = .onPhoto
    planner.analysis = onPhoto
    check(planner.suggestedFileName() == "portrait-retouched-analysis.jpg",
          "analysis on the photo adds its suffix", planner.suggestedFileName())
    check(planner.effectiveFormat == .jpeg, "drawing on the photo keeps the chosen format")

    planner.analysis.exportMode = .poster
    check(planner.suggestedFileName() == "portrait-retouched-analysis-poster.jpg",
          "poster analysis names its own suffix", planner.suggestedFileName())

    planner.analysis.exportMode = .overlayOnly
    check(planner.suggestedFileName() == "portrait-retouched-analysis-lines.png",
          "overlay-only names a png", planner.suggestedFileName())
    check(planner.effectiveFormat == .png, "overlay-only always exports png")

    planner.faceCount = 0
    check(planner.suggestedFileName() == "portrait-retouched.jpg",
          "without a face the name must not promise analysis")
    check(planner.effectiveFormat == .jpeg, "without a face the chosen format stays")
}

@MainActor
func testExportPlannerPixelSize() {
    print("\n[R4.5] the planner decides the exported pixel size")

    var planner = makeExportPlanner()
    check(planner.pixelSize == CGSize(width: 800, height: 600),
          "zero long edge keeps the working size")
    check(!planner.upscaleAvailable && !planner.usesUpscale,
          "no requested edge means no upscale")

    planner.longEdge = 400
    check(planner.pixelSize == CGSize(width: 400, height: 300),
          "a smaller long edge downscales")

    planner.longEdge = 1600
    check(planner.pixelSize == CGSize(width: 800, height: 600),
          "a larger edge does nothing while upscale is off")
    check(planner.upscaleAvailable && !planner.usesUpscale,
          "the upscaler is available but not requested")

    planner.aiUpscale = true
    check(planner.usesUpscale, "requested upscale runs when available")
    check(planner.pixelSize == CGSize(width: 1600, height: 1200),
          "the requested edge caps the upscale")
    check(planner.upscaleEstimate == 50, "the estimate follows the 4x output",
          "\(planner.upscaleEstimate)")

    planner.longEdge = 5000
    check(planner.pixelSize == CGSize(width: 3200, height: 2400),
          "beyond 4x the photo the upscaler stops at its factor")

    planner.workingPixelSize = CGSize(width: 4000, height: 3000)
    planner.longEdge = 5000
    check(!planner.upscaleAvailable, "too many output pixels disables the upscaler")
    check(planner.pixelSize == CGSize(width: 4000, height: 3000),
          "an unavailable upscale leaves the photo at its size")
}

@MainActor
func testExportPlannerSnapshot() {
    print("\n[R4.5] the planner builds the export snapshot")

    var planner = makeExportPlanner()
    planner.adjustments.exposure = 8
    planner.healSpots = [HealSpot(center: CGPoint(x: 0.2, y: 0.3), radius: 0.01)]
    planner.stickers = [Sticker(kind: .star, center: CGPoint(x: 0.4, y: 0.5), size: 0.1)]
    planner.aiEdits = [AIEdit(preset: "p", prompt: "q", seed: 2,
                              patchFile: "patch.png", alphaFile: "alpha.png",
                              box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                              imagePixels: CGSize(width: 16, height: 16))]
    var analysis = AnalysisSettings()
    analysis.isEnabled = true
    planner.analysis = analysis
    planner.crop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    planner.orientation = DocumentOrientation(quarterTurns: 1)
    planner.selectedFaceIndex = 1
    planner.format = .tiff
    planner.quality = 0.8
    planner.longEdge = 2048
    planner.stripsMetadata = false
    planner.aiUpscale = true
    var watermark = WatermarkSettings()
    watermark.enabled = true
    watermark.text = "Studio"
    planner.watermark = watermark

    let snapshot = planner.snapshot()
    check(snapshot.adjustments == planner.adjustments
            && snapshot.healSpots == planner.healSpots
            && snapshot.stickers == planner.stickers
            && snapshot.aiEdits == planner.aiEdits
            && snapshot.analysis == planner.analysis,
          "document content is copied")
    check(snapshot.crop == planner.crop && snapshot.orientation == planner.orientation
            && snapshot.selectedFaceIndex == 1,
          "frame and face choice are copied")
    check(snapshot.format == .tiff && snapshot.quality == 0.8 && snapshot.longEdge == 2048,
          "format, quality and long edge are copied")
    check(snapshot.stripsPrivacyMetadata == false, "the metadata policy is copied")
    check(snapshot.includeStamps && snapshot.includeAnalysis,
          "single-photo export includes stamps and analysis by default")
    check(snapshot.aiUpscale, "the snapshot records the upscale")
    check(snapshot.watermark == watermark, "the watermark is copied")

    let batch = planner.snapshot(includeStamps: false, includeAnalysis: false)
    check(!batch.includeStamps && !batch.includeAnalysis,
          "batch can exclude stamps and analysis")

    var noEdge = makeExportPlanner()
    noEdge.format = .png
    noEdge.longEdge = 0
    check(noEdge.snapshot().longEdge == nil, "zero long edge exports at the photo size")

    var overlay = makeExportPlanner()
    var lines = AnalysisSettings()
    lines.isEnabled = true
    lines.exportMode = .overlayOnly
    overlay.analysis = lines
    let linesSnapshot = overlay.snapshot()
    check(linesSnapshot.format == .png && !linesSnapshot.aiUpscale,
          "an overlay-only snapshot is png and never upscaled when not requested")
}

// MARK: - R4.6 Batch planner

@MainActor
func testBatchPlannerFilePolicy() {
    print("\n[R4.6] the batch planner shares only what fits the file")

    var analysis = AnalysisSettings()
    analysis.isEnabled = true
    analysis.setEndpoint(CGPoint(x: 0.4, y: 0.4), for: .lips)
    analysis.setAnchor(CGPoint(x: 0.5, y: 0.5), for: .lips)
    var base = ExportSnapshot()
    base.adjustments.exposure = 5
    base.crop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    base.aiEdits = [AIEdit(preset: "p", prompt: "q", seed: 3,
                           patchFile: "patch.png", alphaFile: "alpha.png",
                           box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                           imagePixels: CGSize(width: 16, height: 16))]
    base.analysis = analysis
    base.selectedFaceIndex = 1
    base.format = .png

    let documentURL = URL(fileURLWithPath: "/doc/photo.jpg").resolvingSymlinksInPath()
    let planner = BatchPlanner(base: base, documentURL: documentURL, documentAspect: 1.5)

    let own = planner.plan(for: documentURL, fileAspect: 2.0)
    check(own.snapshot == base && !own.skippedCrop,
          "the open document keeps its exact snapshot")

    let sameShape = planner.plan(for: URL(fileURLWithPath: "/doc/other.jpg"), fileAspect: 1.5)
    check(sameShape.snapshot.crop == base.crop && !sameShape.skippedCrop,
          "a file with the same shape keeps the crop")
    check(sameShape.snapshot.adjustments == base.adjustments
            && sameShape.snapshot.format == .png,
          "the shared look and format travel")
    check(sameShape.snapshot.aiEdits.isEmpty, "AI patches never travel to another photo")
    check(sameShape.snapshot.orientation == .identity, "another photo opens upright")
    check(sameShape.snapshot.selectedFaceIndex == nil, "the face choice stays with its photo")
    check(sameShape.snapshot.analysis.endpoints.isEmpty
            && sameShape.snapshot.analysis.anchors.isEmpty,
          "dragged callout ends stay with their photo")

    let differentShape = planner.plan(for: URL(fileURLWithPath: "/doc/wide.jpg"), fileAspect: 2.0)
    check(differentShape.snapshot.crop == nil && differentShape.skippedCrop,
          "a different shape drops the crop and reports it")

    var turned = base
    turned.orientation = DocumentOrientation(quarterTurns: 1)
    let turnedPlanner = BatchPlanner(base: turned, documentURL: documentURL, documentAspect: 1.5)
    let turnedFile = turnedPlanner.plan(for: URL(fileURLWithPath: "/doc/other.jpg"),
                                        fileAspect: 1.5)
    check(turnedFile.snapshot.crop == nil && turnedFile.skippedCrop,
          "a turned document's crop does not travel")
}

@MainActor
func testBatchPlannerUpscaleAndNaming() {
    print("\n[R4.6] the batch planner fits upscaling and names files uniquely")

    var base = ExportSnapshot()
    base.aiUpscale = true
    base.longEdge = 2000
    let planner = BatchPlanner(base: base, documentURL: nil, documentAspect: 1.5)

    check(planner.fitUpscale(base, to: CGSize(width: 800, height: 600)).aiUpscale,
          "a smaller file keeps the requested upscale")
    check(!planner.fitUpscale(base, to: CGSize(width: 2000, height: 1500)).aiUpscale,
          "a file that already reaches the edge does not upscale")
    check(!planner.fitUpscale(base, to: CGSize(width: 4000, height: 3000)).aiUpscale,
          "a file past the 4x ceiling is written at its own size")

    var off = base
    off.aiUpscale = false
    check(!planner.fitUpscale(off, to: CGSize(width: 800, height: 600)).aiUpscale,
          "an unrequested upscale stays off")

    let folder = URL(fileURLWithPath: "/out")
    let file = URL(fileURLWithPath: "/in/photo.jpg")
    check(BatchPlanner.uniqueOutputURL(for: file, in: folder, format: .png) {
        _ in false
    }.lastPathComponent == "photo-retouched.png", "the first name is plain")

    var taken: Set<String> = ["/out/photo-retouched.png"]
    let second = BatchPlanner.uniqueOutputURL(for: file, in: folder, format: .png) {
        taken.contains($0.path)
    }
    check(second.lastPathComponent == "photo-retouched-2.png",
          "a taken name gains a counter", second.lastPathComponent)

    taken.insert("/out/photo-retouched-2.png")
    let third = BatchPlanner.uniqueOutputURL(for: file, in: folder, format: .png) {
        taken.contains($0.path)
    }
    check(third.lastPathComponent == "photo-retouched-3.png",
          "the counter keeps moving", third.lastPathComponent)

    check(BatchPlanner.uniqueOutputURL(for: file, in: folder, format: .tiff) {
        _ in false
    }.lastPathComponent == "photo-retouched.tif", "the format extension is used")
}

// MARK: - P1-5 / M-13 / M-4

@MainActor
func testOperationCoordination() async {
    print("\n[P1-5] blocking work is serialized and previews cannot end it")

    let sourceURL = workDir.appendingPathComponent("coordination.png")
    guard let big = makeImage(width: 2400, height: 1800), writePNG(big, to: sourceURL) else {
        check(false, "coordination fixture")
        return
    }

    let model = EditorModel()
    model.load(url: sourceURL)
    check(await waitUntil { model.hasImage && !model.isBusy }, "fixture loads")

    // A preview in flight must lose the busy flag to the export that follows.
    model.schedulePreview()
    check(model.isBusy, "a preview starts as busy")

    let first = workDir.appendingPathComponent("coordination-first.png")
    model.export(to: first)
    check(model.isExporting && model.isBusy, "export starts over the preview")

    model.schedulePreview()
    check(model.isBusy && model.isExporting,
          "a preview requested during an export leaves the export busy")
    check(await waitUntil(240) { !model.isBusy && !model.isExporting }, "export releases busy once")
    check(FileManager.default.fileExists(atPath: first.path), "the export was written")

    // A second blocking request is refused with a visible status, not queued.
    let second = workDir.appendingPathComponent("coordination-second.png")
    model.export(to: second)
    check(model.isExporting, "a fresh export starts")
    let third = workDir.appendingPathComponent("coordination-third.png")
    model.export(to: third)
    check(model.statusToken == .operationBusy, "a concurrent export is refused", "\(model.statusToken)")

    let refusedFolder = workDir.appendingPathComponent("coordination-refused-batch")
    try? FileManager.default.createDirectory(at: refusedFolder, withIntermediateDirectories: true)
    model.runBatch([sourceURL], to: refusedFolder)
    check(!model.isBatchRunning && model.statusToken == .operationBusy,
          "a batch cannot start during an export")
    model.undo()
    check(model.statusToken == .operationBusy, "undo is refused while an export runs")

    check(await waitUntil(240) { !model.isBusy && !model.isExporting }, "the export still finishes")
    check(!FileManager.default.fileExists(atPath: third.path), "the refused export wrote nothing")
    let refusedOut = (try? FileManager.default.contentsOfDirectory(atPath: refusedFolder.path)) ?? []
    check(refusedOut.isEmpty, "the refused batch wrote nothing", refusedOut.joined(separator: ", "))

    // Cancelling a render releases busy exactly once and leaves no file.
    let cancelled = workDir.appendingPathComponent("coordination-cancelled.png")
    model.export(to: cancelled)
    model.cancelExport()
    check(await waitUntil(240) { !model.isBusy && !model.isExporting }, "cancel releases busy")
    check(model.statusToken == .exportCancelled, "cancel is reported", "\(model.statusToken)")
    check(!FileManager.default.fileExists(atPath: cancelled.path), "a cancelled export writes no file")

    // A cancelled batch stops between files and reports why.
    let batchFolder = workDir.appendingPathComponent("coordination-batch")
    try? FileManager.default.createDirectory(at: batchFolder, withIntermediateDirectories: true)
    model.runBatch([sourceURL, sourceURL], to: batchFolder)
    check(model.isBatchRunning && model.isBusy, "batch starts")
    model.cancelBatchExport()
    check(await waitUntil(240) { !model.isBatchRunning && !model.isBusy }, "batch cancel releases busy")
    check(model.statusToken == .batchCancelled, "batch cancel is reported", "\(model.statusToken)")
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: batchFolder.path))?
        .filter { $0.hasSuffix(".tmp") } ?? []
    check(leftovers.isEmpty, "a cancelled batch leaves no partial files",
          leftovers.joined(separator: ", "))
}

// MARK: - P1-8

@MainActor
func testBatchCancellationStopsInFlightFile() async {
    print("\n[P1-8] cancelling a batch stops the file in flight before it writes")

    let prefix = "cancel-\(UUID().uuidString.prefix(8))"
    let documentURL = workDir.appendingPathComponent("\(prefix)-doc.png")
    let firstURL = workDir.appendingPathComponent("\(prefix)-first.png")
    let secondURL = workDir.appendingPathComponent("\(prefix)-second.png")
    guard let image = makeImage(width: 480, height: 600),
          writePNG(image, to: documentURL),
          writePNG(image, to: firstURL),
          writePNG(image, to: secondURL) else {
        check(false, "cancellation fixtures")
        return
    }

    let model = EditorModel()
    model.load(url: documentURL)
    check(await waitUntil { model.hasImage && !model.isBusy }, "document loads")
    model.exportFormat = .png

    let folder = workDir.appendingPathComponent("batch-cancel-\(prefix)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    // The hook pauses the second file immediately before its write, which is
    // the only moment where a cancellation can land after the render and still
    // leave nothing behind.
    let reached = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let writes = LockedCounter()
    model.batchFileWillWriteHook = { _ in
        guard writes.next() == 2 else { return }
        reached.signal()
        _ = release.wait(timeout: .now() + 30)
    }

    model.runBatch([firstURL, secondURL], to: folder)
    let stopped = await waitUntil(120) { reached.wait(timeout: .now()) == .success }
    check(stopped, "the batch reaches the second file just before writing")
    model.cancelBatchExport()
    release.signal()
    check(await waitUntil(120) { !model.isBatchRunning && model.batchHasReport },
          "the cancelled batch finishes promptly")

    check(model.statusToken == .batchCancelled, "the status reports the cancellation",
          "\(model.statusToken)")
    check(model.batchSavedCount == 1, "the finished first file still counts",
          "\(model.batchSavedCount)")
    let firstOut = folder.appendingPathComponent("\(prefix)-first-retouched.png")
    let secondOut = folder.appendingPathComponent("\(prefix)-second-retouched.png")
    check(readImage(firstOut) != nil, "the first output is complete and readable")
    check(!FileManager.default.fileExists(atPath: secondOut.path),
          "the cancelled second file wrote nothing")
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
        .filter { $0.hasSuffix(".tmp") || $0.hasSuffix(".part") } ?? []
    check(leftovers.isEmpty, "no temporary files remain", leftovers.joined(separator: ", "))

    // The model must run normally again once the cancellation has been cleared.
    model.batchFileWillWriteHook = nil
    let again = workDir.appendingPathComponent("batch-after-cancel-\(prefix)")
    try? FileManager.default.createDirectory(at: again, withIntermediateDirectories: true)
    model.runBatch([firstURL], to: again)
    check(await waitUntil(180) { !model.isBatchRunning && model.batchHasReport },
          "a batch runs normally after a cancellation")
    check(model.batchSavedCount == 1
            && model.statusToken == .batchFinished(saved: 1, total: 1, cropsSkipped: 0),
          "the later batch saved its file", "\(model.statusToken)")
}

// MARK: - P1-8 write failure

@MainActor
func testBatchWriteFailureIsNotCounted() async {
    print("\n[P1-8] a failed write is not counted as a saved photo")

    let prefix = "writefail-\(UUID().uuidString.prefix(8))"
    let documentURL = workDir.appendingPathComponent("\(prefix)-doc.png")
    let firstURL = workDir.appendingPathComponent("\(prefix)-first.png")
    let secondURL = workDir.appendingPathComponent("\(prefix)-second.png")
    guard let image = makeImage(width: 480, height: 600),
          writePNG(image, to: documentURL),
          writePNG(image, to: firstURL),
          writePNG(image, to: secondURL) else {
        check(false, "write-failure fixtures")
        return
    }

    let model = EditorModel()
    model.load(url: documentURL)
    check(await waitUntil { model.hasImage && !model.isBusy }, "document loads")
    model.exportFormat = .png

    let folder = workDir.appendingPathComponent("batch-writefail-\(prefix)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    // The first file uses the real writer; the second reaches the same write
    // stage and reports failure. A load or render failure would not prove that
    // a failed write is kept out of the saved count.
    let writes = LockedCounter()
    model.batchFileWriteResultOverride = { _ in
        writes.next() == 1 ? nil : false
    }

    model.runBatch([firstURL, secondURL], to: folder)
    check(await waitUntil(180) { !model.isBatchRunning && model.batchHasReport },
          "batch finishes")
    check(writes.next() == 3, "both files reached the write stage")

    check(model.batchSavedCount == 1, "the failed write is not counted",
          "\(model.batchSavedCount)")
    check(model.batchCompleted == 2,
          "the failed file still finishes its turn", "\(model.batchCompleted)")
    check(model.statusToken == .batchFinished(saved: 1, total: 2, cropsSkipped: 0),
          "the report says one of two was saved", "\(model.statusToken)")

    let firstOut = folder.appendingPathComponent("\(prefix)-first-retouched.png")
    let secondOut = folder.appendingPathComponent("\(prefix)-second-retouched.png")
    check(readImage(firstOut) != nil, "the real write produced a readable file")
    check(!FileManager.default.fileExists(atPath: secondOut.path),
          "the failed write produced no file")
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
        .filter { $0.hasSuffix(".tmp") || $0.hasSuffix(".part") } ?? []
    check(leftovers.isEmpty, "no temporary files remain", leftovers.joined(separator: ", "))

    // A later batch is unaffected once the test override is gone.
    model.batchFileWriteResultOverride = nil
    let again = workDir.appendingPathComponent("batch-after-writefail-\(prefix)")
    try? FileManager.default.createDirectory(at: again, withIntermediateDirectories: true)
    model.runBatch([firstURL], to: again)
    check(await waitUntil(180) { !model.isBatchRunning && model.batchHasReport },
          "a batch runs normally after a failed write")
    check(model.batchSavedCount == 1
            && model.statusToken == .batchFinished(saved: 1, total: 1, cropsSkipped: 0),
          "the later batch saved its file", "\(model.statusToken)")
}

// MARK: - P1-6 / H-6 / M-3

@MainActor
func testPreviewStaysAtPreviewResolution() async {
    print("\n[P1-6] a slider preview renders the preview copy, not the full photo")

    let url = workDir.appendingPathComponent("preview-resolution.png")
    guard let image = makeImage(width: 3000, height: 2000), writePNG(image, to: url) else {
        check(false, "preview-resolution fixture")
        return
    }

    let model = EditorModel()
    model.load(url: url)
    check(await waitUntil { model.hasImage && !model.isBusy }, "fixture loads")
    check(model.workingPixelSize == CGSize(width: 3000, height: 2000),
          "the full photo is 3000×2000", "\(model.workingPixelSize)")

    let loaded = model.previewImage?.size ?? .zero
    check(max(loaded.width, loaded.height) > 0 && max(loaded.width, loaded.height) <= 1800,
          "the loaded preview is capped at 1800 px",
          "\(Int(loaded.width))×\(Int(loaded.height))")

    model.adjustments.contrast = 20
    model.schedulePreview()
    check(await waitUntil { !model.isBusy }, "the slider preview settles")
    let rendered = model.previewImage?.size ?? .zero
    check(max(rendered.width, rendered.height) > 0
            && max(rendered.width, rendered.height) <= 1800,
          "a slider preview still renders the preview copy",
          "\(Int(rendered.width))×\(Int(rendered.height))")
}

// MARK: - P2-6 / M-6

@MainActor
func testPrivacySettingDefaults() async {
    print("\n[P2-6] privacy stripping defaults on and survives a restart")

    let suite = "RetouchStudio.tests.\(UUID().uuidString)"
    guard let store = UserDefaults(suiteName: suite) else {
        check(false, "temporary preferences")
        return
    }
    defer { store.removePersistentDomain(forName: suite) }

    let fresh = AppSettings(store: store)
    check(fresh.stripLocationMetadata,
          "a fresh install strips location and camera identity")

    fresh.stripLocationMetadata = false
    let reopened = AppSettings(store: store)
    check(!reopened.stripLocationMetadata, "turning it off survives a restart")

    // A preference file written before the key existed has no answer; the
    // missing key must mean the private default, not "keep everything".
    store.removeObject(forKey: "settings.stripLocationMetadata")
    let missing = AppSettings(store: store)
    check(missing.stripLocationMetadata,
          "a preference without the key keeps the private default")

    reopened.resetToDefaults()
    check(reopened.stripLocationMetadata, "Restore Defaults turns the strip back on")
}

// MARK: - Phase 2: AI edits

/// A solid RGBA image, used as synthetic patch pixels.
func solidImage(width: Int, height: Int,
                red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()
}

/// Stages a real pair of files in the edit store: solid patch pixels and an
/// alpha that is opaque only in a centered inset. The inset is the same
/// fraction the worker's dilation leaves inside its rectangle.
func storedAIEdit(box: CGRect, inset: CGFloat = 0.25) -> AIEdit? {
    let side = 64
    guard let patch = solidImage(width: side, height: side, red: 0.92, green: 0.16, blue: 0.08)
    else { return nil }
    let gray = CGColorSpaceCreateDeviceGray()
    guard let alphaContext = CGContext(data: nil, width: side, height: side,
                                       bitsPerComponent: 8, bytesPerRow: 0,
                                       space: gray,
                                       bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return nil }
    alphaContext.setFillColor(gray: 0, alpha: 1)
    alphaContext.fill(CGRect(x: 0, y: 0, width: side, height: side))
    alphaContext.setFillColor(gray: 1, alpha: 1)
    let insetPixels = CGFloat(side) * inset
    alphaContext.fill(CGRect(x: insetPixels, y: insetPixels,
                             width: CGFloat(side) - 2 * insetPixels,
                             height: CGFloat(side) - 2 * insetPixels))
    guard let alpha = alphaContext.makeImage() else { return nil }

    let patchURL = workDir.appendingPathComponent("patch-\(UUID().uuidString).png")
    let alphaURL = workDir.appendingPathComponent("alpha-\(UUID().uuidString).png")
    guard writePNG(patch, to: patchURL), writePNG(alpha, to: alphaURL) else { return nil }
    let id = UUID()
    guard let files = try? AIEditStore.adopt(id: id, patch: patchURL, alpha: alphaURL)
    else { return nil }
    return AIEdit(id: id,
                  preset: "removeObject", prompt: "test", seed: 1,
                  patchFile: files.patch, alphaFile: files.alpha,
                  box: box, imagePixels: CGSize(width: side, height: side))
}

func rgbaBytes(_ image: CGImage) -> [UInt8]? {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let ctx = CGContext(data: &data, width: image.width, height: image.height,
                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                              space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return data
}

func ciBytes(_ image: CIImage, width: Int, height: Int) -> [UInt8]? {
    guard let cg = ImageProcessor.shared.context.createCGImage(
        image, from: CGRect(x: 0, y: 0, width: width, height: height),
        format: .RGBA8, colorSpace: sRGB) else { return nil }
    return rgbaBytes(cg)
}

/// Counts changed pixels outside the authorized box and inside the opaque
/// part of the alpha. `rgbaBytes` dumps rows top-first, the same order as the
/// document's top-left coordinates, so no flip is needed.
func aiDiffStats(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int,
                 box: CGRect, alphaBox: CGRect) -> (outside: Int, insideAlpha: Int) {
    var outside = 0
    var insideAlpha = 0
    for row in 0..<height {
        let y = (Double(row) + 0.5) / Double(height)
        for column in 0..<width {
            let x = (Double(column) + 0.5) / Double(width)
            let offset = (row * width + column) * 4
            let changed = a[offset] != b[offset]
                || a[offset + 1] != b[offset + 1]
                || a[offset + 2] != b[offset + 2]
            guard changed else { continue }
            let point = CGPoint(x: x, y: y)
            if !box.contains(point) {
                outside += 1
            } else if alphaBox.contains(point) {
                insideAlpha += 1
            }
        }
    }
    return (outside, insideAlpha)
}

@MainActor
func testAIEditBoundaries() async {
    print("\n[P2-1] an AI edit changes only its alpha inside the authorized box")

    let box = CGRect(x: 0.25, y: 0.30, width: 0.40, height: 0.30)
    guard let edit = storedAIEdit(box: box) else {
        check(false, "the edit files are staged")
        return
    }
    defer { AIEditStore.remove(edit) }

    let layers = AICompositor.layers([edit], crop: nil)
    check(layers.count == 1, "the layer resolves from the store")

    // The same edit at preview size and at twice that size must cover the same
    // fraction of the frame: the app can re-composite at export size.
    for (width, height) in [(480, 600), (960, 1200)] {
        guard let source = makeImage(width: width, height: height) else {
            check(false, "fixture \(width)×\(height)")
            continue
        }
        let extent = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let base = CIImage(cgImage: source).cropped(to: extent)
        let out = AICompositor.apply(layers, to: base, extent: extent)
        guard let a = rgbaBytes(source), let b = ciBytes(out, width: width, height: height) else {
            check(false, "render \(width)×\(height)")
            continue
        }

        let alphaBox = box.insetBy(dx: box.width * 0.25, dy: box.height * 0.25)
        let stats = aiDiffStats(a, b, width: width, height: height,
                                box: box, alphaBox: alphaBox)
        let expected = alphaBox.width * alphaBox.height * Double(width * height)
        check(stats.outside == 0,
              "\(width)×\(height): byte-identical outside the box",
              "\(stats.outside) px")
        check(Double(stats.insideAlpha) > expected * 0.9,
              "\(width)×\(height): the alpha area is edited",
              "\(stats.insideAlpha) of \(Int(expected)) px")
    }

    // A crop narrows the working frame; the edit's photo coordinates must move
    // with it instead of staying at the same place on screen.
    let moved = AICompositor.workingBox(CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25),
                                        crop: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    check(moved == CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
          "a box maps through the crop", "\(moved)")
}

@MainActor
func testAIProjectRoundTrip() async {
    print("\n[P2-2] a project carries its AI edits and reports missing pixels")

    guard let edit = storedAIEdit(box: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)) else {
        check(false, "the edit files are staged")
        return
    }
    defer { AIEditStore.remove(edit) }

    let project = RetouchProject(imagePath: "/tmp/photo.jpg",
                                 adjustments: Adjustments(),
                                 exportFormat: "png", exportQuality: 0.9,
                                 autoRetouchStrength: 70, aiEdits: [edit])
    guard let encoded = try? JSONEncoder().encode(project),
          let decoded = try? JSONDecoder().decode(RetouchProject.self, from: encoded) else {
        check(false, "the project encodes and decodes")
        return
    }
    check(decoded.version == RetouchProject.currentVersion && decoded.version >= 2,
          "the project is written at the current version")
    check(decoded.aiEdits == [edit], "every AI edit survives the round trip")

    // A file written before AI edits existed has no key at all. It must open
    // with the tool off, not fail.
    guard var object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    else {
        check(false, "the project is valid JSON")
        return
    }
    object.removeValue(forKey: "aiEdits")
    object["version"] = 1
    guard let legacy = try? JSONSerialization.data(withJSONObject: object),
          let old = try? JSONDecoder().decode(RetouchProject.self, from: legacy) else {
        check(false, "a version-1 project still decodes")
        return
    }
    check(old.aiEdits == nil, "an older project opens with no AI edits")

    AIEditStore.remove(edit)
    check(AICompositor.missing([edit]).count == 1, "a removed edit is reported")
    check(AICompositor.layers([edit], crop: nil).isEmpty,
          "a removed edit is not composited")
}

@MainActor
func testAIEditUndoAndExport() async {
    print("\n[P2-3] an AI edit is one undo step and reaches the export")

    let sourceURL = workDir.appendingPathComponent("ai-source.png")
    check(makeImage(width: 480, height: 600).map { writePNG($0, to: sourceURL) } ?? false,
          "fixture written")

    let model = EditorModel()
    model.exportFormat = .png
    model.load(url: sourceURL)
    check(await waitUntil { model.hasImage && !model.isBusy }, "fixture loads")

    let baseURL = workDir.appendingPathComponent("ai-base.png")
    model.export(to: baseURL)
    check(await waitUntil(120) {
        FileManager.default.fileExists(atPath: baseURL.path) && !model.isBusy
    }, "baseline export finishes")
    check(model.isDocumentPristine, "the baseline is pristine")

    let box = CGRect(x: 0.30, y: 0.35, width: 0.40, height: 0.30)
    guard let edit = storedAIEdit(box: box) else {
        check(false, "the edit files are staged")
        return
    }
    defer { AIEditStore.remove(edit) }

    model.addAIEdit(edit)
    check(model.aiEdits.count == 1 && !model.isDocumentPristine,
          "the edit joins the document")
    check(model.canUndo, "the toolbar offers undo for the new edit")
    check(await waitUntil { !model.isBusy }, "the preview settles")

    let editedURL = workDir.appendingPathComponent("ai-edited.png")
    model.export(to: editedURL)
    check(await waitUntil(120) {
        FileManager.default.fileExists(atPath: editedURL.path) && !model.isBusy
    }, "edited export finishes")

    guard let base = readImage(baseURL), let edited = readImage(editedURL),
          let a = rgbaBytes(base), let b = rgbaBytes(edited) else {
        check(false, "both exports decode")
        return
    }
    let alphaBox = box.insetBy(dx: box.width * 0.25, dy: box.height * 0.25)
    let stats = aiDiffStats(a, b, width: 480, height: 600, box: box, alphaBox: alphaBox)
    check(stats.outside == 0,
          "the export is byte-identical outside the authorized box",
          "\(stats.outside) px")
    let expected = alphaBox.width * alphaBox.height * 480 * 600
    check(Double(stats.insideAlpha) > expected * 0.9,
          "the edit is present in the exported file",
          "\(stats.insideAlpha) of \(Int(expected)) px")

    // Undo has to be pixel-stable, not only a list change: the undone document
    // must export exactly what it exported before the edit existed.
    model.undo()
    check(model.aiEdits.isEmpty, "one undo removes the edit")
    let undoneURL = workDir.appendingPathComponent("ai-undone.png")
    model.export(to: undoneURL)
    check(await waitUntil(120) {
        FileManager.default.fileExists(atPath: undoneURL.path) && !model.isBusy
    }, "undone export finishes")
    if let undone = readImage(undoneURL).flatMap(rgbaBytes) {
        let undoneStats = aiDiffStats(a, undone, width: 480, height: 600,
                                      box: box, alphaBox: alphaBox)
        check(undoneStats.outside == 0 && undoneStats.insideAlpha == 0,
              "undo restores the earlier pixels exactly")
    } else {
        check(false, "the undone export decodes")
    }

    model.redo()
    check(model.aiEdits.count == 1, "redo restores it")
    let redoneURL = workDir.appendingPathComponent("ai-redone.png")
    model.export(to: redoneURL)
    check(await waitUntil(120) {
        FileManager.default.fileExists(atPath: redoneURL.path) && !model.isBusy
    }, "redone export finishes")
    if let redone = readImage(redoneURL).flatMap(rgbaBytes) {
        // The redone document must export the same bytes the first edited
        // export produced, not merely "some edit somewhere".
        let diff = zip(b, redone).lazy.filter { $0 != $1 }.count
        check(diff == 0, "redo reproduces the edited pixels", "\(diff) bytes differ")
    } else {
        check(false, "the redone export decodes")
    }

    model.removeLastAIEdit()
    check(model.aiEdits.isEmpty, "the last edit can be removed")
}

// MARK: - Phase 3: selection masks

func grayLevel(_ image: CGImage, x: Int, y: Int) -> Int? {
    guard let data = image.dataProvider?.data as Data? else { return nil }
    let offset = y * image.bytesPerRow + x
    guard offset >= 0, offset < data.count else { return nil }
    return Int(data[offset])
}

func alphaLevel(_ image: CGImage, x: Int, y: Int) -> Int? {
    let width = image.width, height = image.height
    guard let ctx = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let raw = ctx.data else { return nil }
    return Int(raw.load(fromByteOffset: y * width * 4 + x * 4 + 3, as: UInt8.self))
}

func isWhite(_ level: Int?) -> Bool { (level ?? -1) >= 250 }
func isBlack(_ level: Int?) -> Bool { (level ?? 256) <= 5 }

@MainActor
func testAIMaskRenderer() async {
    print("\n[P3] the selection mask keeps its orientation, erase and invert")

    let size = CGSize(width: 100, height: 100)
    // Normalized top-left box: white pixels must land in the top-left corner,
    // even though CGContext counts rows from the bottom.
    let box = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
    guard let boxMask = AIMaskRenderer.mask(size: size, strokes: [], box: box,
                                            refined: nil, inverted: false) else {
        check(false, "box mask renders")
        return
    }
    check(boxMask.width == 100 && boxMask.height == 100, "the mask matches the photo size")
    check(isWhite(grayLevel(boxMask, x: 20, y: 15)), "the box is white at the top-left")
    check(isBlack(grayLevel(boxMask, x: 20, y: 90)), "the same column is black at the bottom")
    check(isBlack(grayLevel(boxMask, x: 80, y: 20)), "the same row is black at the right")

    // A brush point at the center of the photo, one tenth of the width across.
    let dot = AIMaskStroke(points: [CGPoint(x: 0.5, y: 0.5)], width: 0.1, erase: false)
    guard let dotMask = AIMaskRenderer.mask(size: size, strokes: [dot], box: nil,
                                            refined: nil, inverted: false) else {
        check(false, "stroke mask renders")
        return
    }
    check(isWhite(grayLevel(dotMask, x: 50, y: 50)), "a brush dot is white where it was drawn")
    check(isBlack(grayLevel(dotMask, x: 50, y: 20)), "the dot does not leak upward")
    check(isBlack(grayLevel(dotMask, x: 20, y: 50)), "the dot does not leak sideways")

    // Erasing must carve the previous coverage back to black.
    let wipe = AIMaskStroke(points: [CGPoint(x: 0.5, y: 0.3), CGPoint(x: 0.5, y: 0.7)],
                            width: 0.2, erase: true)
    guard let erased = AIMaskRenderer.mask(size: size, strokes: [dot, wipe], box: nil,
                                           refined: nil, inverted: false) else {
        check(false, "erase mask renders")
        return
    }
    check(isBlack(grayLevel(erased, x: 50, y: 50)), "an erase stroke clears the dot")

    // Invert swaps what may change without moving anything else.
    guard let inverted = AIMaskRenderer.mask(size: size, strokes: [], box: box,
                                             refined: nil, inverted: true) else {
        check(false, "inverted mask renders")
        return
    }
    check(isBlack(grayLevel(inverted, x: 20, y: 15)), "invert clears the box")
    check(isWhite(grayLevel(inverted, x: 80, y: 80)), "invert fills the rest")

    guard let alpha = AIMaskRenderer.alphaMask(boxMask) else {
        check(false, "the preview alpha plane renders")
        return
    }
    check(alphaLevel(alpha, x: 20, y: 15) == 255, "the preview is opaque inside the box")
    check(alphaLevel(alpha, x: 80, y: 80) == 0, "the preview is clear outside the box")
}

@MainActor
func testQuickEditSelectionGating() async {
    print("\n[P3] Quick Edit needs a selection, and heal needs a mask")

    let url = workDir.appendingPathComponent("mask-gating.png")
    guard let image = makeImage(width: 640, height: 480), writePNG(image, to: url) else {
        check(false, "mask-gating fixture")
        return
    }
    let model = EditorModel()
    model.load(url: url)
    check(await waitUntil { model.hasImage && !model.isBusy }, "fixture loads")

    check(!model.canRunQuickEdit, "no run without a point or a mask")

    model.beginQuickEdit()
    check(model.isAIPicking, "begin starts picking")
    model.placeQuickEditPoint(CGPoint(x: 0.5, y: 0.5))
    check(model.canRunQuickEdit, "a point is enough for Remove object")
    check(model.aiMaskPreview == nil, "a point alone paints no mask")

    model.selectQuickEditPreset(.healArea)
    check(model.quickEditPoint == nil, "switching to heal drops the point")
    check(!model.canRunQuickEdit, "heal cannot run from a point")
    check(model.aiMaskTool == .brush, "heal selects the brush")

    model.selectAIMaskTool(.brush)
    model.appendMaskStroke(AIMaskStroke(
        points: [CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.6, y: 0.6)],
        width: 0.04, erase: false))
    check(model.canRunQuickEdit, "a stroke enables heal")
    check(model.aiMaskPreview != nil, "the stroke paints a preview")
    check(model.aiMaskPreview?.width == Int(model.previewSize.width),
          "the preview plane matches the preview size")

    model.aiMaskInverted = true
    check(model.aiMaskPreview != nil, "inverting keeps the preview")
    model.aiMaskInverted = false

    model.clearAIMask()
    check(!model.aiMaskHasSelection, "Clear empties the mask")
    check(!model.canRunQuickEdit, "Clear disables Run again")
    check(model.aiMaskPreview == nil, "Clear removes the preview")

    // Reimagine is the one preset that redraws the frame, so it must not be
    // held to the selection rule the other two live by.
    model.beginQuickEdit()
    model.placeQuickEditPoint(CGPoint(x: 0.5, y: 0.5))
    model.selectQuickEditPreset(.reimagine)
    check(model.quickEditPreset.isFullFrame && !model.quickEditPreset.needsSelection,
          "reimagine is a full-frame preset")
    check(model.quickEditPoint == nil && !model.isAIPicking,
          "switching to reimagine drops the point and the picking mode")
    check(model.canRunQuickEdit, "reimagine runs without a selection")
    model.selectQuickEditPreset(.removeObject)
    check(!model.canRunQuickEdit, "a masked preset still needs a selection")
}

/// A full-frame edit is one opaque layer over the whole frame: every pixel is
/// new, and undo still has to restore the earlier bytes exactly.
@MainActor
func testFullFrameReimagine() async {
    print("\n[P5] a full-frame edit covers the picture and undoes in one step")

    let url = workDir.appendingPathComponent("reimagine-source.png")
    guard let image = makeImage(width: 480, height: 600), writePNG(image, to: url) else {
        check(false, "reimagine fixture")
        return
    }
    let model = EditorModel()
    model.exportFormat = .png
    model.load(url: url)
    check(await waitUntil { model.hasImage && !model.isBusy }, "fixture loads")

    let baseURL = workDir.appendingPathComponent("reimagine-base.png")
    model.export(to: baseURL)
    check(await waitUntil(120) {
        FileManager.default.fileExists(atPath: baseURL.path) && !model.isBusy
    }, "baseline export finishes")

    guard let edit = storedAIEdit(box: CGRect(x: 0, y: 0, width: 1, height: 1), inset: 0)
    else {
        check(false, "the full-frame edit files are staged")
        return
    }
    defer { AIEditStore.remove(edit) }

    model.addAIEdit(edit)
    check(await waitUntil { !model.isBusy }, "the preview settles")

    let editedURL = workDir.appendingPathComponent("reimagine-edited.png")
    model.export(to: editedURL)
    check(await waitUntil(120) {
        FileManager.default.fileExists(atPath: editedURL.path) && !model.isBusy
    }, "edited export finishes")

    guard let base = readImage(baseURL), let edited = readImage(editedURL),
          let a = rgbaBytes(base), let b = rgbaBytes(edited) else {
        check(false, "both exports decode")
        return
    }
    let changed = zip(a, b).lazy.enumerated().filter { $0.offset % 4 != 3 && $0.element.0 != $0.element.1 }.count
    let total = 480 * 600 * 3
    check(Double(changed) > Double(total) * 0.9,
          "the edit reaches the whole frame", "\(changed) of \(total) channels")

    model.undo()
    check(model.aiEdits.isEmpty, "one undo removes the full-frame edit")
    let undoneURL = workDir.appendingPathComponent("reimagine-undone.png")
    model.export(to: undoneURL)
    check(await waitUntil(120) {
        FileManager.default.fileExists(atPath: undoneURL.path) && !model.isBusy
    }, "undone export finishes")
    if let undone = readImage(undoneURL).flatMap(rgbaBytes) {
        let diff = zip(a, undone).lazy.filter { $0 != $1 }.count
        check(diff == 0, "undo restores the whole frame exactly", "\(diff) bytes differ")
    } else {
        check(false, "the undone export decodes")
    }
}

// MARK: - runner

@MainActor
func testExportUpscalePolicy() async {
    print("\n[P4-1] the upscaler's limits match what the helper will accept")

    // Swin2SR is fixed at 4x and the helper refuses more than 40 MP out, so a
    // full pass is only offered up to 2.5 MP in. Both numbers live here so the
    // sheet can refuse in the same terms before a job is queued.
    check(ExportUpscale.factor == 4, "the pass is four times the pixels per axis")
    check(ExportUpscale.canHandle(CGSize(width: 1500, height: 1500)),
          "2.25 MP fits the 4x ceiling", "\(6000 * 6000) px out")
    check(!ExportUpscale.canHandle(CGSize(width: 1600, height: 1600)),
          "the first size past 2.5 MP is refused", "\(6400 * 6400) px out")
    check(ExportUpscale.canHandle(CGSize(width: 400, height: 300)),
          "a small photo is accepted")
    check(!ExportUpscale.canHandle(CGSize(width: 0, height: 300)),
          "an empty size is refused")

    check(ExportUpscale.outputLongEdge(sourceLong: 1000, requested: 4096) == 4000,
          "4x wins when the request is above it", "1000 -> 4000")
    check(ExportUpscale.outputLongEdge(sourceLong: 1000, requested: 2048) == 2048,
          "the requested edge wins below 4x", "1000 -> 2048")
    check(ExportUpscale.outputLongEdge(sourceLong: 1000, requested: nil) == 4000,
          "no request means the full 4x")
}

// MARK: - Portable geometry

@MainActor
func testStudioGeometryBridge() {
    print("\n[R3] portable geometry reaches CoreGraphics without changing a bit")

    let point = CGPoint(x: 0.1, y: -0.25)
    let bridgedPoint = StudioPoint(point)
    check(bridgedPoint == StudioPoint(x: 0.1, y: -0.25), "a point keeps its components")
    check(bridgedPoint.cgPoint == point, "the point round-trips")
    check(bridgedPoint.cgPoint.x.bitPattern == point.x.bitPattern
          && bridgedPoint.cgPoint.y.bitPattern == point.y.bitPattern,
          "the point bits are identical")

    let size = CGSize(width: 1600, height: 1067)
    let bridgedSize = StudioSize(size)
    check(bridgedSize == StudioSize(width: 1600, height: 1067),
          "a size keeps its components")
    check(bridgedSize.cgSize == size, "the size round-trips")
    check(bridgedSize.cgSize.width.bitPattern == size.width.bitPattern
          && bridgedSize.cgSize.height.bitPattern == size.height.bitPattern,
          "the size bits are identical")

    let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.25)
    let bridgedRect = StudioRect(rect)
    check(bridgedRect == StudioRect(x: 0.1, y: 0.2, width: 0.3, height: 0.25),
          "a rectangle keeps its origin and extents")
    check(bridgedRect.cgRect == rect, "the rectangle round-trips")
    check(bridgedRect.cgRect.origin.x.bitPattern == rect.origin.x.bitPattern
          && bridgedRect.cgRect.size.height.bitPattern == rect.size.height.bitPattern,
          "the rectangle bits are identical")

    let draft = CGRect(x: 0.75, y: 0.9, width: -0.25, height: -0.4)
    let bridgedDraft = StudioRect(draft)
    check(bridgedDraft.cgRect == draft, "a negative-extent draft round-trips")
    check(bridgedDraft.cgRect.origin.x == 0.75
          && bridgedDraft.cgRect.size.width == -0.25,
          "the bridge does not standardize or clamp")
    check(bridgedDraft.standardized() != bridgedDraft,
          "standardizing stays an explicit call")
}

// MARK: - Orientation

@MainActor
func testOrientationKeepsEditsAttached() async {
    print("\n[R1] rotating and flipping keep every edit on its pixel")

    let sourceURL = workDir.appendingPathComponent("orientation-source.png")
    check(makeImage(width: 480, height: 600).map { writePNG($0, to: sourceURL) } ?? false,
          "fixture written")

    let model = EditorModel()
    model.load(url: sourceURL)
    check(await waitUntil { model.hasImage && !model.isBusy }, "fixture loads")
    check(model.workingPixelSize == CGSize(width: 480, height: 600), "starts portrait")

    model.tapHeal(at: CGPoint(x: 0.25, y: 0.25))
    model.tapArt(at: CGPoint(x: 0.75, y: 0.75))
    check(await waitUntil { !model.isBusy }, "stamp preview settles")

    model.cropDraft = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
    model.applyCrop()
    check(await waitUntil { !model.isBusy && model.appliedCrop != nil },
          "a top-left crop is applied")
    check(abs((model.appliedCrop?.width ?? 0) - 0.5) < 0.001, "the crop is the quarter asked for")

    model.rotateClockwise()
    check(await waitUntil { !model.isBusy && model.documentOrientation.quarterTurns == 1 },
          "the frame turns clockwise")
    check(model.workingPixelSize == CGSize(width: 300, height: 240),
          "the cropped working frame swapped sides", "\(model.workingPixelSize)")
    let turnedCrop = model.appliedCrop ?? .zero
    check(abs(turnedCrop.minX - 0.5) < 0.001 && abs(turnedCrop.minY) < 0.001
            && abs(turnedCrop.width - 0.5) < 0.001 && abs(turnedCrop.height - 0.5) < 0.001,
          "the top-left crop moved to the top-right", "\(turnedCrop)")
    let healed = model.healSpots.first?.center ?? .zero
    check(abs(healed.x - 0.75) < 0.001 && abs(healed.y - 0.25) < 0.001,
          "the healing stamp turned with the photo", "\(healed)")
    let art = model.stickers.first?.center ?? .zero
    check(abs(art.x - 0.25) < 0.001 && abs(art.y - 0.75) < 0.001,
          "the sticker turned with the photo", "\(art)")

    model.undo()
    check(await waitUntil { !model.isBusy && model.documentOrientation == .identity },
          "one undo puts the frame back")
    check(model.workingPixelSize == CGSize(width: 240, height: 300),
          "the cropped portrait frame is back")
    check(abs((model.healSpots.first?.center.x ?? 0) - 0.25) < 0.001,
          "the stamp is back on its original pixel")

    let radiusBefore = model.healSpots.first?.radius ?? 0
    model.setStraightenAngle(12)
    check(await waitUntil { !model.isBusy && abs(model.straightenAngle - 12) < 0.01 },
          "the straighten slider commits one turn")
    check(model.workingPixelSize == CGSize(width: 240, height: 300),
          "straighten keeps the frame size")
    let grownRadius = model.healSpots.first?.radius ?? 0
    check(radiusBefore > 0 && grownRadius > radiusBefore,
          "the stamp grows with the upscaled pixels", "\(radiusBefore) -> \(grownRadius)")

    model.undo()
    check(await waitUntil { !model.isBusy && model.documentOrientation == .identity },
          "undo removes the straighten")
}

// MARK: - M-12

/// An analysis export is lines over a face. With no face there is nothing to
/// draw, so the suggested name must not promise an analysis artifact.
@MainActor
func testAnalysisExportNeedsFace() async {
    print("\n[M-12] the analysis export waits for a detected face")

    let model = EditorModel()
    model.analysis.isEnabled = true
    model.analysis.exportMode = .overlayOnly
    model.exportFormat = .jpeg

    check(model.faces.isEmpty, "no faces before a photo is open")
    let name = model.suggestedFileName()
    check(!name.lowercased().contains("analysis"),
          "the suggested name does not promise analysis", name)
    check(name.hasSuffix(".\(model.exportFormat.fileExtension)"),
          "the ordinary format is kept without a face", name)
}

// MARK: - Milestone 1: data integrity

struct RuntimeTestFailure: Error {}

/// Counts how many times a test hook may still reject a path. A rollback
/// validates the restored copy through the same hook, so a rejection must be
/// one-shot to model a bad new runtime rather than a broken hook.
final class RuntimeVerifyPlan {
    let root: URL
    var armed = false
    var remainingRejections: Int

    init(root: URL, rejections: Int = 1) {
        self.root = root
        self.remainingRejections = rejections
    }

    func shouldReject(_ candidate: URL) -> Bool {
        guard armed, remainingRejections > 0,
              candidate.standardizedFileURL == root.standardizedFileURL else { return false }
        remainingRejections -= 1
        if remainingRejections == 0 { armed = false }
        return true
    }
}

func fileBytes(_ url: URL) -> Data? {
    try? Data(contentsOf: url)
}

/// A fixture that passes the structural contract. It is not a real Python, so
/// tests replace the functional hook; this keeps the transaction tests offline
/// and bounded while still exercising the layout the real runtime must have.
func makeFakeRuntime(at root: URL, marker: String) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: root.appendingPathComponent("bin"),
                                withIntermediateDirectories: true)
    let python = root.appendingPathComponent("bin/python3")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: python)
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    let worker = root.appendingPathComponent("retouch_ai_worker", isDirectory: true)
    try manager.createDirectory(at: worker, withIntermediateDirectories: true)
    for name in ["__main__.py", "server.py", "engine.py"] {
        try Data("# fake\n".utf8).write(to: worker.appendingPathComponent(name))
    }
    try manager.createDirectory(at: root.appendingPathComponent("site-packages",
                                                                isDirectory: true),
                                withIntermediateDirectories: true)
    try manager.createDirectory(
        at: root.appendingPathComponent("Python.framework/Versions/3.13",
                                        isDirectory: true),
        withIntermediateDirectories: true)
    try Data(marker.utf8).write(to: root.appendingPathComponent("marker.txt"))
}

/// Install hooks for fixture runtimes: extraction comes from the test, the
/// structural contract is the real one, and the functional stage is stubbed
/// unless the test supplies its own decision.
func fakeRuntimeHooks(
    extract: @escaping (URL, URL) throws -> Void,
    functional: ((URL) -> RuntimeValidationReport)? = nil
) -> AIRuntime.InstallHooks {
    var hooks = AIRuntime.InstallHooks()
    hooks.extract = extract
    hooks.validateRuntime = { root in
        if let functional { return functional(root) }
        let layout = AIRuntimeValidation.structural(root: root)
        guard layout.ok else { return layout }
        return RuntimeValidationReport.success(.functional)
    }
    return hooks
}

func recoveryHooks(
    functional: ((URL) -> RuntimeValidationReport)? = nil
) -> AIRuntime.InstallHooks {
    fakeRuntimeHooks(extract: { _, _ in throw RuntimeTestFailure() },
                     functional: functional)
}

/// Writes a durable marker exactly as the transaction would, for recovery tests
/// that start from a state a crash left behind.
func writeTransactionMarker(in support: URL, id: String, state: String,
                            hadPrevious: Bool, extra: [String: Any] = [:]) throws {
    var object: [String: Any] = [
        "id": id,
        "state": state,
        "had_previous": hadPrevious,
        "created": "2026-11-10T00:00:00Z",
    ]
    for (key, value) in extra { object[key] = value }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try data.write(to: support.appendingPathComponent("runtime-transaction.json"),
                   options: .atomic)
}

func transactionMarker(in support: URL) -> [String: Any]? {
    let url = support.appendingPathComponent("runtime-transaction.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

func transactionState(in support: URL) -> String? {
    transactionMarker(in: support)?["state"] as? String
}

func hasBackupDirectory(in support: URL) -> Bool {
    FileManager.default.fileExists(atPath: AIRuntime.backupDirectory(in: support).path)
}

func hasRejectedDirectory(in support: URL) -> Bool {
    let prefix = AIRuntime.installDirectory(in: support).lastPathComponent + "-rejected-"
    let entries = (try? FileManager.default.contentsOfDirectory(
        at: support, includingPropertiesForKeys: nil)) ?? []
    return entries.contains { $0.lastPathComponent.hasPrefix(prefix) }
}

func copyContents(of source: URL, into destination: URL) throws {
    let manager = FileManager.default
    for item in try manager.contentsOfDirectory(at: source,
                                                 includingPropertiesForKeys: nil) {
        try manager.copyItem(at: item,
                             to: destination.appendingPathComponent(item.lastPathComponent))
    }
}

func marker(at root: URL) -> String? {
    guard let data = try? Data(contentsOf: root.appendingPathComponent("marker.txt"))
    else { return nil }
    return String(data: data, encoding: .utf8)
}

func hasStagingDirectory(in support: URL) -> Bool {
    let manager = FileManager.default
    let prefix = AIRuntime.installDirectory(in: support).lastPathComponent + "-installing-"
    let entries = (try? manager.contentsOfDirectory(at: support,
                                                     includingPropertiesForKeys: nil)) ?? []
    return entries.contains { $0.lastPathComponent.hasPrefix(prefix) }
}

/// Every entry under the production recovery tree, captured before the suite
/// starts and compared at the end. Reading them is safe; nothing here writes.
struct RecoveryFingerprint: Equatable {
    struct Entry: Equatable {
        let path: String
        let isDirectory: Bool
        let size: Int?
        let modified: Date?
        let hash: String?
    }

    let rootExists: Bool
    let entries: [Entry]

    static func capture(_ directory: URL) -> RecoveryFingerprint {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path),
              let enumerator = manager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey,
                                             .contentModificationDateKey],
                options: []) else {
            return RecoveryFingerprint(rootExists: false, entries: [])
        }
        var entries: [Entry] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey,
                                                           .contentModificationDateKey])
            let isDirectory = values?.isDirectory ?? false
            let relative = url.pathComponents
                .dropFirst(directory.pathComponents.count)
                .joined(separator: "/")
            entries.append(Entry(path: relative,
                                 isDirectory: isDirectory,
                                 size: isDirectory ? nil : values?.fileSize,
                                 modified: values?.contentModificationDate,
                                 hash: isDirectory ? nil : (try? AIRuntime.sha256(of: url))))
        }
        return RecoveryFingerprint(rootExists: true,
                                   entries: entries.sorted { $0.path < $1.path })
    }
}

/// Invalidates a debounced write left behind by the previous test and clears
/// the scratch store. The epoch check makes this deterministic: no sleep is
/// needed before the next scenario installs fixtures.
@MainActor
func settleRecoveryWrites() async {
    RecoveryStore.clearAll()
}

// MARK: - Recovery candidates
//
// The store keeps one mutable working slot and any number of immutable
// candidates. These tests drive the real launch and restore paths and compare
// the bytes on disk, so a regression that deletes or overwrites a candidate
// fails here instead of only flipping a state flag.

@MainActor
func testRecoveryChoiceMapping() {
    print("\n[M1-R0] Escape and Cancel never delete a recovery copy")

    // Escape and a closed alert both arrive as .abort. Only the explicit
    // third button may be destructive.
    check(EditorModel.missingSourceChoice(for: .abort) == .cancel,
          "Escape/close on the Locate prompt cancels")
    check(EditorModel.restoreChoice(for: .abort) == .cancel,
          "Escape/close on the Restore prompt cancels")
    check(EditorModel.missingSourceChoice(for: .alertSecondButtonReturn) == .cancel,
          "the Cancel button on the Locate prompt cancels")
    check(EditorModel.restoreChoice(for: .alertSecondButtonReturn) == .cancel,
          "the Cancel button on the Restore prompt cancels")
    check(EditorModel.missingSourceChoice(for: .alertThirdButtonReturn) == .discard,
          "the explicit Discard response is recognized")
    check(EditorModel.restoreChoice(for: .alertThirdButtonReturn) == .discard,
          "the explicit Discard response is recognized")
}

@MainActor
func testRecoveryPolicyDecisions() {
    print("\n[R4.7] recovery decisions keep their rules without a store")

    let base = Date(timeIntervalSince1970: 1_700_000_000)
    check(RecoveryPolicy.olderFirst(.init(savedAt: base, name: "b"),
                                    .init(savedAt: base.addingTimeInterval(1), name: "a")),
          "an earlier date is offered first")
    check(RecoveryPolicy.olderFirst(.init(savedAt: base, name: "a"),
                                    .init(savedAt: base, name: "b")),
          "the name breaks a same-millisecond tie")
    check(!RecoveryPolicy.olderFirst(.init(savedAt: base, name: "b"),
                                     .init(savedAt: base, name: "a")),
          "the tie-break is not reversed")
    check(!RecoveryPolicy.olderFirst(.init(savedAt: base, name: "a"),
                                     .init(savedAt: base, name: "a")),
          "a candidate never sorts before itself")

    check(RecoveryPolicy.isCandidateFileName("0000000000000-abc.retouch"),
          "a candidate copy is recognized")
    check(!RecoveryPolicy.isCandidateFileName(".hidden.retouch"),
          "a dotfile left by the file system is not a candidate")
    check(!RecoveryPolicy.isCandidateFileName("snapshot.json"),
          "an unrelated file is not a candidate")
    check(!RecoveryPolicy.isCandidateFileName(".retouch"),
          "a leading-dot name has no candidate extension")

    let photo = URL(fileURLWithPath: "/tmp/policy-photo.png")
    let project = RetouchProject(imagePath: photo.path, adjustments: .zero,
                                 exportFormat: "png", exportQuality: 0.8,
                                 autoRetouchStrength: 60)
    let identity = RecoverySourceIdentity(bytes: 10, modified: base)
    let snapshot = RecoverySnapshot(project: project, savedAt: base,
                                    source: identity, version: 1)
    let encoder = JSONEncoder()
    if let data = try? encoder.encode(snapshot),
       let decoded = RecoveryPolicy.snapshot(from: data, modified: nil) {
        check(decoded.version == 1 && decoded.savedAt == base && decoded.source == identity,
              "a version 1 snapshot keeps its date and identity")
    } else {
        check(false, "a version 1 snapshot decodes")
    }
    if let data = try? encoder.encode(project),
       let legacy = RecoveryPolicy.snapshot(from: data, modified: base) {
        check(legacy.version == 0 && legacy.source == nil && legacy.savedAt == base,
              "a bare project decodes as legacy version 0")
    } else {
        check(false, "a bare project decodes as a legacy snapshot")
    }
    check(RecoveryPolicy.snapshot(from: Data("not a snapshot".utf8), modified: nil) == nil,
          "unreadable bytes are not a snapshot")

    check(RecoveryPolicy.sourceState(url: nil, recorded: identity, version: 1,
                                     current: nil) == .missing,
          "no photo at all is missing")
    check(RecoveryPolicy.sourceState(url: photo, recorded: nil, version: 0,
                                     current: nil) == .available(photo),
          "a legacy copy is offered without an identity")
    check(RecoveryPolicy.sourceState(url: photo, recorded: nil, version: 1,
                                     current: nil) == .changed(photo),
          "a new copy with no identity is not proven to match")
    check(RecoveryPolicy.sourceState(url: photo, recorded: identity, version: 1,
                                     current: identity) == .available(photo),
          "the same size and date is the same photo")
    check(RecoveryPolicy.sourceState(url: photo, recorded: identity, version: 1,
                                     current: .init(bytes: 11, modified: base)) == .changed(photo),
          "a different identity is a changed photo")
    check(RecoveryPolicy.sourceState(url: photo, recorded: identity, version: 1,
                                     current: nil) == .available(photo),
          "an unreadable identity does not claim the photo changed")

    check(RecoveryPolicy.monotonic(base, after: nil) == base,
          "the first legacy copy keeps its date")
    check(RecoveryPolicy.monotonic(base, after: base) == base.addingTimeInterval(0.001),
          "an equal date is pushed past the previous copy")
    let later = base.addingTimeInterval(2)
    check(RecoveryPolicy.monotonic(later, after: base) == later,
          "a later date is not changed")

    let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    check(RecoveryPolicy.quarantineFileName(base: "snap", pathExtension: "retouch", id: id)
            == "snap-11111111-1111-1111-1111-111111111111.retouch",
          "a quarantined copy keeps its name and extension")
    check(RecoveryPolicy.quarantineFileName(base: "snap", pathExtension: "", id: id)
            == "snap-11111111-1111-1111-1111-111111111111",
          "a quarantined file without an extension keeps its base")
    check(RecoveryPolicy.quarantineFileName(base: "snap", pathExtension: "retouch", id: UUID())
            != RecoveryPolicy.quarantineFileName(base: "snap", pathExtension: "retouch", id: UUID()),
          "two damaged copies cannot collide")

    var gate = RecoveryPolicy.AutosaveEpoch()
    check(gate.accepts(0), "a fresh epoch accepts its generation")
    gate.invalidate()
    check(!gate.accepts(0) && gate.accepts(1),
          "invalidation rejects a task that captured the old generation")
}

func recoveryFixture(_ name: String, width: Int, height: Int) -> URL? {
    let url = workDir.appendingPathComponent(name)
    guard let image = makeImage(width: width, height: height),
          writePNG(image, to: url) else { return nil }
    return url
}

func recoveryProject(for url: URL, exposure: Double = 0, contrast: Double = 0,
                     crop: CGRect? = nil,
                     orientation: DocumentOrientation? = nil,
                     healSpots: [HealSpot]? = nil) -> RetouchProject {
    var adjustments = Adjustments()
    adjustments.exposure = exposure
    adjustments.contrast = contrast
    return RetouchProject(imagePath: url.path, adjustments: adjustments,
                          exportFormat: "png", exportQuality: 0.81,
                          autoRetouchStrength: 63, crop: crop,
                          healSpots: healSpots, orientation: orientation)
}

func recoveryBytes(_ url: URL) -> Data? {
    try? Data(contentsOf: url)
}

@MainActor
func stageRecoveryCandidate(for url: URL, exposure: Double = 0, contrast: Double = 0,
                            crop: CGRect? = nil,
                            orientation: DocumentOrientation? = nil,
                            healSpots: [HealSpot]? = nil,
                            savedAt: Date) -> URL? {
    let project = recoveryProject(for: url, exposure: exposure, contrast: contrast,
                                  crop: crop, orientation: orientation, healSpots: healSpots)
    return RecoveryStore.saveCandidate(RecoverySnapshot.capture(project, savedAt: savedAt))
}

@MainActor
func recoveryCandidates() -> [RecoveryStore.Candidate] {
    RecoveryStore.loadCandidates().candidates
}

@MainActor
func testRestoreLeavesSameImageCandidateIntact() async {
    print("\n[M1-R1] restoring one candidate leaves another copy of the same photo intact")

    await settleRecoveryWrites()

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    settings.recoveryEnabled = true
    defer { settings.recoveryEnabled = previousRecoverySetting }

    guard let source = recoveryFixture("c1-same.png", width: 320, height: 400) else {
        check(false, "same-photo fixture written")
        return
    }
    let base = Date().addingTimeInterval(-60)
    guard let older = stageRecoveryCandidate(for: source, exposure: 0.2, savedAt: base),
          let newer = stageRecoveryCandidate(for: source, exposure: 0.7,
                                             savedAt: base.addingTimeInterval(1)) else {
        check(false, "both same-photo candidates written")
        return
    }
    guard let newerBefore = recoveryBytes(newer) else {
        check(false, "newer candidate readable")
        return
    }

    var prompts = 0
    let model = EditorModel()
    model.recoveryChoiceHandler = { _, _ in
        prompts += 1
        return prompts == 1 ? .restore : .cancel
    }
    model.offerRecoveryIfNeeded()
    check(await waitUntil(60) { model.hasImage && !model.isBusy },
          "the older candidate restores")
    check(model.adjustments.exposure == 0.2,
          "the restored document carries the older candidate's edits")
    check(!FileManager.default.fileExists(atPath: older.path),
          "the restored candidate is resolved")
    check(FileManager.default.fileExists(atPath: newer.path),
          "the other candidate for the same photo still exists")
    check(recoveryBytes(newer) == newerBefore,
          "the other candidate is byte-identical after the restore")
    check(RecoveryStore.readWorking()?.project.imagePath == source.path,
          "the restored document is durable in the working slot")
    check(RecoveryStore.readWorking()?.project.adjustments.exposure == 0.2,
          "the working copy carries the restored edits")
    check(await waitUntil(20) { prompts == 2 },
          "the postponed candidate gets its own prompt", "\(prompts)")
    check(recoveryCandidates().count == 1,
          "the postponed candidate is still recoverable")
}

@MainActor
func testCancelKeepsEveryCandidateWhileThirdDocumentEdits() async {
    print("\n[M1-R2] Cancel preserves both candidates while a third document autosaves")

    await settleRecoveryWrites()

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    settings.recoveryEnabled = true
    defer { settings.recoveryEnabled = previousRecoverySetting }

    guard let first = recoveryFixture("h1-first.png", width: 320, height: 400),
          let second = recoveryFixture("h1-second.png", width: 400, height: 320),
          let third = recoveryFixture("h1-third.png", width: 360, height: 360) else {
        check(false, "H1 fixtures written")
        return
    }
    let base = Date().addingTimeInterval(-60)
    guard let candidateA = stageRecoveryCandidate(for: first, exposure: 0.31, savedAt: base),
          let candidateB = stageRecoveryCandidate(for: second, exposure: 0.62,
                                                  savedAt: base.addingTimeInterval(1)),
          let bytesA = recoveryBytes(candidateA),
          let bytesB = recoveryBytes(candidateB) else {
        check(false, "H1 candidates written")
        return
    }

    var prompts = 0
    let model = EditorModel()
    model.recoveryChoiceHandler = { _, _ in
        prompts += 1
        return .cancel
    }
    model.offerRecoveryIfNeeded()
    check(prompts == 1, "Cancel answers the oldest candidate and postpones the rest")

    model.requestLoad(url: third)
    check(await waitUntil(60) { model.hasImage && !model.isBusy },
          "the third photo loads while two candidates wait")
    model.adjustments.exposure = 0.93
    model.flushAutosave()
    check(RecoveryStore.readWorking()?.project.imagePath == third.path,
          "the third document autosaves into the working slot")
    check(RecoveryStore.readWorking()?.project.adjustments.exposure == 0.93,
          "the working slot holds the third document")
    check(recoveryBytes(candidateA) == bytesA,
          "the first candidate is byte-identical after the new autosave")
    check(recoveryBytes(candidateB) == bytesB,
          "the second candidate is byte-identical after the new autosave")
    check(recoveryCandidates().count == 2,
          "both postponed candidates are still recoverable")
    check(prompts == 1, "the postponed pass did not run again in this session")
}

@MainActor
func testMissingSourceCancelKeepsCandidate() async {
    print("\n[M1-R3] Cancel preserves a candidate whose photo is missing")

    await settleRecoveryWrites()

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    settings.recoveryEnabled = true
    defer { settings.recoveryEnabled = previousRecoverySetting }

    let missing = workDir.appendingPathComponent("h2-missing.png")
    guard let candidate = stageRecoveryCandidate(for: missing, exposure: 0.44,
                                                 savedAt: Date().addingTimeInterval(-30)),
          let before = recoveryBytes(candidate) else {
        check(false, "missing-source candidate written")
        return
    }

    var prompts: [Bool] = []
    let model = EditorModel()
    model.recoveryChoiceHandler = { missingSource, _ in
        prompts.append(missingSource)
        return .cancel
    }
    model.offerRecoveryIfNeeded()
    check(prompts == [true], "a missing source asks before anything is applied")
    check(recoveryBytes(candidate) == before,
          "Cancel keeps the candidate byte-identical")
    check(!model.hasImage, "nothing was loaded")
    check(RecoveryStore.readWorking() == nil,
          "nothing was written to the working slot")
}

@MainActor
func testMovedSourceLocateThenRestore() async {
    print("\n[M1-R4] a located photo restores only after the Restore answer")

    await settleRecoveryWrites()

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    settings.recoveryEnabled = true
    defer { settings.recoveryEnabled = previousRecoverySetting }

    let missing = workDir.appendingPathComponent("h2-moved-away.png")
    guard let actual = recoveryFixture("h2-moved-here.png", width: 320, height: 400),
          let candidate = stageRecoveryCandidate(for: missing, exposure: 0.35,
                                                 savedAt: Date().addingTimeInterval(-30)),
          let before = recoveryBytes(candidate) else {
        check(false, "moved-source fixtures written")
        return
    }

    var prompts: [Bool] = []
    let model = EditorModel()
    model.recoveryChoiceHandler = { missingSource, _ in
        prompts.append(missingSource)
        return missingSource ? .locate : .restore
    }
    model.recoveryLocateHandler = { _ in actual }
    model.offerRecoveryIfNeeded()
    check(prompts == [true, false], "Locate is followed by the Restore prompt")
    check(recoveryBytes(candidate) == before,
          "the candidate is untouched before the Restore answer")
    check(await waitUntil(60) { model.hasImage && !model.isBusy },
          "the located photo restores")
    check(model.imageURL?.standardizedFileURL == actual.standardizedFileURL,
          "the located path is on screen")
    check(await waitUntil(10) { RecoveryStore.readWorking()?.project.imagePath == actual.path },
          "the working copy records the located path")
    check(RecoveryStore.readWorking()?.project.adjustments.exposure == 0.35,
          "the edits survive the move")
    check(!FileManager.default.fileExists(atPath: candidate.path),
          "the candidate is resolved after the restore")

    // The next launch must treat the located path as the photo's identity.
    RecoveryStore.invalidatePendingAutosaves()
    let relaunched = EditorModel()
    var relaunchPrompts = 0
    relaunched.recoveryChoiceHandler = { _, _ in relaunchPrompts += 1; return .cancel }
    relaunched.offerRecoveryIfNeeded()
    check(relaunchPrompts == 1,
          "the restored document is offered again from its working copy", "\(relaunchPrompts)")
    check(recoveryCandidates().first?.snapshot.project.imagePath == actual.path,
          "the durable copy points at the located photo")
}

@MainActor
func testRestoreTwoDifferentDocuments() async {
    print("\n[M1-R5] restoring a second document preserves the first one")

    await settleRecoveryWrites()

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    settings.recoveryEnabled = true
    defer { settings.recoveryEnabled = previousRecoverySetting }

    guard let first = recoveryFixture("h3-first.png", width: 320, height: 400),
          let second = recoveryFixture("h3-second.png", width: 400, height: 320) else {
        check(false, "H3 fixtures written")
        return
    }
    let base = Date().addingTimeInterval(-60)
    guard let candidateA = stageRecoveryCandidate(for: first, exposure: 0.2, savedAt: base),
          let candidateB = stageRecoveryCandidate(for: second, exposure: 0.8,
                                                  savedAt: base.addingTimeInterval(1)) else {
        check(false, "H3 candidates written")
        return
    }

    var prompts = 0
    let model = EditorModel()
    model.recoveryChoiceHandler = { _, _ in
        prompts += 1
        if prompts == 1 { return .restore }
        if prompts == 2 { return .restore }
        return .cancel
    }
    model.offerRecoveryIfNeeded()
    check(await waitUntil(60) {
        model.hasImage && model.imageURL?.standardizedFileURL == second.standardizedFileURL
            && !model.isBusy
    }, "the second document restores over the first")
    check(await waitUntil(20) { prompts >= 2 }, "both documents were offered", "\(prompts)")
    check(model.adjustments.exposure == 0.8, "the second document is on screen")
    check(await waitUntil(10) { RecoveryStore.readWorking()?.project.imagePath == second.path },
          "the second document is durable in the working slot")
    check(!FileManager.default.fileExists(atPath: candidateB.path),
          "the restored second candidate is resolved")

    let preserved = recoveryCandidates().filter {
        $0.snapshot.project.imagePath == first.path
    }
    check(preserved.count == 1,
          "the first restored document was preserved before being replaced",
          "\(preserved.count)")
    check(preserved.first?.snapshot.project.adjustments.exposure == 0.2,
          "the preserved copy carries the first document's edits")

    // A relaunch still sees two complete documents: one in the working slot,
    // one preserved as a candidate. Whichever is offered first, restoring it
    // must leave the other recoverable.
    RecoveryStore.invalidatePendingAutosaves()
    let relaunched = EditorModel()
    var relaunchPrompts = 0
    relaunched.recoveryChoiceHandler = { _, _ in
        relaunchPrompts += 1
        return relaunchPrompts == 1 ? .restore : .cancel
    }
    relaunched.offerRecoveryIfNeeded()
    check(await waitUntil(60) { relaunched.hasImage && !relaunched.isBusy },
          "one of the two documents restores on the next launch")
    let restoredPath = relaunched.imageURL?.standardizedFileURL
    check(restoredPath == first.standardizedFileURL || restoredPath == second.standardizedFileURL,
          "the restored document is one of the two")
    check(await waitUntil(20) { relaunchPrompts == 2 },
          "the other document is offered separately", "\(relaunchPrompts)")
    let otherPath = restoredPath == first.standardizedFileURL ? second.path : first.path
    check(recoveryCandidates().contains { $0.snapshot.project.imagePath == otherPath },
          "the other document is still recoverable after the restore")
}

@MainActor
func testFailedPreservationKeepsLiveDocument() async {
    print("\n[M1-R16] a restore that cannot preserve the live document leaves it in place")

    await settleRecoveryWrites()

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    settings.recoveryEnabled = true
    defer { settings.recoveryEnabled = previousRecoverySetting }

    guard let first = recoveryFixture("preserve-live-first.png", width: 320, height: 400),
          let second = recoveryFixture("preserve-live-second.png", width: 400, height: 320) else {
        check(false, "preservation fixtures written")
        return
    }
    let base = Date().addingTimeInterval(-60)
    guard let candidateA = stageRecoveryCandidate(for: first, exposure: 0.21, savedAt: base),
          let candidateB = stageRecoveryCandidate(for: second, exposure: 0.42,
                                                  savedAt: base.addingTimeInterval(1)),
          let bytesB = recoveryBytes(candidateB) else {
        check(false, "preservation candidates written")
        return
    }

    // The live copy cannot be set aside, so replacing it would lose it.
    RecoveryStore.injectedFailures = [.candidateWrite]
    defer { RecoveryStore.injectedFailures = [] }
    var prompts = 0
    let model = EditorModel()
    model.recoveryChoiceHandler = { _, _ in prompts += 1; return .restore }
    model.offerRecoveryIfNeeded()
    check(await waitUntil(60) { model.hasImage && !model.isBusy },
          "the first candidate restores")
    check(await waitUntil(20) { prompts == 2 },
          "the second candidate is offered", "\(prompts)")
    check(model.imageURL?.standardizedFileURL == first.standardizedFileURL,
          "the live document is still on screen")
    check(model.adjustments.exposure == 0.21,
          "the live document's edits are intact")
    check(model.statusToken == .recoveryStorageFailed,
          "the failed preservation is reported")
    check(recoveryBytes(candidateB) == bytesB,
          "the unresolvable candidate is byte-identical")
    check(!FileManager.default.fileExists(atPath: candidateA.path),
          "the candidate that was already restored is resolved")
    check(RecoveryStore.readWorking()?.project.imagePath == first.path,
          "the live document stays durable in the working slot")

    // The next launch must offer both documents again.
    RecoveryStore.injectedFailures = []
    RecoveryStore.invalidatePendingAutosaves()
    let relaunched = EditorModel()
    var relaunchPrompts = 0
    relaunched.recoveryChoiceHandler = { _, _ in relaunchPrompts += 1; return .cancel }
    relaunched.offerRecoveryIfNeeded()
    check(relaunchPrompts == 1, "the preserved live copy is offered again",
          "\(relaunchPrompts)")
    check(recoveryCandidates().count == 2,
          "both documents are recoverable on the next launch")
}

@MainActor
func testCrashBeforeRestoredSnapshotWrite() async {
    print("\n[M1-R6] a failed durable write keeps the candidate for the next launch")

    await settleRecoveryWrites()

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    settings.recoveryEnabled = true
    defer { settings.recoveryEnabled = previousRecoverySetting }

    guard let source = recoveryFixture("crash-before-write.png", width: 320, height: 400),
          let candidate = stageRecoveryCandidate(for: source, exposure: 0.5,
                                                 savedAt: Date().addingTimeInterval(-30)),
          let before = recoveryBytes(candidate) else {
        check(false, "crash-before-write fixture written")
        return
    }

    RecoveryStore.injectedFailures = [.workingWrite]
    defer { RecoveryStore.injectedFailures = [] }
    var prompts = 0
    let model = EditorModel()
    model.recoveryChoiceHandler = { _, _ in prompts += 1; return .restore }
    model.offerRecoveryIfNeeded()
    check(await waitUntil(60) { model.hasImage && !model.isBusy },
          "the pixels still load")
    check(model.statusToken == .recoveryStorageFailed,
          "the failed durable write is reported")
    check(FileManager.default.fileExists(atPath: candidate.path),
          "the candidate survives a crash before persistence")
    check(recoveryBytes(candidate) == before,
          "the candidate is byte-identical")
    check(RecoveryStore.readWorking() == nil,
          "no working copy pretends the restored document is durable")
    check(prompts == 1, "the failed restore does not repeat the prompt")

    RecoveryStore.injectedFailures = []
    RecoveryStore.invalidatePendingAutosaves()
    let relaunched = EditorModel()
    relaunched.recoveryChoiceHandler = { _, _ in .restore }
    relaunched.offerRecoveryIfNeeded()
    check(await waitUntil(60) { relaunched.hasImage && !relaunched.isBusy },
          "the preserved candidate restores on the next launch")
    check(await waitUntil(10) {
        RecoveryStore.readWorking()?.project.adjustments.exposure == 0.5
    }, "the restore is durable this time")
    check(recoveryCandidates().isEmpty, "the candidate is resolved after the verified write")
}

@MainActor
func testCrashAfterWorkingWriteBeforeCandidateDelete() async {
    print("\n[M1-R7] a failed candidate delete leaves two complete copies")

    await settleRecoveryWrites()

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    settings.recoveryEnabled = true
    defer { settings.recoveryEnabled = previousRecoverySetting }

    guard let source = recoveryFixture("crash-after-write.png", width: 320, height: 400),
          let candidate = stageRecoveryCandidate(for: source, exposure: 0.52,
                                                 savedAt: Date().addingTimeInterval(-30)) else {
        check(false, "crash-after-write fixture written")
        return
    }

    RecoveryStore.injectedFailures = [.candidateRemove]
    defer { RecoveryStore.injectedFailures = [] }
    var prompts = 0
    let model = EditorModel()
    model.recoveryChoiceHandler = { _, _ in prompts += 1; return .restore }
    model.offerRecoveryIfNeeded()
    check(await waitUntil(60) { model.hasImage && !model.isBusy },
          "the restored pixels load")
    check(await waitUntil(10) {
        RecoveryStore.readWorking()?.project.adjustments.exposure == 0.52
    }, "the restored document is durable before the delete")
    check(model.statusToken == .recoveryCandidateNotRemoved,
          "the failed delete is reported")
    check(FileManager.default.fileExists(atPath: candidate.path),
          "the old candidate remains after the failed delete")
    check(prompts == 1, "the failed delete does not loop the prompt")

    RecoveryStore.injectedFailures = []
    RecoveryStore.invalidatePendingAutosaves()
    let relaunched = EditorModel()
    var relaunchPrompts = 0
    relaunched.recoveryChoiceHandler = { _, _ in relaunchPrompts += 1; return .cancel }
    relaunched.offerRecoveryIfNeeded()
    let listing = recoveryCandidates()
    check(listing.count == 2,
          "the working copy and the candidate both survive the crash",
          "\(listing.count)")
    check(listing.allSatisfy { $0.snapshot.project.adjustments.exposure == 0.52 },
          "both copies describe the same restored document")
    check(RecoveryStore.readWorking() == nil,
          "the working copy was lifted into the candidate list")
    check(relaunchPrompts == 1, "the relaunch asks once and Cancel postpones the rest")
}

@MainActor
func testFailedPromotionKeepsRecoveryCopy() async {
    print("\n[M1-R8] a failed promotion leaves every copy where it was")

    await settleRecoveryWrites()

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    settings.recoveryEnabled = true
    defer { settings.recoveryEnabled = previousRecoverySetting }

    guard let first = recoveryFixture("promote-first.png", width: 320, height: 400),
          let second = recoveryFixture("promote-second.png", width: 400, height: 320) else {
        check(false, "promotion fixtures written")
        return
    }

    // A legacy session file that cannot be renamed must stay exactly where it
    // is, byte-identical, and be retried on the next launch.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let legacy = recoveryProject(for: first, exposure: 0.61)
    guard let legacyData = try? encoder.encode(legacy) else {
        check(false, "legacy project encoded")
        return
    }
    try? FileManager.default.createDirectory(at: RecoveryStore.directory,
                                             withIntermediateDirectories: true)
    check((try? legacyData.write(to: RecoveryStore.legacyActiveURL)) != nil,
          "a legacy active copy is staged")

    RecoveryStore.injectedFailures = [.migrate]
    defer { RecoveryStore.injectedFailures = [] }
    var prompts = 0
    let blocked = EditorModel()
    blocked.recoveryChoiceHandler = { _, _ in prompts += 1; return .cancel }
    blocked.offerRecoveryIfNeeded()
    check(prompts == 0, "nothing is offered while its file is still in the legacy slot")
    check(blocked.statusToken == .recoveryStorageFailed,
          "the failed promotion is reported")
    check(recoveryBytes(RecoveryStore.legacyActiveURL) == legacyData,
          "the legacy copy is byte-identical")
    check(recoveryCandidates().isEmpty, "nothing was written as a candidate")

    RecoveryStore.injectedFailures = []
    RecoveryStore.invalidatePendingAutosaves()
    let migrated = EditorModel()
    var migratedPrompts = 0
    migrated.recoveryChoiceHandler = { _, _ in migratedPrompts += 1; return .cancel }
    migrated.offerRecoveryIfNeeded()
    check(migratedPrompts == 1, "the next launch migrates and offers it", "\(migratedPrompts)")
    check(!FileManager.default.fileExists(atPath: RecoveryStore.legacyActiveURL.path),
          "the legacy file has moved")
    check(recoveryCandidates().first?.snapshot.project.adjustments.exposure == 0.61,
          "the migrated candidate carries the edits")

    // A working copy that cannot be promoted must not be overwritten by the
    // next document's autosave.
    await settleRecoveryWrites()
    let staged = RecoverySnapshot.capture(recoveryProject(for: first, exposure: 0.77),
                                          savedAt: Date().addingTimeInterval(-30))
    check(RecoveryStore.writeWorking(staged), "an unresolved working copy is staged")
    RecoveryStore.injectedFailures = [.migrate]
    var lockedPrompts = 0
    let locked = EditorModel()
    locked.recoveryChoiceHandler = { _, _ in lockedPrompts += 1; return .cancel }
    locked.offerRecoveryIfNeeded()
    check(lockedPrompts == 0, "the locked working copy is not offered")
    check(locked.statusToken == .recoveryStorageFailed,
          "the failed working promotion is reported")
    check(RecoveryStore.readWorking()?.project.adjustments.exposure == 0.77,
          "the unresolved working copy is still in its slot")
    locked.load(url: first)
    check(await waitUntil(60) { locked.hasImage && !locked.isBusy },
          "another photo loads while the slot is locked")
    locked.adjustments.exposure = 0.05
    locked.flushAutosave()
    check(RecoveryStore.readWorking()?.project.adjustments.exposure == 0.77,
          "autosave cannot overwrite a working copy that could not be promoted")
    check(!RecoveryStore.removeWorking(),
          "a confirmed open cannot delete a working copy that could not be promoted")
    check(RecoveryStore.readWorking()?.project.adjustments.exposure == 0.77,
          "the unresolved copy survives the refused removal")

    RecoveryStore.injectedFailures = []
    RecoveryStore.invalidatePendingAutosaves()
    let recovered = EditorModel()
    var recoveredPrompts = 0
    recovered.recoveryChoiceHandler = { _, _ in recoveredPrompts += 1; return .cancel }
    recovered.offerRecoveryIfNeeded()
    check(recoveredPrompts == 1, "the next launch promotes and offers the copy",
          "\(recoveredPrompts)")
    check(RecoveryStore.readWorking() == nil, "the working slot is empty after promotion")

    // Legacy pending is offered before legacy active, and a damaged legacy
    // file is quarantined instead of blocking the valid one.
    await settleRecoveryWrites()
    try? FileManager.default.createDirectory(at: RecoveryStore.directory,
                                             withIntermediateDirectories: true)
    guard let pendingData = try? encoder.encode(recoveryProject(for: first, exposure: 0.11)),
          let activeData = try? encoder.encode(recoveryProject(for: second, exposure: 0.22)) else {
        check(false, "legacy order projects encoded")
        return
    }
    check((try? pendingData.write(to: RecoveryStore.legacyPendingURL)) != nil,
          "a legacy pending copy is staged")
    check((try? activeData.write(to: RecoveryStore.legacyActiveURL)) != nil,
          "a legacy active copy is staged")
    var order: [String] = []
    let ordered = EditorModel()
    ordered.recoveryChoiceHandler = { _, name in
        order.append(name ?? "")
        return .cancel
    }
    ordered.offerRecoveryIfNeeded()
    check(order == [first.lastPathComponent],
          "the postponed legacy copy is offered first", "\(order)")
    check(recoveryCandidates().count == 2, "both legacy copies were migrated")
    check(!FileManager.default.fileExists(atPath: RecoveryStore.legacyPendingURL.path)
            && !FileManager.default.fileExists(atPath: RecoveryStore.legacyActiveURL.path),
          "the legacy slots are empty after migration")

    await settleRecoveryWrites()
    try? FileManager.default.createDirectory(at: RecoveryStore.directory,
                                             withIntermediateDirectories: true)
    check((try? Data("broken legacy".utf8).write(to: RecoveryStore.legacyPendingURL)) != nil,
          "a damaged legacy copy is staged")
    check((try? activeData.write(to: RecoveryStore.legacyActiveURL)) != nil,
          "a valid legacy copy is staged next to it")
    var legacyPrompts = 0
    let damaged = EditorModel()
    damaged.recoveryChoiceHandler = { _, _ in legacyPrompts += 1; return .cancel }
    damaged.offerRecoveryIfNeeded()
    check(legacyPrompts == 1, "the valid legacy copy is still offered")
    check(damaged.statusToken == .recoveryQuarantined(1),
          "the damaged legacy copy is reported as quarantined")
    check(recoveryCandidates().count == 1, "the valid legacy copy migrated")
}

@MainActor
func testFailedCandidateDeleteOnDiscard() async {
    print("\n[M1-R9] a failed Discard leaves the candidate recoverable")

    await settleRecoveryWrites()

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    settings.recoveryEnabled = true
    defer { settings.recoveryEnabled = previousRecoverySetting }

    guard let source = recoveryFixture("discard-failure.png", width: 320, height: 400),
          let candidate = stageRecoveryCandidate(for: source, exposure: 0.4,
                                                 savedAt: Date().addingTimeInterval(-30)),
          let before = recoveryBytes(candidate) else {
        check(false, "discard-failure fixture written")
        return
    }

    RecoveryStore.injectedFailures = [.candidateRemove]
    defer { RecoveryStore.injectedFailures = [] }
    var prompts = 0
    let model = EditorModel()
    model.recoveryChoiceHandler = { _, _ in prompts += 1; return .discard }
    model.offerRecoveryIfNeeded()
    check(prompts == 1, "the prompt is not repeated after a failed delete")
    check(FileManager.default.fileExists(atPath: candidate.path),
          "the candidate survives a failed Discard")
    check(recoveryBytes(candidate) == before, "the candidate is byte-identical")
    check(model.statusToken == .recoveryCandidateNotRemoved,
          "the failed delete is reported")

    RecoveryStore.injectedFailures = []
    RecoveryStore.invalidatePendingAutosaves()
    var retryPrompts = 0
    let retry = EditorModel()
    retry.recoveryChoiceHandler = { _, _ in retryPrompts += 1; return .discard }
    retry.offerRecoveryIfNeeded()
    check(!FileManager.default.fileExists(atPath: candidate.path),
          "the next launch can discard it")
    check(retryPrompts == 1, "the retry asks once", "\(retryPrompts)")
}

@MainActor
func testSeveralLaunchesKeepSeveralCandidates() async {
    print("\n[M1-R10] several launches keep every unresolved candidate")

    await settleRecoveryWrites()

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    settings.recoveryEnabled = true
    defer { settings.recoveryEnabled = previousRecoverySetting }

    guard let first = recoveryFixture("launch-first.png", width: 320, height: 400),
          let second = recoveryFixture("launch-second.png", width: 400, height: 320),
          let third = recoveryFixture("launch-third.png", width: 360, height: 360) else {
        check(false, "launch fixtures written")
        return
    }
    let base = Date().addingTimeInterval(-60)
    guard let candidateA = stageRecoveryCandidate(for: first, exposure: 0.1, savedAt: base),
          let candidateB = stageRecoveryCandidate(for: second, exposure: 0.2,
                                                  savedAt: base.addingTimeInterval(1)),
          let candidateC = stageRecoveryCandidate(for: third, exposure: 0.3,
                                                  savedAt: base.addingTimeInterval(2)),
          let bytesA = recoveryBytes(candidateA),
          let bytesB = recoveryBytes(candidateB),
          let bytesC = recoveryBytes(candidateC) else {
        check(false, "launch candidates written")
        return
    }

    var prompts = 0
    for _ in 0..<2 {
        let model = EditorModel()
        model.recoveryChoiceHandler = { _, _ in prompts += 1; return .cancel }
        model.offerRecoveryIfNeeded()
        check(recoveryCandidates().count == 3,
              "a launch leaves all three candidates on disk")
    }
    check(prompts == 2, "each launch offers only the oldest copy", "\(prompts)")
    check(recoveryBytes(candidateA) == bytesA
            && recoveryBytes(candidateB) == bytesB
            && recoveryBytes(candidateC) == bytesC,
          "two Cancels leave all three candidates byte-identical")

    let resolving = EditorModel()
    var decisions: [String] = []
    resolving.recoveryChoiceHandler = { _, name in
        decisions.append(name ?? "")
        return decisions.count == 1 ? .restore : .cancel
    }
    resolving.offerRecoveryIfNeeded()
    check(await waitUntil(60) { resolving.hasImage && !resolving.isBusy },
          "the oldest document restores on a later launch")
    check(decisions.first == first.lastPathComponent,
          "the oldest candidate is the one restored", "\(decisions)")
    check(resolving.adjustments.exposure == 0.1, "its own edits are on screen")
    check(await waitUntil(20) { decisions.count == 2 },
          "the next candidate gets its own prompt", "\(decisions.count)")
    check(recoveryCandidates().count == 2,
          "the two unresolved candidates remain")
    check(recoveryBytes(candidateB) == bytesB && recoveryBytes(candidateC) == bytesC,
          "the remaining candidates are byte-identical")
}

@MainActor
func testRecoveryPreferenceKeepsCandidates() async {
    print("\n[M1-R11] disabling recovery preserves every candidate and the working copy")

    await settleRecoveryWrites()

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    defer { settings.recoveryEnabled = previousRecoverySetting }
    settings.recoveryEnabled = true

    guard let first = recoveryFixture("pref-first.png", width: 320, height: 400),
          let second = recoveryFixture("pref-second.png", width: 400, height: 320) else {
        check(false, "preference fixtures written")
        return
    }
    let base = Date().addingTimeInterval(-60)
    guard let candidateA = stageRecoveryCandidate(for: first, exposure: 0.12, savedAt: base),
          let candidateB = stageRecoveryCandidate(for: second, exposure: 0.24,
                                                  savedAt: base.addingTimeInterval(1)),
          let bytesA = recoveryBytes(candidateA),
          let bytesB = recoveryBytes(candidateB) else {
        check(false, "preference candidates written")
        return
    }
    let working = RecoverySnapshot.capture(recoveryProject(for: first, exposure: 0.36),
                                           savedAt: base.addingTimeInterval(2))
    check(RecoveryStore.writeWorking(working), "an autosave copy is staged")

    settings.recoveryEnabled = false
    var disabledPrompts = 0
    let disabled = EditorModel()
    disabled.recoveryChoiceHandler = { _, _ in disabledPrompts += 1; return .cancel }
    disabled.offerRecoveryIfNeeded()
    check(disabledPrompts == 0, "a disabled preference offers nothing")
    check(recoveryCandidates().count == 2,
          "a disabled preference leaves the candidates alone")
    check(RecoveryStore.readWorking()?.project.adjustments.exposure == 0.36,
          "a disabled preference leaves the working copy alone")
    check(recoveryBytes(candidateA) == bytesA && recoveryBytes(candidateB) == bytesB,
          "the candidates are byte-identical while recovery is off")

    settings.recoveryEnabled = true
    var enabledPrompts = 0
    let enabled = EditorModel()
    enabled.recoveryChoiceHandler = { _, _ in enabledPrompts += 1; return .cancel }
    enabled.offerRecoveryIfNeeded()
    check(enabledPrompts == 1, "re-enabling recovery offers the copies", "\(enabledPrompts)")
    check(RecoveryStore.readWorking() == nil,
          "the working copy was promoted after re-enabling")
    check(recoveryCandidates().count == 3,
          "all three copies are recoverable after re-enabling")
    check(recoveryBytes(candidateA) == bytesA && recoveryBytes(candidateB) == bytesB,
          "the original candidates are still byte-identical")
}

@MainActor
func testCorruptCandidateIsQuarantined() async {
    print("\n[M1-R12] a damaged candidate is quarantined, not deleted")

    await settleRecoveryWrites()

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    settings.recoveryEnabled = true
    defer { settings.recoveryEnabled = previousRecoverySetting }

    guard let source = recoveryFixture("corrupt-valid.png", width: 320, height: 400),
          let valid = stageRecoveryCandidate(for: source, exposure: 0.25,
                                             savedAt: Date().addingTimeInterval(-30)) else {
        check(false, "valid candidate written")
        return
    }
    try? FileManager.default.createDirectory(at: RecoveryStore.candidatesDirectory,
                                             withIntermediateDirectories: true)
    let corrupt = RecoveryStore.candidatesDirectory
        .appendingPathComponent("0000000000000-\(UUID().uuidString).retouch")
    let junk = Data("{ this is not a recovery snapshot".utf8)
    check((try? junk.write(to: corrupt)) != nil, "a damaged candidate is staged first")

    var prompts = 0
    let model = EditorModel()
    model.recoveryChoiceHandler = { _, _ in prompts += 1; return .cancel }
    model.offerRecoveryIfNeeded()
    check(prompts == 1, "the valid candidate is still offered")
    check(!FileManager.default.fileExists(atPath: corrupt.path),
          "the damaged file left the candidate list")
    check(FileManager.default.fileExists(atPath: valid.path),
          "the valid candidate is untouched")
    let quarantined = (try? FileManager.default.contentsOfDirectory(
        at: RecoveryStore.quarantineDirectory, includingPropertiesForKeys: nil)) ?? []
    check(quarantined.count == 1,
          "exactly one damaged copy was quarantined", "\(quarantined.count)")
    check(quarantined.first.flatMap(recoveryBytes) == junk,
          "the damaged bytes are preserved, not deleted")
    check(model.statusToken == .recoveryQuarantined(1),
          "the quarantine is reported to the owner")

    // A damaged file that cannot be moved aside must be reported, but it must
    // not hide the candidates that can still be read.
    await settleRecoveryWrites()
    guard let second = recoveryFixture("corrupt-valid-2.png", width: 320, height: 400),
          let readable = stageRecoveryCandidate(for: second, exposure: 0.26,
                                                savedAt: Date().addingTimeInterval(-20)),
          let readableBytes = recoveryBytes(readable) else {
        check(false, "second valid candidate written")
        return
    }
    let stuck = RecoveryStore.candidatesDirectory
        .appendingPathComponent("0000000000001-\(UUID().uuidString).retouch")
    check((try? junk.write(to: stuck)) != nil, "a second damaged candidate is staged")
    RecoveryStore.injectedFailures = [.quarantine]
    defer { RecoveryStore.injectedFailures = [] }
    var secondPrompts = 0
    let blocked = EditorModel()
    blocked.recoveryChoiceHandler = { _, _ in secondPrompts += 1; return .cancel }
    blocked.offerRecoveryIfNeeded()
    check(secondPrompts == 1,
          "a damaged file that cannot be quarantined does not hide a valid copy")
    check(blocked.statusToken == .recoveryStorageFailed,
          "the failed quarantine is reported")
    check(FileManager.default.fileExists(atPath: stuck.path),
          "the damaged file is left in place for the next launch")
    check(recoveryBytes(readable) == readableBytes,
          "the readable candidate is byte-identical")
}

@MainActor
func testChangedSourceAsksBeforeRestore() async {
    print("\n[M1-R13] a changed photo still needs an explicit Restore")

    await settleRecoveryWrites()

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    settings.recoveryEnabled = true
    defer { settings.recoveryEnabled = previousRecoverySetting }

    guard let source = recoveryFixture("identity-source.png", width: 320, height: 400),
          let candidate = stageRecoveryCandidate(for: source, exposure: 0.48,
                                                 savedAt: Date().addingTimeInterval(-30)),
          let before = recoveryBytes(candidate) else {
        check(false, "identity fixture written")
        return
    }
    guard let replacement = makeImage(width: 200, height: 260),
          writePNG(replacement, to: source) else {
        check(false, "replacement photo written")
        return
    }
    try? FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: source.path)

    let listed = recoveryCandidates()
    check(listed.count == 1, "the candidate is still listed")
    if let snapshot = listed.first?.snapshot {
        check(RecoveryStore.sourceState(for: snapshot) == .changed(source),
              "a changed photo is detected before anything is applied")
    }

    var cancelPrompts = 0
    let cancelled = EditorModel()
    cancelled.recoveryChoiceHandler = { _, _ in cancelPrompts += 1; return .cancel }
    cancelled.offerRecoveryIfNeeded()
    check(cancelPrompts == 1, "the changed photo asks instead of applying silently")
    check(!cancelled.hasImage, "nothing is applied without a decision")
    check(recoveryBytes(candidate) == before,
          "Cancel keeps the candidate byte-identical")

    var restorePrompts = 0
    let restored = EditorModel()
    restored.recoveryChoiceHandler = { _, _ in restorePrompts += 1; return .restore }
    restored.offerRecoveryIfNeeded()
    check(await waitUntil(60) { restored.hasImage && !restored.isBusy },
          "the explicit Restore applies the edits")
    check(restored.adjustments.exposure == 0.48, "the stored edits are on screen")
    let identity = RecoverySourceIdentity.of(source)
    check(await waitUntil(10) { RecoveryStore.readWorking()?.source == identity },
          "the working copy records the new photo identity")
    check(!FileManager.default.fileExists(atPath: candidate.path),
          "the candidate is resolved after the explicit restore")
}

@MainActor
func testWorkingSlotIsPromotedAtLaunch() async {
    print("\n[M1-R14] an unsaved document in the working slot is offered at launch")

    await settleRecoveryWrites()

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    settings.recoveryEnabled = true
    defer { settings.recoveryEnabled = previousRecoverySetting }

    guard let source = recoveryFixture("working-launch.png", width: 320, height: 400) else {
        check(false, "working-launch fixture written")
        return
    }
    let staged = RecoverySnapshot.capture(recoveryProject(for: source, exposure: 0.58),
                                          savedAt: Date().addingTimeInterval(-30))
    check(RecoveryStore.writeWorking(staged), "a crash copy is staged in the working slot")

    var prompts = 0
    let model = EditorModel()
    model.recoveryChoiceHandler = { _, _ in prompts += 1; return .cancel }
    model.offerRecoveryIfNeeded()
    check(prompts == 1, "the working copy is offered at launch")
    check(RecoveryStore.readWorking() == nil,
          "the working slot was lifted before a new document can overwrite it")
    let listing = recoveryCandidates()
    check(listing.count == 1, "the crash copy became an independent candidate")
    check(listing.first?.snapshot.project.adjustments.exposure == 0.58,
          "the candidate carries the unsaved edits")
}

@MainActor
func testExternalOpenPromotesWorkingSnapshotFirst() async {
    print("\n[M1-R17] an external open promotes the previous working copy first")

    await settleRecoveryWrites()

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    settings.recoveryEnabled = true
    defer { settings.recoveryEnabled = previousRecoverySetting }

    guard let previous = recoveryFixture("h1-previous.png", width: 320, height: 400),
          let incoming = recoveryFixture("h1-incoming.png", width: 400, height: 320) else {
        check(false, "H1 fixtures written")
        return
    }
    let staged = RecoverySnapshot.capture(recoveryProject(for: previous, exposure: 0.37),
                                          savedAt: Date().addingTimeInterval(-30))
    check(RecoveryStore.writeWorking(staged), "a crash copy is staged in the working slot")
    guard let workingBytes = recoveryBytes(RecoveryStore.workingURL) else {
        check(false, "the crash copy is readable")
        return
    }

    // requestOpen is the production entry point for a Finder / Open With /
    // drag-and-drop event, including one that arrives before the launch pass.
    let model = EditorModel()
    model.requestOpen(url: incoming)
    check(await waitUntil(60) { model.hasImage && !model.isBusy },
          "the incoming photo opens")
    check(model.imageURL?.standardizedFileURL == incoming.standardizedFileURL,
          "the incoming photo is the document", model.imageName)
    check(RecoveryStore.readWorking() == nil,
          "the working slot was promoted instead of removed")
    let listing = recoveryCandidates()
    check(listing.count == 1, "the previous session became a candidate", "\(listing.count)")
    check(listing.first.map { recoveryBytes($0.url) == workingBytes } ?? false,
          "the candidate is byte-identical to the crash copy")
    check(listing.first?.snapshot.project.adjustments.exposure == 0.37,
          "the candidate carries the unsaved edits")

    model.adjustments.exposure = 0.71
    model.flushAutosave()
    check(RecoveryStore.readWorking()?.project.imagePath == incoming.path,
          "the incoming document autosaves into the working slot")
    check(recoveryCandidates().count == 1
            && (listing.first.map { recoveryBytes($0.url) == workingBytes } ?? false),
          "the promoted candidate survives the new autosave")
}

@MainActor
func testExternalOpenPromotionFailureKeepsWorking() async {
    print("\n[M1-R18] a failed promotion blocks the open and keeps the crash copy")

    await settleRecoveryWrites()

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    settings.recoveryEnabled = true
    defer { settings.recoveryEnabled = previousRecoverySetting }

    guard let previous = recoveryFixture("h1-fail-previous.png", width: 320, height: 400),
          let incoming = recoveryFixture("h1-fail-incoming.png", width: 400, height: 320) else {
        check(false, "H1 failure fixtures written")
        return
    }
    let staged = RecoverySnapshot.capture(recoveryProject(for: previous, exposure: 0.37),
                                          savedAt: Date().addingTimeInterval(-30))
    check(RecoveryStore.writeWorking(staged), "a crash copy is staged in the working slot")
    guard let workingBytes = recoveryBytes(RecoveryStore.workingURL) else {
        check(false, "the crash copy is readable")
        return
    }

    RecoveryStore.injectedFailures = [.migrate]
    defer { RecoveryStore.injectedFailures = [] }

    let model = EditorModel()
    model.requestOpen(url: incoming)
    check(model.statusToken == .recoveryStorageFailed,
          "the failed promotion is reported", "\(model.statusToken)")
    check(!model.hasImage, "the incoming document is not allowed to replace it")
    check(recoveryBytes(RecoveryStore.workingURL) == workingBytes,
          "the crash copy is byte-identical")
    check(RecoveryStore.readWorking()?.project.adjustments.exposure == 0.37,
          "the crash copy is still readable")
    check(recoveryCandidates().isEmpty, "no candidate was fabricated")
    check(!RecoveryStore.removeWorking(),
          "the unpromoted copy cannot be removed by a later discard")

    // Once promotion can succeed, the same entry point retries the barrier.
    RecoveryStore.injectedFailures = []
    model.requestOpen(url: incoming)
    check(await waitUntil(60) { model.hasImage && !model.isBusy },
          "the retry opens the photo")
    check(RecoveryStore.readWorking() == nil, "the crash copy was promoted on retry")
    let listing = recoveryCandidates()
    check(listing.count == 1
            && (listing.first.map { recoveryBytes($0.url) == workingBytes } ?? false),
          "the retry produced the byte-identical candidate")
}

@MainActor
func testQueuedExternalOpensKeepOneCandidate() async {
    print("\n[M1-R19] queued external opens promote the working copy exactly once")

    await settleRecoveryWrites()

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    settings.recoveryEnabled = true
    defer { settings.recoveryEnabled = previousRecoverySetting }

    guard let first = recoveryFixture("h1-queue-first.png", width: 320, height: 400),
          let second = recoveryFixture("h1-queue-second.png", width: 400, height: 320) else {
        check(false, "H1 queue fixtures written")
        return
    }
    let staged = RecoverySnapshot.capture(recoveryProject(for: first, exposure: 0.29),
                                          savedAt: Date().addingTimeInterval(-30))
    check(RecoveryStore.writeWorking(staged), "a crash copy is staged in the working slot")
    guard let workingBytes = recoveryBytes(RecoveryStore.workingURL) else {
        check(false, "the crash copy is readable")
        return
    }

    let model = EditorModel()
    model.requestOpen(url: first)
    // The first open owns the load operation; a request that arrives while it
    // is in flight is refused instead of queueing in front of the replacement.
    model.requestOpen(url: second)
    check(await waitUntil(60) { model.hasImage && !model.isBusy },
          "the first accepted open finishes")
    check(model.imageURL?.standardizedFileURL == first.standardizedFileURL,
          "the first request is the one that ran", model.imageName)
    check(recoveryCandidates().count == 1,
          "the working copy was promoted exactly once")
    check(RecoveryStore.readWorking() == nil,
          "the refused request did not write over the promoted slot")

    model.requestOpen(url: second)
    check(await waitUntil(60) {
        model.hasImage && !model.isBusy
            && model.imageURL?.standardizedFileURL == second.standardizedFileURL
    }, "the next request runs once the load is done")
    let listing = recoveryCandidates()
    check(listing.count == 1
            && (listing.first.map { recoveryBytes($0.url) == workingBytes } ?? false),
          "the candidate is untouched by both opens")
}

@MainActor
func testDiscardInvalidatesInFlightAutosave() async {
    print("\n[M1-R20] Discard invalidates an autosave that already started")

    await settleRecoveryWrites()

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    settings.recoveryEnabled = true
    defer { settings.recoveryEnabled = previousRecoverySetting }

    guard let photo = recoveryFixture("m1-discard.png", width: 320, height: 400) else {
        check(false, "M1 discard fixture written")
        return
    }
    let model = EditorModel()
    model.load(url: photo)
    check(await waitUntil(60) { model.hasImage && !model.isBusy }, "the photo loads")

    model.autosaveDebounceNanoseconds = 0
    defer {
        model.autosaveDebounceNanoseconds = 1_500_000_000
        model.autosaveWillWrite = nil
    }

    var reachedDecision = false
    model.autosaveWillWrite = {
        reachedDecision = true
        model.discardUnsavedChanges()
    }
    model.adjustments.exposure = 0.47
    check(await waitUntil(10) { reachedDecision },
          "the scheduled autosave reached its write decision")
    check(RecoveryStore.readWorking() == nil,
          "the invalidated task did not recreate the discarded copy")
    check(recoveryCandidates().isEmpty,
          "Discard does not leave a candidate behind")
    check(!model.hasUnsavedChanges, "the document is clean after Discard")

    model.autosaveWillWrite = nil
    model.autosaveDebounceNanoseconds = 1_500_000_000
    model.adjustments.exposure = 0.63
    model.flushAutosave()
    check(RecoveryStore.readWorking()?.project.adjustments.exposure == 0.63,
          "the next legitimate autosave still lands")
}

@MainActor
func testReplacementInvalidatesOldDocumentAutosave() async {
    print("\n[M1-R21] replacing a document invalidates the old autosave")

    await settleRecoveryWrites()

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    settings.recoveryEnabled = true
    defer { settings.recoveryEnabled = previousRecoverySetting }

    guard let first = recoveryFixture("m1-replace-first.png", width: 320, height: 400),
          let second = recoveryFixture("m1-replace-second.png", width: 400, height: 320) else {
        check(false, "M1 replacement fixtures written")
        return
    }
    let model = EditorModel()
    model.load(url: first)
    check(await waitUntil(60) { model.hasImage && !model.isBusy },
          "the first photo loads")

    model.discardChoiceHandler = { true }
    model.autosaveDebounceNanoseconds = 0
    defer {
        model.autosaveDebounceNanoseconds = 1_500_000_000
        model.discardChoiceHandler = nil
        model.autosaveWillWrite = nil
    }

    var oldSnapshotStarted = false
    model.autosaveWillWrite = {
        oldSnapshotStarted = true
        model.requestOpen(url: second)
    }
    model.adjustments.exposure = 0.39
    check(await waitUntil(10) { oldSnapshotStarted },
          "the old document's autosave reached its write decision")
    check(await waitUntil(60) {
        model.hasImage && !model.isBusy
            && model.imageURL?.standardizedFileURL == second.standardizedFileURL
    }, "the incoming photo replaces it")
    check(RecoveryStore.readWorking() == nil,
          "the old snapshot never reached the working slot")

    model.autosaveWillWrite = nil
    model.autosaveDebounceNanoseconds = 1_500_000_000
    model.adjustments.exposure = 0.82
    model.flushAutosave()
    check(RecoveryStore.readWorking()?.project.imagePath == second.path,
          "the new document's autosave describes the new document")
    check(RecoveryStore.readWorking()?.project.adjustments.exposure == 0.82,
          "the new document's legitimate autosave still lands")
}

@MainActor
func testFailedLoadPreservesDocument() async {
    print("\n[M1-L] a failed open leaves the current document intact")

    let good = workDir.appendingPathComponent("failedload-good.png")
    check(makeImage(width: 400, height: 500).map { writePNG($0, to: good) } ?? false,
          "good fixture written")
    let bad = workDir.appendingPathComponent("failedload-bad.png")
    check((try? Data("not an image".utf8).write(to: bad)) != nil, "corrupt fixture written")

    let model = EditorModel()
    model.load(url: good)
    check(await waitUntil { model.hasImage && !model.isBusy }, "good fixture loads")
    model.adjustments.smooth = 30
    check(model.adjustments.smooth == 30, "an edit is made before the failed open")
    check(model.canUndo, "the edit is in the undo history")
    let name = model.imageName
    let url = model.imageURL
    let suggested = model.suggestedFileName()
    let title = model.windowTitle

    model.load(url: bad)
    check(await waitUntil { model.status == L10n.current.couldNotRead },
          "the failure is reported")
    check(model.hasImage, "the previous image remains open")
    check(model.imageName == name, "the previous name remains", model.imageName)
    check(model.imageURL == url, "the previous URL remains")
    check(model.adjustments.smooth == 30, "the previous adjustments remain")
    check(model.canUndo, "the previous undo history remains")
    check(model.suggestedFileName() == suggested,
          "the export name still describes the previous photo")
    check(model.windowTitle == title, "the title still describes the previous photo")
    model.undo()
    check(model.adjustments.smooth == 0, "undo still reaches the edit made before the failure")

    let empty = EditorModel()
    empty.load(url: bad)
    check(await waitUntil { empty.status == L10n.current.couldNotRead },
          "the failure is reported with no document")
    check(!empty.hasImage, "the failed image does not become the document")
    check(empty.imageName.isEmpty, "the failed image does not become the title")
    check(empty.imageURL == nil, "the failed image does not become the URL")
    check(empty.windowTitle == L10n.current.appName, "the window keeps the app title")
    check(!empty.suggestedFileName().contains("failedload-bad"),
          "the suggested export name does not use the failed file")
}

@MainActor
func testExportProtectsSource() async {
    print("\n[M1-X] export refuses the source path and every alias")

    let source = workDir.appendingPathComponent("export-source.png")
    check(makeImage(width: 480, height: 600).map { writePNG($0, to: source) } ?? false,
          "source fixture written")
    guard let before = fileBytes(source) else {
        check(false, "source bytes are readable")
        return
    }

    let model = EditorModel()
    model.load(url: source)
    model.exportFormat = .png
    check(await waitUntil { model.hasImage && !model.isBusy }, "source fixture loads")

    model.export(to: source)
    check(!model.isBusy, "same-path export is refused before rendering")
    check(model.status == L10n.current.exportRefusedOriginal,
          "the same-path refusal is reported", model.status)
    check(fileBytes(source) == before, "the source is unchanged after the same-path refusal")

    let symlink = workDir.appendingPathComponent("export-symlink.png")
    try? FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
    model.export(to: symlink)
    check(!model.isBusy, "the symlink alias is refused before rendering")
    check(fileBytes(source) == before, "the source is unchanged after the symlink refusal")

    let hardlink = workDir.appendingPathComponent("export-hardlink.png")
    let linked = (try? FileManager.default.linkItem(at: source, to: hardlink)) != nil
    if linked {
        model.export(to: hardlink)
        check(!model.isBusy, "the hard-link alias is refused before rendering")
        check(fileBytes(source) == before, "the source is unchanged after the hard-link refusal")
    } else {
        print("  · hard links are not available here; NOT RUN")
    }

    // The writer itself refuses too: this is the check immediately before the
    // replace, independent of the UI's early check.
    if let image = makeImage(width: 32, height: 32) {
        let rendered = RenderedExport(image: CIImage(cgImage: image),
                                      carriesSourceMetadata: false)
        var snapshot = ExportSnapshot()
        snapshot.format = .png
        let direct = ExportService.writeResult(rendered, snapshot: snapshot, to: source,
                                               colorSpace: sRGB, metadata: [:],
                                               protecting: source)
        check(direct == .refusedOriginal, "the writer refuses the source at commit time")
        let directAlias = ExportService.writeResult(rendered, snapshot: snapshot, to: symlink,
                                                    colorSpace: sRGB, metadata: [:],
                                                    protecting: source)
        check(directAlias == .refusedOriginal, "the writer refuses a symlink at commit time")
        if linked {
            let directHardlink = ExportService.writeResult(rendered, snapshot: snapshot,
                                                           to: hardlink, colorSpace: sRGB,
                                                           metadata: [:], protecting: source)
            check(directHardlink == .refusedOriginal,
                  "the writer refuses a hard link at commit time")
        }
    }

    let valid = workDir.appendingPathComponent("export-valid.png")
    model.export(to: valid)
    check(await waitUntil(120) {
        FileManager.default.fileExists(atPath: valid.path) && !model.isBusy
    }, "a valid destination still exports")
    check(fileBytes(source) == before, "the source is unchanged after a valid export")
}

@MainActor
func testBatchDoesNotOverwriteSource() async {
    print("\n[M1-B] batch output cannot replace a source image")

    let source = workDir.appendingPathComponent("batch-source.png")
    check(makeImage(width: 480, height: 600).map { writePNG($0, to: source) } ?? false,
          "batch source written")
    guard let before = fileBytes(source) else {
        check(false, "batch source bytes are readable")
        return
    }

    let model = EditorModel()
    model.load(url: source)
    model.exportFormat = .png
    check(await waitUntil { model.hasImage && !model.isBusy }, "batch source loads")

    model.runBatch([source], to: workDir)
    check(await waitUntil(120) {
        !model.isBatchRunning && model.batchCompleted == 1
    }, "batch finishes")
    check(fileBytes(source) == before,
          "the batch leaves the source byte-for-byte unchanged")
    check(model.batchSavedCount == 1, "the batch saves a distinct output",
          "\(model.batchSavedCount)")

    let entries = (try? FileManager.default.contentsOfDirectory(
        at: workDir, includingPropertiesForKeys: nil)) ?? []
    check(entries.contains { $0.lastPathComponent.hasPrefix("batch-source-retouched") },
          "the batch output exists under a different name")
}

@MainActor
func testRuntimeTransactionalInstall() {
    print("\n[M1-AI] runtime installation is transactional")

    let manager = FileManager.default
    let oldFixture = workDir.appendingPathComponent("runtime-old-\(UUID().uuidString)")
    let newFixture = workDir.appendingPathComponent("runtime-new-\(UUID().uuidString)")
    do {
        try makeFakeRuntime(at: oldFixture, marker: "old")
        try makeFakeRuntime(at: newFixture, marker: "new")
    } catch {
        check(false, "runtime fixtures written", "\(error)")
        return
    }

    func makeSupport(_ label: String) -> URL {
        let url = workDir.appendingPathComponent("runtime-\(label)-\(UUID().uuidString)",
                                                isDirectory: true)
        try? manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func seedLive(_ support: URL, _ fixture: URL) {
        let install = AIRuntime.installDirectory(in: support)
        try? manager.createDirectory(at: install, withIntermediateDirectories: true)
        try? copyContents(of: fixture, into: install)
    }
    func extractNew(_ archive: URL, _ staging: URL) throws {
        try copyContents(of: newFixture, into: staging)
    }

    // A. A first install has no previous runtime to protect.
    let firstSupport = makeSupport("first")
    do {
        try AIRuntime.install(archive: newFixture, support: firstSupport,
                              hooks: fakeRuntimeHooks(extract: extractNew))
        let install = AIRuntime.installDirectory(in: firstSupport)
        check(AIRuntime.isStructurallyValid(root: install), "A: a first install lands")
        check(marker(at: install) == "new", "A: the first install is the new runtime")
        check(transactionState(in: firstSupport) == "committed",
              "A: the marker records a committed install")
        check(!hasBackupDirectory(in: firstSupport), "A: no backup after a first install")
        check(!hasStagingDirectory(in: firstSupport), "A: no staging after a first install")
    } catch {
        check(false, "A: first install", "\(error)")
    }

    // B. Replacing a runtime: the old copy is a backup until the new one has
    // passed the full contract.
    let replaceSupport = makeSupport("replace")
    seedLive(replaceSupport, oldFixture)
    do {
        try AIRuntime.install(archive: newFixture, support: replaceSupport,
                              hooks: fakeRuntimeHooks(extract: extractNew))
        let install = AIRuntime.installDirectory(in: replaceSupport)
        check(marker(at: install) == "new", "B: a replacement installs the new runtime")
        check(transactionState(in: replaceSupport) == "committed",
              "B: the replacement is committed")
        check(!hasBackupDirectory(in: replaceSupport),
              "B: the old runtime is deleted only after the new one is committed")
        check(!hasStagingDirectory(in: replaceSupport),
              "B: no staging remains after a replacement")
    } catch {
        check(false, "B: replacement install", "\(error)")
    }

    // C. A corrupt archive is rejected by extraction and changes nothing.
    let corruptSupport = makeSupport("corrupt")
    seedLive(corruptSupport, oldFixture)
    let corruptArchive = workDir.appendingPathComponent(
        "runtime-corrupt-\(UUID().uuidString).zip")
    try? Data("not a zip".utf8).write(to: corruptArchive)
    var corruptHooks = AIRuntime.InstallHooks()
    corruptHooks.validateRuntime = { _ in RuntimeValidationReport.success(.functional) }
    var corruptThrew = false
    do {
        try AIRuntime.install(archive: corruptArchive, support: corruptSupport,
                              hooks: corruptHooks)
    } catch {
        corruptThrew = true
    }
    check(corruptThrew, "C: a corrupt archive is rejected")
    check(marker(at: AIRuntime.installDirectory(in: corruptSupport)) == "old",
          "C: the old runtime survives a corrupt archive")
    check(!hasBackupDirectory(in: corruptSupport), "C: no backup is created for a corrupt archive")
    check(!hasStagingDirectory(in: corruptSupport),
          "C: the failed extraction leaves no staging")

    // D. A staged tree with no worker package fails the structural contract.
    let layoutSupport = makeSupport("layout")
    seedLive(layoutSupport, oldFixture)
    let incomplete = workDir.appendingPathComponent("runtime-incomplete-\(UUID().uuidString)")
    try? manager.createDirectory(at: incomplete.appendingPathComponent("bin"),
                                 withIntermediateDirectories: true)
    let incompletePython = incomplete.appendingPathComponent("bin/python3")
    try? Data("#!/bin/sh\nexit 0\n".utf8).write(to: incompletePython)
    try? manager.setAttributes([.posixPermissions: 0o755],
                               ofItemAtPath: incompletePython.path)
    var layoutThrew = false
    do {
        try AIRuntime.install(archive: incomplete, support: layoutSupport,
                              hooks: fakeRuntimeHooks(extract: { _, staging in
                                  try copyContents(of: incomplete, into: staging)
                              }))
    } catch {
        layoutThrew = true
    }
    check(layoutThrew, "D: a runtime without the worker package is rejected")
    check(marker(at: AIRuntime.installDirectory(in: layoutSupport)) == "old",
          "D: the old runtime survives a structural failure")
    check(!hasStagingDirectory(in: layoutSupport),
          "D: a structural failure leaves no staging")

    // E. A tree that is structurally complete but fails the core contract is
    // rejected before the swap.
    let functionalSupport = makeSupport("functional")
    seedLive(functionalSupport, oldFixture)
    let functionalHooks = fakeRuntimeHooks(extract: extractNew, functional: { root in
        if marker(at: root) == "new" {
            return RuntimeValidationReport.failure(.functional, "core-dependency",
                                                   "numpy: ImportError")
        }
        return RuntimeValidationReport.success(.functional)
    })
    var functionalThrew = false
    do {
        try AIRuntime.install(archive: newFixture, support: functionalSupport,
                              hooks: functionalHooks)
    } catch {
        functionalThrew = true
    }
    check(functionalThrew, "E: a runtime that fails its core imports is rejected")
    check(marker(at: AIRuntime.installDirectory(in: functionalSupport)) == "old",
          "E: the old runtime survives a functional failure")
    check(transactionState(in: functionalSupport) == "committed",
          "E: a pre-swap failure restores the previous marker state")
    check(!hasStagingDirectory(in: functionalSupport),
          "E: a pre-swap failure leaves no staging")

    // F. Crash before the old runtime is moved aside: the old copy is still
    // live, the marker says swapping, and recovery keeps the old copy.
    let crashBeforeSupport = makeSupport("crash-before")
    seedLive(crashBeforeSupport, oldFixture)
    var crashBeforeHooks = fakeRuntimeHooks(extract: extractNew)
    crashBeforeHooks.checkpoint = { point in
        if point == .beforeBackupMove { throw SimulatedRuntimeCrash() }
    }
    var crashBeforeInjected = false
    do {
        try AIRuntime.install(archive: newFixture, support: crashBeforeSupport,
                              hooks: crashBeforeHooks)
    } catch is SimulatedRuntimeCrash {
        crashBeforeInjected = true
    } catch {
        crashBeforeInjected = false
    }
    check(crashBeforeInjected, "F: the crash before the backup move is injected")
    check(transactionState(in: crashBeforeSupport) == "swapping",
          "F: the crash leaves a durable swapping marker")
    check(hasStagingDirectory(in: crashBeforeSupport), "F: the staging tree survives the crash")
    let crashBeforeRecovery = AIRuntime.recoverInterruptedInstall(
        in: crashBeforeSupport, hooks: recoveryHooks())
    check(crashBeforeRecovery.isSuccess, "F: recovery after the crash succeeds",
          crashBeforeRecovery.logLine)
    check(marker(at: AIRuntime.installDirectory(in: crashBeforeSupport)) == "old",
          "F: the old runtime stays live")
    check(transactionState(in: crashBeforeSupport) == "committed",
          "F: recovery commits the runtime it kept")
    check(!hasStagingDirectory(in: crashBeforeSupport), "F: recovery removes the staging tree")

    // G. Crash after the old runtime moved to the backup and before the new one
    // moved in: the live directory is missing, so recovery restores the backup.
    let crashBackupSupport = makeSupport("crash-backup")
    seedLive(crashBackupSupport, oldFixture)
    var crashBackupHooks = fakeRuntimeHooks(extract: extractNew)
    crashBackupHooks.checkpoint = { point in
        if point == .afterBackupMove { throw SimulatedRuntimeCrash() }
    }
    var crashBackupInjected = false
    do {
        try AIRuntime.install(archive: newFixture, support: crashBackupSupport,
                              hooks: crashBackupHooks)
    } catch is SimulatedRuntimeCrash {
        crashBackupInjected = true
    } catch {
        crashBackupInjected = false
    }
    check(crashBackupInjected, "G: the crash after the backup move is injected")
    check(!manager.fileExists(atPath: AIRuntime.installDirectory(in: crashBackupSupport).path),
          "G: the crash leaves no live runtime")
    check(marker(at: AIRuntime.backupDirectory(in: crashBackupSupport)) == "old",
          "G: the old runtime is in the backup")
    let crashBackupRecovery = AIRuntime.recoverInterruptedInstall(
        in: crashBackupSupport, hooks: recoveryHooks())
    check(crashBackupRecovery.isSuccess, "G: recovery restores the backup",
          crashBackupRecovery.logLine)
    check(marker(at: AIRuntime.installDirectory(in: crashBackupSupport)) == "old",
          "G: the old runtime is live again")
    check(!hasBackupDirectory(in: crashBackupSupport), "G: the consumed backup is gone")

    // H. Crash after the new runtime moved in but before commit: the old copy
    // is still the last known-good runtime, so recovery prefers it.
    let crashLiveSupport = makeSupport("crash-live")
    seedLive(crashLiveSupport, oldFixture)
    var crashLiveHooks = fakeRuntimeHooks(extract: extractNew)
    crashLiveHooks.checkpoint = { point in
        if point == .afterLiveMove { throw SimulatedRuntimeCrash() }
    }
    var crashLiveInjected = false
    do {
        try AIRuntime.install(archive: newFixture, support: crashLiveSupport,
                              hooks: crashLiveHooks)
    } catch is SimulatedRuntimeCrash {
        crashLiveInjected = true
    } catch {
        crashLiveInjected = false
    }
    check(crashLiveInjected, "H: the crash after the live move is injected")
    check(marker(at: AIRuntime.installDirectory(in: crashLiveSupport)) == "new",
          "H: the new runtime is momentarily live")
    let crashLiveRecovery = AIRuntime.recoverInterruptedInstall(
        in: crashLiveSupport, hooks: recoveryHooks())
    check(crashLiveRecovery.isSuccess, "H: recovery after the live move succeeds",
          crashLiveRecovery.logLine)
    check(marker(at: AIRuntime.installDirectory(in: crashLiveSupport)) == "old",
          "H: the last known-good runtime is restored")
    check(!hasBackupDirectory(in: crashLiveSupport), "H: the old backup becomes live")
    check(!hasRejectedDirectory(in: crashLiveSupport),
          "H: the uncommitted new copy is removed")

    // I. Crash after commit: the new runtime is proven, so recovery keeps it and
    // only then deletes the backup.
    let crashCommitSupport = makeSupport("crash-commit")
    seedLive(crashCommitSupport, oldFixture)
    var crashCommitHooks = fakeRuntimeHooks(extract: extractNew)
    crashCommitHooks.checkpoint = { point in
        if point == .afterCommit { throw SimulatedRuntimeCrash() }
    }
    var crashCommitInjected = false
    do {
        try AIRuntime.install(archive: newFixture, support: crashCommitSupport,
                              hooks: crashCommitHooks)
    } catch is SimulatedRuntimeCrash {
        crashCommitInjected = true
    } catch {
        crashCommitInjected = false
    }
    check(crashCommitInjected, "I: the crash after commit is injected")
    check(transactionState(in: crashCommitSupport) == "committed",
          "I: the committed marker survived the crash")
    let crashCommitRecovery = AIRuntime.recoverInterruptedInstall(
        in: crashCommitSupport, hooks: recoveryHooks())
    check(crashCommitRecovery.isSuccess, "I: recovery accepts the committed runtime",
          crashCommitRecovery.logLine)
    check(marker(at: AIRuntime.installDirectory(in: crashCommitSupport)) == "new",
          "I: the committed runtime stays live")
    check(hasBackupDirectory(in: crashCommitSupport),
          "I: a verified live copy keeps the old backup until the next install")
    check(crashCommitRecovery.warnings.contains {
              $0.contains("kept until the next install")
          }, "I: recovery reports the deferred backup cleanup",
          crashCommitRecovery.warnings.joined(separator: "; "))

    // J. A new runtime that moves in and then fails its post-swap check is
    // rolled back to the old copy.
    let postSupport = makeSupport("post")
    seedLive(postSupport, oldFixture)
    let postInstall = AIRuntime.installDirectory(in: postSupport)
    let postPlan = RuntimeVerifyPlan(root: postInstall)
    var postHooks = fakeRuntimeHooks(extract: extractNew)
    postHooks.move = { source, destination in
        try manager.moveItem(at: source, to: destination)
        if destination.standardizedFileURL == postInstall.standardizedFileURL {
            postPlan.armed = true
        }
    }
    postHooks.validateRuntime = { root in
        if postPlan.shouldReject(root) {
            return RuntimeValidationReport.failure(.functional, "startup",
                                                   "the helper did not answer")
        }
        return RuntimeValidationReport.success(.functional)
    }
    var postFailure: AIRuntimeFailure?
    do {
        try AIRuntime.install(archive: newFixture, support: postSupport,
                              hooks: postHooks)
    } catch let error as AIRuntimeFailure {
        postFailure = error
    } catch {
        postFailure = nil
    }
    check(postFailure?.code == .validation, "J: a post-swap failure is a validation failure")
    check(postFailure?.previous == .kept, "J: the error knows the old runtime was kept")
    check(marker(at: postInstall) == "old", "J: the old runtime is restored after a failed swap")
    check(transactionState(in: postSupport) == "committed",
          "J: the restored runtime is committed")
    check(!hasBackupDirectory(in: postSupport), "J: the backup is consumed by the rollback")
    check(!hasStagingDirectory(in: postSupport), "J: the failed post-swap leaves no staging")

    // K. If moving the old runtime to the backup fails, it never left its place
    // and the message must not claim it was lost.
    let keptSupport = makeSupport("kept")
    seedLive(keptSupport, oldFixture)
    let keptBackup = AIRuntime.backupDirectory(in: keptSupport)
    var keptHooks = fakeRuntimeHooks(extract: extractNew)
    keptHooks.move = { source, destination in
        if destination.standardizedFileURL == keptBackup.standardizedFileURL {
            throw RuntimeTestFailure()
        }
        try manager.moveItem(at: source, to: destination)
    }
    var keptFailure: AIRuntimeFailure?
    do {
        try AIRuntime.install(archive: newFixture, support: keptSupport, hooks: keptHooks)
    } catch let error as AIRuntimeFailure {
        keptFailure = error
    } catch {
        keptFailure = nil
    }
    check(keptFailure?.code == .install, "K: a failed backup move is an install failure")
    check(keptFailure?.previous == .kept, "K: the error knows the old runtime never moved")
    check(keptFailure?.localizedDescription == L10n.current.aiRuntimeInstallFailed,
          "K: the message says the previous runtime was kept",
          keptFailure?.localizedDescription ?? "")
    check(marker(at: AIRuntime.installDirectory(in: keptSupport)) == "old",
          "K: the old runtime remains live")
    check(transactionState(in: keptSupport) == "committed",
          "K: the marker records the still-live runtime")

    // L. A first install that fails after the swap leaves nothing live and must
    // not claim a previous runtime was kept.
    let firstFailSupport = makeSupport("first-fail")
    let firstFailInstall = AIRuntime.installDirectory(in: firstFailSupport)
    let firstFailPlan = RuntimeVerifyPlan(root: firstFailInstall)
    var firstFailHooks = fakeRuntimeHooks(extract: extractNew)
    firstFailHooks.move = { source, destination in
        try manager.moveItem(at: source, to: destination)
        if destination.standardizedFileURL == firstFailInstall.standardizedFileURL {
            firstFailPlan.armed = true
        }
    }
    firstFailHooks.validateRuntime = { root in
        if firstFailPlan.shouldReject(root) {
            return RuntimeValidationReport.failure(.functional, "startup",
                                                   "the helper did not answer")
        }
        return RuntimeValidationReport.success(.functional)
    }
    var firstFailFailure: AIRuntimeFailure?
    do {
        try AIRuntime.install(archive: newFixture, support: firstFailSupport,
                              hooks: firstFailHooks)
    } catch let error as AIRuntimeFailure {
        firstFailFailure = error
    } catch {
        firstFailFailure = nil
    }
    check(firstFailFailure?.code == .validation, "L: a first install failure is reported")
    check(firstFailFailure?.previous == AIRuntimeFailure.PreviousRuntime.none,
          "L: the error knows there was no previous runtime")
    check(firstFailFailure?.localizedDescription == L10n.current.aiRuntimeInstallFailedNothing,
          "L: the message does not claim a previous runtime was kept",
          firstFailFailure?.localizedDescription ?? "")
    check(!manager.fileExists(atPath: firstFailInstall.path),
          "L: a failed first install leaves nothing live")
    check(transactionMarker(in: firstFailSupport) == nil,
          "L: a failed first install leaves no marker")
    check(!hasStagingDirectory(in: firstFailSupport),
          "L: a failed first install leaves no staging")

    // M. If the rollback itself cannot restore the backup, it must say so and
    // keep the old runtime in the backup for a later recovery.
    let rollbackSupport = makeSupport("rollback")
    seedLive(rollbackSupport, oldFixture)
    let rollbackInstall = AIRuntime.installDirectory(in: rollbackSupport)
    let rollbackBackup = AIRuntime.backupDirectory(in: rollbackSupport)
    let rollbackPlan = RuntimeVerifyPlan(root: rollbackInstall)
    var rollbackHooks = fakeRuntimeHooks(extract: extractNew)
    rollbackHooks.move = { source, destination in
        if destination.standardizedFileURL == rollbackInstall.standardizedFileURL {
            rollbackPlan.armed = true
        }
        if source.standardizedFileURL == rollbackBackup.standardizedFileURL {
            throw RuntimeTestFailure()
        }
        try manager.moveItem(at: source, to: destination)
    }
    rollbackHooks.validateRuntime = { root in
        if rollbackPlan.shouldReject(root) {
            return RuntimeValidationReport.failure(.functional, "startup",
                                                   "the helper did not answer")
        }
        return RuntimeValidationReport.success(.functional)
    }
    var rollbackFailure: AIRuntimeFailure?
    do {
        try AIRuntime.install(archive: newFixture, support: rollbackSupport,
                              hooks: rollbackHooks)
    } catch let error as AIRuntimeFailure {
        rollbackFailure = error
    } catch {
        rollbackFailure = nil
    }
    check(rollbackFailure?.code == .validation, "M: a failed rollback is reported")
    check(rollbackFailure?.previous == .preserved,
          "M: the error knows the old runtime is preserved, not live")
    check(rollbackFailure?.localizedDescription == L10n.current.aiRuntimeInstallFailedPreserved,
          "M: the message says the previous runtime was preserved for recovery",
          rollbackFailure?.localizedDescription ?? "")
    check(marker(at: rollbackBackup) == "old",
          "M: the old runtime is preserved in the backup")
    check(!manager.fileExists(atPath: rollbackInstall.path),
          "M: no unverified runtime is left live")
    check(hasRejectedDirectory(in: rollbackSupport),
          "M: the rejected new copy is kept for inspection")
    check(transactionState(in: rollbackSupport) == "rollingBack",
          "M: the marker stays honest after a failed rollback")
}

@MainActor
func testRuntimeMarkerAndRecoverySafety() {
    print("\n[M1-AI2] a damaged marker or a symlink cannot reach outside the runtime folder")

    let manager = FileManager.default
    let oldFixture = workDir.appendingPathComponent("runtime-old-\(UUID().uuidString)")
    do {
        try makeFakeRuntime(at: oldFixture, marker: "old")
    } catch {
        check(false, "runtime fixture written", "\(error)")
        return
    }

    func makeSupport(_ label: String) -> URL {
        let url = workDir.appendingPathComponent("runtime-\(label)-\(UUID().uuidString)",
                                                isDirectory: true)
        try? manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func seedLive(_ support: URL) {
        let install = AIRuntime.installDirectory(in: support)
        try? manager.createDirectory(at: install, withIntermediateDirectories: true)
        try? copyContents(of: oldFixture, into: install)
    }

    // The marker is treated as untrusted input: unreadable JSON, a JSON object
    // with unexpected fields, a non-UUID id and a directory in its place are all
    // rejected without touching any runtime file.
    let brokenJSON = makeSupport("broken-json")
    seedLive(brokenJSON)
    try? Data("{not json".utf8).write(to: brokenJSON.appendingPathComponent(
        "runtime-transaction.json"))
    let brokenResult = AIRuntime.recoverInterruptedInstall(in: brokenJSON,
                                                           hooks: recoveryHooks())
    check(brokenResult.failure?.code == .invalidMarker,
          "N: unreadable marker JSON is rejected")
    check(marker(at: AIRuntime.installDirectory(in: brokenJSON)) == "old",
          "N: the live runtime is untouched when the marker is unreadable")
    check(!hasRejectedDirectory(in: brokenJSON),
          "N: no directory is moved for an unreadable marker")

    let canary = workDir.appendingPathComponent("canary-\(UUID().uuidString)")
    try? Data("keep".utf8).write(to: canary)

    let absoluteID = makeSupport("absolute-id")
    try? writeTransactionMarker(in: absoluteID, id: canary.path,
                                state: "swapping", hadPrevious: true)
    let absoluteResult = AIRuntime.recoverInterruptedInstall(in: absoluteID,
                                                             hooks: recoveryHooks())
    check(absoluteResult.failure?.code == .invalidMarker,
          "N: a path in the id field is rejected")
    check(fileBytes(canary) != nil,
          "N: a path in the id cannot delete a file outside the runtime folder")

    let extraField = makeSupport("extra-field")
    try? writeTransactionMarker(in: extraField,
                                id: UUID().uuidString,
                                state: "swapping", hadPrevious: true,
                                extra: ["path": canary.path])
    let extraResult = AIRuntime.recoverInterruptedInstall(in: extraField,
                                                          hooks: recoveryHooks())
    check(extraResult.failure?.code == .invalidMarker,
          "N: unexpected fields in the marker are rejected")
    check(fileBytes(canary) != nil,
          "N: an unexpected path field cannot reach outside the runtime folder")

    let malformedID = makeSupport("malformed-id")
    try? writeTransactionMarker(in: malformedID, id: "../outside",
                                state: "swapping", hadPrevious: true)
    let malformedResult = AIRuntime.recoverInterruptedInstall(in: malformedID,
                                                              hooks: recoveryHooks())
    check(malformedResult.failure?.code == .invalidMarker,
          "N: a traversal id is rejected")

    let directoryMarker = makeSupport("directory-marker")
    try? manager.createDirectory(
        at: directoryMarker.appendingPathComponent("runtime-transaction.json"),
        withIntermediateDirectories: true)
    let directoryResult = AIRuntime.recoverInterruptedInstall(in: directoryMarker,
                                                              hooks: recoveryHooks())
    check(directoryResult.failure?.code == .invalidMarker,
          "N: a directory in place of the marker is rejected")

    // A symlinked live or backup directory is never followed, even when the
    // marker is otherwise valid.
    let outside = workDir.appendingPathComponent("outside-\(UUID().uuidString)")
    try? manager.createDirectory(at: outside, withIntermediateDirectories: true)
    try? copyContents(of: oldFixture, into: outside)

    let symlinkBackup = makeSupport("symlink-backup")
    try? manager.createSymbolicLink(at: AIRuntime.backupDirectory(in: symlinkBackup),
                                    withDestinationURL: outside)
    try? writeTransactionMarker(in: symlinkBackup, id: UUID().uuidString,
                                state: "swapping", hadPrevious: true)
    let symlinkBackupResult = AIRuntime.recoverInterruptedInstall(
        in: symlinkBackup, hooks: recoveryHooks())
    check(symlinkBackupResult.failure?.code == .unsafePath,
          "N: a symlinked backup is rejected")
    check(marker(at: outside) == "old",
          "N: the symlink target is never moved or modified")

    let symlinkLive = makeSupport("symlink-live")
    try? manager.createSymbolicLink(at: AIRuntime.installDirectory(in: symlinkLive),
                                    withDestinationURL: outside)
    let symlinkLiveResult = AIRuntime.recoverInterruptedInstall(
        in: symlinkLive, hooks: recoveryHooks())
    check(symlinkLiveResult.failure?.code == .unsafePath,
          "N: a symlinked live runtime is rejected")
    check(marker(at: outside) == "old",
          "N: the live symlink target is never modified")

    // A committed runtime whose files are gone is a failure, not a silent
    // "installed" answer.
    let missing = makeSupport("missing")
    try? writeTransactionMarker(in: missing, id: UUID().uuidString,
                                state: "committed", hadPrevious: false)
    let missingResult = AIRuntime.recoverInterruptedInstall(in: missing,
                                                            hooks: recoveryHooks())
    check(missingResult.failure?.code == .liveInvalid,
          "N: a committed marker with no live runtime is a failure")

    // A committed live copy that no longer passes the contract is replaced by
    // the validated backup instead of deleting the backup first.
    let committedBroken = makeSupport("committed-broken")
    let brokenInstall = AIRuntime.installDirectory(in: committedBroken)
    try? manager.createDirectory(at: brokenInstall, withIntermediateDirectories: true)
    try? Data("half".utf8).write(to: brokenInstall.appendingPathComponent("half"))
    let brokenBackup = AIRuntime.backupDirectory(in: committedBroken)
    try? manager.createDirectory(at: brokenBackup, withIntermediateDirectories: true)
    try? copyContents(of: oldFixture, into: brokenBackup)
    try? writeTransactionMarker(in: committedBroken, id: UUID().uuidString,
                                state: "committed", hadPrevious: true)
    let committedBrokenResult = AIRuntime.recoverInterruptedInstall(
        in: committedBroken, hooks: recoveryHooks())
    check(committedBrokenResult.isSuccess, "N: a broken committed runtime is repaired",
          committedBrokenResult.logLine)
    check(marker(at: brokenInstall) == "old",
          "N: the validated backup replaces the broken live copy")
    check(!hasBackupDirectory(in: committedBroken),
          "N: the backup is consumed only after the restored copy validates")

    // A fresh staging folder with no marker could belong to an older install,
    // so it is left alone; an old one is swept.
    let freshStaging = makeSupport("fresh-staging")
    let stagingPrefix = AIRuntime.installDirectory(in: freshStaging)
        .lastPathComponent + "-installing-"
    let fresh = freshStaging.appendingPathComponent(stagingPrefix + "fresh")
    try? manager.createDirectory(at: fresh, withIntermediateDirectories: true)
    let freshResult = AIRuntime.recoverInterruptedInstall(in: freshStaging,
                                                          hooks: recoveryHooks())
    check(freshResult.isSuccess, "N: a marker-less support folder recovers cleanly")
    check(manager.fileExists(atPath: fresh.path),
          "N: a fresh marker-less staging folder is not deleted")

    let staleStaging = makeSupport("stale-staging")
    let stale = staleStaging.appendingPathComponent(
        AIRuntime.installDirectory(in: staleStaging).lastPathComponent + "-installing-stale")
    try? manager.createDirectory(at: stale, withIntermediateDirectories: true)
    try? manager.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)],
                               ofItemAtPath: stale.path)
    _ = AIRuntime.recoverInterruptedInstall(in: staleStaging, hooks: recoveryHooks())
    check(!manager.fileExists(atPath: stale.path),
          "N: stale marker-less staging data is swept")
}

@MainActor
func testRuntimeRecoveryBeforeUse() {
    print("\n[M1-AI3] a failed recovery is retried, a good one is cached, and AI use waits for it")

    let manager = FileManager.default
    let oldFixture = workDir.appendingPathComponent("runtime-old-\(UUID().uuidString)")
    do {
        try makeFakeRuntime(at: oldFixture, marker: "old")
    } catch {
        check(false, "runtime fixture written", "\(error)")
        return
    }

    // The worker recovers an update interrupted while the app was closed before
    // it reports a runtime.
    let useSupport = workDir.appendingPathComponent("runtime-use-\(UUID().uuidString)",
                                                   isDirectory: true)
    try? manager.createDirectory(at: useSupport, withIntermediateDirectories: true)
    let useBackup = AIRuntime.backupDirectory(in: useSupport)
    try? manager.createDirectory(at: useBackup, withIntermediateDirectories: true)
    try? copyContents(of: oldFixture, into: useBackup)
    let useResult = AIWorker.recoverRuntimeIfNeeded(force: true, support: useSupport,
                                                    hooks: recoveryHooks())
    check(useResult.isSuccess, "R: the worker recovers before looking up a helper",
          useResult.logLine)
    check(marker(at: AIRuntime.installDirectory(in: useSupport)) == "old",
          "R: the old runtime is restored before use")
    check(AIRuntime.isStructurallyValid(root: AIRuntime.installDirectory(in: useSupport)),
          "R: the recovered runtime passes the layout contract")
    check(!hasBackupDirectory(in: useSupport), "R: the backup is consumed after a good restore")

    // A failed recovery is not cached as done: the next use retries.
    let retrySupport = workDir.appendingPathComponent("runtime-retry-\(UUID().uuidString)",
                                                     isDirectory: true)
    try? manager.createDirectory(at: retrySupport, withIntermediateDirectories: true)
    try? Data("{bad".utf8).write(to: retrySupport.appendingPathComponent(
        "runtime-transaction.json"))
    let firstAttempt = AIWorker.recoverRuntimeIfNeeded(force: true, support: retrySupport,
                                                       hooks: recoveryHooks())
    check(!firstAttempt.isSuccess, "R: a failed recovery is reported")
    try? manager.removeItem(at: retrySupport.appendingPathComponent("runtime-transaction.json"))
    let retryInstall = AIRuntime.installDirectory(in: retrySupport)
    try? manager.createDirectory(at: retryInstall, withIntermediateDirectories: true)
    try? copyContents(of: oldFixture, into: retryInstall)
    let secondAttempt = AIWorker.recoverRuntimeIfNeeded(support: retrySupport,
                                                        hooks: recoveryHooks())
    check(secondAttempt.isSuccess, "R: the next use retries a failed recovery",
          secondAttempt.logLine)
    check(marker(at: retryInstall) == "old", "R: the retry adopts the live runtime")

    // AIWorker's gate: a runtime that passes the functional contract is usable;
    // the answer is cached until the runtime changes.
    let gateSupport = workDir.appendingPathComponent("runtime-gate-\(UUID().uuidString)",
                                                    isDirectory: true)
    try? manager.createDirectory(at: gateSupport, withIntermediateDirectories: true)
    let gateInstall = AIRuntime.installDirectory(in: gateSupport)
    try? manager.createDirectory(at: gateInstall, withIntermediateDirectories: true)
    try? copyContents(of: oldFixture, into: gateInstall)
    AIWorker.runtimeDidChange(support: gateSupport)
    check(AIWorker.downloadedRuntimeUsable(support: gateSupport, hooks: recoveryHooks()),
          "P: a runtime that passes the functional contract is usable")
    let refusing = recoveryHooks(functional: { _ in
        RuntimeValidationReport.failure(.functional, "startup", "refused by the test")
    })
    check(AIWorker.downloadedRuntimeUsable(support: gateSupport, hooks: refusing),
          "P: the validated answer is cached for this process")
    AIWorker.runtimeDidChange(support: gateSupport)
    check(!AIWorker.downloadedRuntimeUsable(support: gateSupport, hooks: refusing),
          "P: an invalid runtime is refused after the cache is cleared")
    check(AIWorker.runtimeProblem(support: gateSupport) != nil,
          "P: the refusal is available to the error message")

    let capsSupport = workDir.appendingPathComponent("runtime-caps-\(UUID().uuidString)",
                                                    isDirectory: true)
    try? manager.createDirectory(at: capsSupport, withIntermediateDirectories: true)
    let capsInstall = AIRuntime.installDirectory(in: capsSupport)
    try? manager.createDirectory(at: capsInstall, withIntermediateDirectories: true)
    try? copyContents(of: oldFixture, into: capsInstall)
    AIWorker.runtimeDidChange(support: capsSupport)
    let capsHooks = recoveryHooks(functional: { _ in
        RuntimeValidationReport.success(.functional,
                                        capabilities: ["segmentation": false,
                                                       "image-generation": true])
    })
    check(AIWorker.downloadedRuntimeUsable(support: capsSupport, hooks: capsHooks),
          "P: a missing optional backend does not invalidate the runtime")

    let blockedSupport = workDir.appendingPathComponent("runtime-blocked-\(UUID().uuidString)",
                                                       isDirectory: true)
    try? manager.createDirectory(at: blockedSupport, withIntermediateDirectories: true)
    let blockedInstall = AIRuntime.installDirectory(in: blockedSupport)
    try? manager.createDirectory(at: blockedInstall, withIntermediateDirectories: true)
    try? copyContents(of: oldFixture, into: blockedInstall)
    try? Data("{bad".utf8).write(to: blockedSupport.appendingPathComponent(
        "runtime-transaction.json"))
    AIWorker.runtimeDidChange(support: blockedSupport)
    check(!AIWorker.downloadedRuntimeUsable(support: blockedSupport, hooks: recoveryHooks()),
          "P: an unresolved transaction blocks runtime selection")
}

@MainActor
func testRuntimeConcurrentInstall() {
    print("\n[M1-AI4] concurrent installs serialize on one shared transaction lock")

    let manager = FileManager.default
    let support = workDir.appendingPathComponent("runtime-concurrent-\(UUID().uuidString)",
                                                isDirectory: true)
    try? manager.createDirectory(at: support, withIntermediateDirectories: true)

    var fixtures: [URL] = []
    for index in 0..<4 {
        let fixture = workDir.appendingPathComponent(
            "runtime-concurrent-\(index)-\(UUID().uuidString)")
        do {
            try makeFakeRuntime(at: fixture, marker: "v\(index)")
            fixtures.append(fixture)
        } catch {
            check(false, "O: concurrent fixtures written", "\(error)")
            return
        }
    }

    let errors = NSLock()
    var collected: [String] = []
    let group = DispatchGroup()
    for fixture in fixtures {
        DispatchQueue.global().async(group: group) {
            var hooks = fakeRuntimeHooks(extract: { _, staging in
                try copyContents(of: fixture, into: staging)
            })
            hooks.validateRuntime = { root in
                let layout = AIRuntimeValidation.structural(root: root)
                guard layout.ok else { return layout }
                return RuntimeValidationReport.success(.functional)
            }
            do {
                try AIRuntime.install(archive: fixture, support: support, hooks: hooks)
            } catch {
                errors.lock()
                collected.append("\(error)")
                errors.unlock()
            }
        }
    }
    group.wait()

    check(collected.isEmpty, "O: every concurrent install finishes", collected.joined(separator: "; "))
    let install = AIRuntime.installDirectory(in: support)
    check(AIRuntime.isStructurallyValid(root: install),
          "O: the surviving runtime passes the layout contract")
    check(transactionState(in: support) == "committed",
          "O: the final marker is committed")
    check(!hasStagingDirectory(in: support), "O: no staging is left behind")
    check(!hasBackupDirectory(in: support), "O: no backup is left behind")
    check(!hasRejectedDirectory(in: support), "O: no rejected copy is left behind")
    let lockPath = support.appendingPathComponent("runtime.lock")
    var isDirectory: ObjCBool = false
    let lockIsFile = manager.fileExists(atPath: lockPath.path, isDirectory: &isDirectory)
        && !isDirectory.boolValue
    var info = stat()
    let notSymlink = lockPath.path.withCString { lstat($0, &info) } == 0
        && (info.st_mode & S_IFMT) == S_IFREG
    check(lockIsFile && notSymlink, "O: the lock file is a persistent regular file")
}

@MainActor
func testRealRuntimeValidation() {
    print("\n[M1-AI-R] the real runtime passes the functional contract")

    guard ProcessInfo.processInfo.environment["RETOUCH_REAL_RUNTIME"] == "1" else {
        print("  · skipped (set RETOUCH_REAL_RUNTIME=1 to probe an installed runtime)")
        return
    }

    var candidates: [URL] = []
    if let bundled = AIWorker.bundledRoot { candidates.append(bundled) }
    let installed = AIRuntime.installDirectory
    if FileManager.default.fileExists(atPath: installed.path) {
        candidates.append(installed)
    }
    guard let root = candidates.first(where: { AIRuntime.isStructurallyValid(root: $0) }) else {
        check(false, "a structurally valid real runtime is available")
        return
    }

    func fingerprint(_ root: URL) -> String {
        ["bin/python3", "retouch_ai_worker", "site-packages"].map { name in
            let url = root.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey,
                                                            .fileSizeKey])
            return "\(name):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values?.fileSize ?? 0)"
        }.joined(separator: "|")
    }

    let before = fingerprint(root)
    let report = AIRuntimeValidation.functional(root: root)
    check(report.ok, "the real runtime starts, imports its core and answers health",
          report.logLine)
    check(report.capabilities["segmentation"] != nil,
          "optional capability availability is reported separately")
    check(AIRuntime.isStructurallyValid(root: root),
          "the functional probe leaves the real runtime valid")
    check(fingerprint(root) == before,
          "the functional probe does not modify the runtime")
}

@MainActor
func testRecoveryIsolation(productionBefore: RecoveryFingerprint) async {
    print("\n[M1-R15] the suite never writes the production recovery tree")

    await settleRecoveryWrites()

    check(RecoveryStore.directory.standardizedFileURL
            != RecoveryStore.productionDirectory.standardizedFileURL,
          "recovery writes are redirected away from Application Support")
    check(RecoveryStore.directory.path.hasPrefix(workDir.path),
          "the test recovery root is inside the scratch directory")

    let settings = AppSettings.shared
    let previousRecoverySetting = settings.recoveryEnabled
    settings.recoveryEnabled = true
    defer { settings.recoveryEnabled = previousRecoverySetting }

    let source = workDir.appendingPathComponent("isolation-photo.png")
    check(makeImage(width: 320, height: 400).map { writePNG($0, to: source) } ?? false,
          "isolation fixture written")
    let model = EditorModel()
    model.load(url: source)
    check(await waitUntil(60) { model.hasImage && !model.isBusy }, "isolation fixture loads")
    model.adjustments.exposure = 0.3
    model.flushAutosave()
    check(RecoveryStore.readWorking()?.project.imagePath == source.path,
          "the autosave lands in the working slot of the test directory")
    check(recoveryCandidates().isEmpty,
          "the autosave does not create a candidate")

    let productionAfter = RecoveryFingerprint.capture(RecoveryStore.productionDirectory)
    check(productionAfter == productionBefore,
          "the production recovery tree is untouched by the whole suite")
}

// MARK: - R4.0 document-state characterization

/// Loads a fresh model from a throwaway photo. The characterization tests use
/// only public editor API, so the R4.1 extraction must leave them unchanged.
@MainActor
func makeCharacterizationModel(_ name: String) async -> (EditorModel, URL)? {
    let url = workDir.appendingPathComponent("\(name)-\(UUID().uuidString).png")
    guard let image = makeImage(width: 480, height: 600), writePNG(image, to: url) else {
        check(false, "\(name): fixture written")
        return nil
    }
    let model = EditorModel()
    model.load(url: url)
    guard await waitUntil(60, { model.hasImage && !model.isBusy }) else {
        check(false, "\(name): fixture loads")
        return nil
    }
    return (model, url)
}

/// Pins the eight values `EditState` covers and the three things they drive:
/// the clean baseline, undo/redo and the snapshots taken for export and
/// autosave. Nothing here depends on the debounce elapsing.
@MainActor
func testDocumentStateDefaultsAndDirtyTracking() async {
    print("\n[R4.0] the eight document fields, their defaults and dirty tracking")

    guard let (model, _) = await makeCharacterizationModel("r4-defaults") else { return }

    check(model.adjustments == Adjustments(), "a fresh load starts with zeroed adjustments")
    check(model.healSpots.isEmpty, "a fresh load starts with no healing stamps")
    check(model.stickers.isEmpty, "a fresh load starts with no stickers")
    check(model.aiEdits.isEmpty, "a fresh load starts with no AI edits")
    check(model.analysis == AnalysisSettings(), "a fresh load starts with default analysis settings")
    check(model.appliedCrop == nil, "a fresh load starts with the whole frame")
    check(model.documentOrientation == .identity, "a fresh load starts upright")
    check(model.selectedFaceIndex == nil, "a fresh load leaves the face on automatic")
    check(model.isDocumentPristine, "a fresh load is pristine")
    check(!model.hasUnsavedChanges && !model.canUndo && !model.canRedo,
          "a fresh load is clean with no history")

    // Adjustments
    model.adjustments.smooth = 18
    check(model.hasUnsavedChanges, "an adjustment marks the document dirty")
    check(model.canUndo, "an uncommitted adjustment is already undoable")
    model.undo()
    check(model.adjustments.smooth == 0 && !model.hasUnsavedChanges,
          "undo restores the slider and the clean baseline")
    check(model.canRedo, "the undone adjustment is redoable")
    model.redo()
    check(model.adjustments.smooth == 18 && model.hasUnsavedChanges, "redo reapplies the adjustment")
    model.undo()
    check(!model.hasUnsavedChanges, "the document is clean again")

    // Healing stamp
    model.tapHeal(at: CGPoint(x: 0.5, y: 0.5))
    check(model.healSpots.count == 1, "a tap places one healing stamp")
    check(model.hasUnsavedChanges && model.canUndo, "a healing stamp is document data")
    model.undo()
    _ = await waitUntil { !model.isBusy }
    check(model.healSpots.isEmpty && !model.hasUnsavedChanges,
          "undo removes the stamp and the dirty flag")
    model.redo()
    _ = await waitUntil { !model.isBusy }
    check(model.healSpots.count == 1 && model.hasUnsavedChanges, "redo brings the stamp back")
    model.undo()
    _ = await waitUntil { !model.isBusy }

    // Sticker
    model.tapArt(at: CGPoint(x: 0.4, y: 0.4))
    check(model.stickers.count == 1, "a tap places one sticker")
    check(model.hasUnsavedChanges && model.canUndo, "a sticker is document data")
    model.undo()
    _ = await waitUntil { !model.isBusy }
    check(model.stickers.isEmpty && !model.hasUnsavedChanges,
          "undo removes the sticker and the dirty flag")
    model.redo()
    _ = await waitUntil { !model.isBusy }
    check(model.stickers.count == 1 && model.hasUnsavedChanges, "redo brings the sticker back")
    model.undo()
    _ = await waitUntil { !model.isBusy }

    // Analysis overlay
    model.analysis.isEnabled = true
    check(model.hasUnsavedChanges && model.canUndo, "the analysis overlay is document data")
    model.undo()
    check(model.analysis == AnalysisSettings() && !model.hasUnsavedChanges,
          "undo restores the default analysis settings")
    model.redo()
    check(model.analysis.isEnabled && model.hasUnsavedChanges, "redo re-enables the overlay")
    model.undo()
    check(!model.hasUnsavedChanges, "the document is clean again")

    // AI edit
    let box = CGRect(x: 0.25, y: 0.25, width: 0.3, height: 0.3)
    guard let edit = storedAIEdit(box: box) else {
        check(false, "the AI edit files are staged")
        return
    }
    defer { AIEditStore.remove(edit) }
    model.addAIEdit(edit)
    _ = await waitUntil { !model.isBusy }
    check(model.aiEdits == [edit], "the AI edit joins the document")
    check(model.hasUnsavedChanges && model.canUndo, "an AI edit is document data")
    model.undo()
    _ = await waitUntil { !model.isBusy }
    check(model.aiEdits.isEmpty && !model.hasUnsavedChanges, "one undo removes the AI edit")
    model.redo()
    _ = await waitUntil { !model.isBusy }
    check(model.aiEdits == [edit] && model.hasUnsavedChanges, "redo restores the AI edit")
    model.removeLastAIEdit()
    _ = await waitUntil { !model.isBusy }
    check(model.aiEdits.isEmpty && !model.hasUnsavedChanges,
          "removing the last AI edit returns to the clean baseline")
    model.undo()
    _ = await waitUntil { !model.isBusy }
    check(model.aiEdits == [edit] && model.hasUnsavedChanges,
          "undo restores an AI edit that was removed")
    model.redo()
    _ = await waitUntil { !model.isBusy }
    check(model.aiEdits.isEmpty && !model.hasUnsavedChanges, "redo removes it again")

    // Preferences a project carries but the document does not own.
    let previousSettings = (model.exportQuality, model.exportLongEdge, model.exportFormat,
                            model.autoRetouchStrength, model.autoColorStrength,
                            model.comparePosition, model.showFaceOverlay)
    defer {
        model.exportQuality = previousSettings.0
        model.exportLongEdge = previousSettings.1
        model.exportFormat = previousSettings.2
        model.autoRetouchStrength = previousSettings.3
        model.autoColorStrength = previousSettings.4
        model.comparePosition = previousSettings.5
        model.showFaceOverlay = previousSettings.6
    }
    let undoBefore = model.canUndo
    model.exportQuality = 0.5
    model.exportLongEdge = 2400
    model.exportFormat = .png
    model.autoRetouchStrength = 25
    model.autoColorStrength = 40
    model.comparePosition = 0.2
    model.showFaceOverlay = true
    check(!model.hasUnsavedChanges,
          "export settings and auto strengths do not mark the document dirty")
    check(model.canUndo == undoBefore, "they also add no undo step")
}

/// Pins when a change becomes a step: a pending debounce is flushed by undo,
/// repeated commits are no-ops, a new edit discards the redo branch and the
/// stack keeps the last 100 states.
@MainActor
func testDocumentStateHistoryBehavior() async {
    print("\n[R4.0] undo/redo step rules")

    guard let (model, _) = await makeCharacterizationModel("r4-history") else { return }

    model.commitAdjustments()
    check(!model.canUndo, "committing an unchanged document records no step")

    model.adjustments.contrast = 30
    check(model.canUndo && model.hasUnsavedChanges,
          "a debounced change is undoable before the idle window elapses")
    model.undo()
    check(model.adjustments.contrast == 0 && !model.hasUnsavedChanges,
          "undo flushes a pending debounce and restores the baseline")
    model.redo()
    check(model.adjustments.contrast == 30 && model.hasUnsavedChanges, "redo replays it")
    model.undo()

    model.adjustments.exposure = 10
    model.commitAdjustments()
    model.commitAdjustments()
    model.undo()
    check(model.adjustments.exposure == 0 && !model.hasUnsavedChanges,
          "a repeated commit does not add a second step")

    model.adjustments.exposure = 10
    model.commitAdjustments()
    model.adjustments.exposure = 20
    model.commitAdjustments()
    model.undo()
    check(model.adjustments.exposure == 10 && model.canRedo, "undo returns one step")
    model.adjustments.exposure = 40
    model.commitAdjustments()
    check(!model.canRedo, "editing after undo discards the redo branch")
    model.undo()
    check(model.adjustments.exposure == 10, "the new branch undoes to its own base")
    model.undo()
    check(model.adjustments.exposure == 0, "the older branch is still reachable")

    for value in 1...105 {
        model.adjustments.smooth = Double(value)
        model.commitAdjustments()
    }
    for _ in 0..<100 { model.undo() }
    check(model.adjustments.smooth == 5,
          "history keeps the most recent 100 steps", "oldest retained value is 5")
    check(!model.canUndo, "older steps were dropped")
    model.adjustments.smooth = 0
    model.commitAdjustments()
    check(!model.hasUnsavedChanges, "the document returns to its clean baseline")
}

/// Pins what autosave sees: the same `RetouchProject` save writes, captured by
/// value, with empty fields normalized away and removed once the document is
/// clean again.
@MainActor
func testDocumentStateAutosaveCapture() async {
    print("\n[R4.0] autosave captures the same document value")

    let previousRecovery = AppSettings.shared.recoveryEnabled
    AppSettings.shared.recoveryEnabled = true
    defer {
        RecoveryStore.invalidatePendingAutosaves()
        _ = RecoveryStore.removeWorking()
        AppSettings.shared.recoveryEnabled = previousRecovery
    }
    RecoveryStore.invalidatePendingAutosaves()
    _ = RecoveryStore.removeWorking()

    guard let (model, url) = await makeCharacterizationModel("r4-autosave") else { return }
    check(RecoveryStore.readWorking() == nil, "a clean document has no working copy")

    model.adjustments.smooth = 22
    model.flushAutosave()
    let working = RecoveryStore.readWorking()
    check(working?.project.imagePath == url.path, "the working copy names the open photo")
    check(working?.project.adjustments.smooth == 22, "autosave carries the adjustment")
    check(working?.project.healSpots == nil, "empty stamps stay normalized away")
    check(working?.project.version == RetouchProject.currentVersion,
          "the copy is a current-version project")

    var project = RetouchProject(imagePath: url.path, adjustments: Adjustments(),
                                 exportFormat: "jpeg", exportQuality: 0.92,
                                 autoRetouchStrength: 70)
    project.adjustments.smooth = 11
    let snapshot = RecoverySnapshot.capture(project)
    project.adjustments.smooth = 64
    check(snapshot.project.adjustments.smooth == 11,
          "a snapshot owns a copy of the project, not a reference")

    model.adjustments.smooth = 0
    check(!model.hasUnsavedChanges && RecoveryStore.readWorking() == nil,
          "returning to the clean baseline removes the working copy")
}

/// Pins what Save Project writes: every document field, the preferences the
/// project carries, and the nil normalization of empty/default values.
@MainActor
func testDocumentStateProjectNormalization() async {
    print("\n[R4.0] project save writes the document and normalizes defaults")

    let folder = workDir.appendingPathComponent("r4-project-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let photoURL = folder.appendingPathComponent("photo.png")
    guard let image = makeImage(width: 480, height: 600), writePNG(image, to: photoURL) else {
        check(false, "project fixture")
        return
    }
    let projectURL = folder.appendingPathComponent("edit.retouch")
    let initial = RetouchProject(imagePath: photoURL.path,
                                 adjustments: Adjustments(),
                                 exportFormat: "jpeg", exportQuality: 0.9,
                                 autoRetouchStrength: 70)
    check(writeProject(initial, to: projectURL), "the project fixture is written")

    let model = EditorModel()
    model.openProject(at: projectURL)
    check(await waitUntil { model.hasImage && !model.isBusy }, "the project opens")
    check(!model.hasUnsavedChanges && model.projectURL == projectURL,
          "an opened project starts clean")

    let previous = (model.exportQuality, model.autoRetouchStrength, model.autoColorStrength)
    defer {
        model.exportQuality = previous.0
        model.autoRetouchStrength = previous.1
        model.autoColorStrength = previous.2
    }
    model.exportQuality = 0.77
    model.autoRetouchStrength = 33
    model.autoColorStrength = 44
    check(!model.hasUnsavedChanges,
          "export and auto preferences are written to a project but are not document dirt")

    model.adjustments.smooth = 33
    check(model.hasUnsavedChanges, "a slider change is still dirt")
    model.saveProject()
    check(!model.hasUnsavedChanges && model.projectURL == projectURL,
          "save moves the clean baseline")

    guard let data = try? Data(contentsOf: projectURL),
          let saved = try? JSONDecoder().decode(RetouchProject.self, from: data) else {
        check(false, "the saved project decodes")
        return
    }
    check(saved.version == RetouchProject.currentVersion, "the project is written at version 3")
    check(saved.imagePath == photoURL.path, "the project names the photo")
    check(saved.adjustments.smooth == 33, "the adjustment is written")
    check(saved.exportQuality == 0.77 && saved.autoRetouchStrength == 33
              && saved.autoColorStrength == 44,
          "export and auto preferences are written")
    check(saved.exportLongEdge == nil && saved.crop == nil
              && saved.healSpots == nil && saved.stickers == nil
              && saved.aiEdits == nil && saved.analysis == nil
              && saved.orientation == nil && saved.selectedFace == nil,
          "empty and default fields are normalized away")
}

/// Pins that the export snapshot reads the same eight fields the history and
/// dirty comparison use, and gets its remaining switches from the caller.
@MainActor
func testDocumentStateExportSnapshot() async {
    print("\n[R4.0] the export snapshot reads the same eight document fields")

    guard let (model, _) = await makeCharacterizationModel("r4-export") else { return }

    model.adjustments.smooth = 21
    model.tapHeal(at: CGPoint(x: 0.6, y: 0.4))
    model.tapArt(at: CGPoint(x: 0.35, y: 0.6))
    model.analysis.isEnabled = true
    _ = await waitUntil { !model.isBusy }

    let previous = (model.exportQuality, model.exportLongEdge, model.stripLocationMetadata)
    defer {
        model.exportQuality = previous.0
        model.exportLongEdge = previous.1
        model.stripLocationMetadata = previous.2
    }
    model.exportQuality = 0.66
    model.exportLongEdge = 2400
    model.stripLocationMetadata = false

    guard let snapshot = model.makeExportSnapshot(includeStamps: false,
                                                  includeAnalysis: false) else {
        check(false, "an export snapshot exists for an open photo")
        return
    }
    check(snapshot.adjustments == model.adjustments, "adjustments travel")
    check(snapshot.healSpots == model.healSpots, "healing stamps travel")
    check(snapshot.stickers == model.stickers, "stickers travel")
    check(snapshot.aiEdits == model.aiEdits, "AI edits travel")
    check(snapshot.analysis == model.analysis, "analysis settings travel")
    check(snapshot.crop == model.appliedCrop, "the crop travels")
    check(snapshot.orientation == model.documentOrientation, "the orientation travels")
    check(snapshot.selectedFaceIndex == model.selectedFaceIndex, "the face selection travels")
    check(snapshot.quality == 0.66 && snapshot.longEdge == 2400
              && snapshot.stripsPrivacyMetadata == false,
          "export settings are supplied by the application layer")
    check(snapshot.includeStamps == false && snapshot.includeAnalysis == false,
          "batch switches are supplied by the caller")
    check(snapshot.aiUpscale == model.usesExportUpscale,
          "the upscale choice follows the same runtime gate as the sheet")

    model.resetAll()
    _ = await waitUntil { !model.isBusy }
}

// MARK: - R4.1 DocumentState value semantics

/// Pins the extracted value itself: the eight fields, their defaults, equality
/// and copy behavior. The model-level characterization above proves the editor
/// still observes the same values through it.
@MainActor
func testDocumentStateValueSemantics() {
    print("\n[R4.1] DocumentState defaults, equality and copying")

    let empty = DocumentState()
    check(empty.adjustments == Adjustments(), "default adjustments are the identity")
    check(empty.healSpots.isEmpty && empty.stickers.isEmpty && empty.aiEdits.isEmpty,
          "default collections are empty")
    check(empty.analysis == AnalysisSettings(), "default analysis settings are the defaults")
    check(empty.crop == nil, "the default crop is the whole frame")
    check(empty.orientation == .identity, "the default orientation is identity")
    check(empty.selectedFaceIndex == nil, "the default face is automatic")
    check(empty == DocumentState(), "two fresh states are equal")

    var edit = DocumentState()
    edit.adjustments.smooth = 12
    edit.healSpots = [HealSpot(center: CGPoint(x: 0.1, y: 0.2), radius: 0.03)]
    edit.stickers = [Sticker(center: CGPoint(x: 0.3, y: 0.4), size: 0.2)]
    edit.aiEdits = [AIEdit(preset: "removeObject", prompt: "test", seed: 7,
                           patchFile: "patch.png", alphaFile: "alpha.png",
                           box: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           imagePixels: CGSize(width: 64, height: 64))]
    edit.analysis.isEnabled = true
    edit.crop = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.6)
    edit.orientation = DocumentOrientation(quarterTurns: 1)
    edit.selectedFaceIndex = 2

    check(empty.adjustments.isIdentity && empty.healSpots.isEmpty
              && empty.stickers.isEmpty && empty.aiEdits.isEmpty
              && empty.analysis == AnalysisSettings() && empty.crop == nil
              && empty.orientation == .identity && empty.selectedFaceIndex == nil,
          "building another state leaves the first one untouched")

    var copy = edit
    copy.adjustments.contrast = 9
    copy.healSpots.append(HealSpot(center: CGPoint(x: 0.5, y: 0.5), radius: 0.04))
    copy.stickers.removeAll()
    copy.crop = nil
    check(edit.adjustments.contrast == 0 && edit.healSpots.count == 1
              && edit.stickers.count == 1 && edit.crop != nil,
          "a copy owns its own values and arrays")

    let same = DocumentState(adjustments: edit.adjustments,
                             healSpots: edit.healSpots,
                             stickers: edit.stickers,
                             aiEdits: edit.aiEdits,
                             analysis: edit.analysis,
                             crop: edit.crop,
                             orientation: edit.orientation,
                             selectedFaceIndex: edit.selectedFaceIndex)
    check(same == edit, "equal fields compare equal")

    let mutations: [(String, (inout DocumentState) -> Void)] = [
        ("adjustments", { $0.adjustments.smooth += 1 }),
        ("healSpots", { $0.healSpots.append(HealSpot(center: .zero, radius: 0.01)) }),
        ("stickers", { $0.stickers.append(Sticker(center: .zero, size: 0.1)) }),
        ("aiEdits", { $0.aiEdits.removeAll() }),
        ("analysis", { $0.analysis.isEnabled.toggle() }),
        ("crop", { $0.crop = nil }),
        ("orientation", { $0.orientation = .identity }),
        ("selectedFaceIndex", { $0.selectedFaceIndex = nil }),
    ]
    for (label, mutate) in mutations {
        var variant = edit
        mutate(&variant)
        check(variant != edit, "equality distinguishes \(label)")
    }
}

// MARK: - R4.2 DocumentSession history value

/// Pins the history transitions themselves, without a model or a window. The
/// R4.0 suite above proves `EditorModel` still produces the same steps and
/// dirty transitions through this value.
@MainActor
func testDocumentSessionHistoryValue() {
    print("\n[R4.2] DocumentSession owns undo, redo, cap and baseline")

    var session = DocumentSession()
    let base = DocumentState()
    check(!session.canUndo(current: base) && !session.canRedo(current: base),
          "a fresh session offers no history")
    check(session.lastCommitted == base && session.cleanState == base,
          "a fresh session records and cleans the empty document")

    var contrast = base
    contrast.adjustments.contrast = 30
    check(session.canUndo(current: contrast),
          "an uncommitted change is already undoable")
    session.commit(contrast)
    check(session.undoStack.count == 1 && session.lastCommitted == contrast,
          "a commit records the previous state")

    session.commit(contrast)
    check(session.undoStack.count == 1, "committing the same state again adds no step")

    guard let undone = session.undo(current: contrast) else {
        check(false, "undo returns the recorded state")
        return
    }
    check(undone == base && session.redoStack.count == 1 && session.lastCommitted == base,
          "undo returns the previous state and keeps the branch")
    check(session.canRedo(current: undone), "redo is offered while the branch is intact")

    guard let redone = session.redo(current: undone) else {
        check(false, "redo returns the branch state")
        return
    }
    check(redone == contrast && session.undoStack.count == 1
              && session.lastCommitted == contrast,
          "redo replays it and restores the undo side")

    var exposure = base
    exposure.adjustments.exposure = 12
    session.commit(exposure)
    check(session.redoStack.isEmpty, "a new commit discards the redo branch")

    var cap = DocumentSession()
    for value in 1...105 {
        var state = DocumentState()
        state.adjustments.smooth = Double(value)
        cap.commit(state)
    }
    check(cap.undoStack.count == DocumentSession.stepLimit,
          "the stack keeps the most recent \(DocumentSession.stepLimit) steps")
    var walked = DocumentState()
    walked.adjustments.smooth = 105
    var oldest = walked
    for _ in 0..<DocumentSession.stepLimit {
        guard let previous = cap.undo(current: walked) else { break }
        walked = previous
        oldest = previous
    }
    check(oldest.adjustments.smooth == 5,
          "the oldest retained step is the 100th before the last",
          "\(oldest.adjustments.smooth)")
    check(!cap.canUndo(current: walked), "steps beyond the cap are gone")
    check(cap.undo(current: walked) == nil, "undoing past the cap returns nothing")

    var reset = DocumentSession()
    reset.commit(contrast)
    reset.markClean(exposure)
    check(reset.cleanState == exposure && reset.lastCommitted == contrast
              && reset.undoStack.count == 1,
          "marking clean moves only the baseline")
    reset.reset(to: exposure)
    check(reset.undoStack.isEmpty && reset.redoStack.isEmpty
              && reset.lastCommitted == exposure && reset.cleanState == exposure,
          "reset starts a new document with no history")

    var original = DocumentSession()
    original.commit(contrast)
    var copy = original
    copy.commit(exposure)
    check(original.undoStack.count == 1 && copy.undoStack.count == 2,
          "a copied session owns its own stacks")
}

// MARK: - runner

@MainActor
func runAll() async {
    await testExportDoesNotSave()
    await testSmartKeepsUnmeasuredFields()
    await testResetAllClearsEverything()
    await testCropIsUndoable()
    await testOrientationKeepsEditsAttached()
    testStudioGeometryBridge()
    testBatchExportPolicy()
    await testBatchMatchesSingleExport()
    await testBatchKeepsCropAfterQuarterTurn()
    await testProjectRelink()
    await testProjectVersionGuard()
    testProjectV3BaselineByteIdentity()
    testProjectCodecFieldMapping()
    testProjectCodecNormalization()
    testProjectCodecLegacyDecode()
    testProjectCodecVersionGuard()
    testProjectCodecReproducesBaseline()
    testProjectSourceResolverOrder()
    testProjectCodecRelinkRewrite()
    testDocumentRestorationFromProject()
    testDocumentRestorationDefaultsAndPhoto()
    testExportPlannerNaming()
    testExportPlannerPixelSize()
    testExportPlannerSnapshot()
    testBatchPlannerFilePolicy()
    testBatchPlannerUpscaleAndNaming()
    await testOperationCoordination()
    await testBatchCancellationStopsInFlightFile()
    await testBatchWriteFailureIsNotCounted()
    await testPreviewStaysAtPreviewResolution()
    await testPrivacySettingDefaults()
    await testAIEditBoundaries()
    await testAIProjectRoundTrip()
    await testAIEditUndoAndExport()
    await testAIMaskRenderer()
    await testQuickEditSelectionGating()
    await testFullFrameReimagine()
    await testExportUpscalePolicy()
    await testAnalysisExportNeedsFace()
    testRecoveryChoiceMapping()
    testRecoveryPolicyDecisions()
    await testRestoreLeavesSameImageCandidateIntact()
    await testCancelKeepsEveryCandidateWhileThirdDocumentEdits()
    await testMissingSourceCancelKeepsCandidate()
    await testMovedSourceLocateThenRestore()
    await testRestoreTwoDifferentDocuments()
    await testFailedPreservationKeepsLiveDocument()
    await testCrashBeforeRestoredSnapshotWrite()
    await testCrashAfterWorkingWriteBeforeCandidateDelete()
    await testFailedPromotionKeepsRecoveryCopy()
    await testFailedCandidateDeleteOnDiscard()
    await testSeveralLaunchesKeepSeveralCandidates()
    await testRecoveryPreferenceKeepsCandidates()
    await testCorruptCandidateIsQuarantined()
    await testChangedSourceAsksBeforeRestore()
    await testWorkingSlotIsPromotedAtLaunch()
    await testExternalOpenPromotesWorkingSnapshotFirst()
    await testExternalOpenPromotionFailureKeepsWorking()
    await testQueuedExternalOpensKeepOneCandidate()
    await testDiscardInvalidatesInFlightAutosave()
    await testReplacementInvalidatesOldDocumentAutosave()
    await testFailedLoadPreservesDocument()
    await testExportProtectsSource()
    await testBatchDoesNotOverwriteSource()
    testRuntimeTransactionalInstall()
    testRuntimeMarkerAndRecoverySafety()
    testRuntimeRecoveryBeforeUse()
    testRuntimeConcurrentInstall()
    testRealRuntimeValidation()
    await testRecoveryIsolation(productionBefore: productionRecoveryBefore)
    await testDocumentStateDefaultsAndDirtyTracking()
    await testDocumentStateHistoryBehavior()
    await testDocumentStateAutosaveCapture()
    await testDocumentStateProjectNormalization()
    await testDocumentStateExportSnapshot()
    testDocumentStateValueSemantics()
    testDocumentSessionHistoryValue()

    // Invalidate any debounced write left by the last scenario: the scratch
    // directory is about to disappear, and no timer may outlive it.
    RecoveryStore.invalidatePendingAutosaves()

    print("\n" + String(repeating: "-", count: 60))
    removeRecentEntries(under: workDir)
    try? FileManager.default.removeItem(at: workDir)
    if failures.isEmpty {
        print("MODEL TESTS: PASS")
        exit(0)
    } else {
        print("MODEL TESTS: FAIL (\(failures.count))")
        for failure in failures { print("   - \(failure)") }
        exit(1)
    }
}

Task { @MainActor in
    await runAll()
}
dispatchMain()
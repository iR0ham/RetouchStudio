import AppKit
import CoreGraphics
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class EditorModel: ObservableObject {

    // Adjustments
    @Published var adjustments = Adjustments()
    @Published var compareEnabled = true
    @Published var comparePosition: Double = 0.45
    @Published var showFaceOverlay = false

    // Export
    @Published var showExportSheet = false
    @Published var exportFormat: ExportFormat = .jpeg
    @Published var exportQuality: Double = 0.92

    // State
    @Published private(set) var originalImage: NSImage?
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var faces: [FaceGeometry] = []
    @Published private(set) var isBusy = false
    @Published private(set) var status = ""
    @Published private(set) var imageName = ""
    @Published private(set) var imageInfo = ""
    @Published private(set) var hasImage = false
    @Published private(set) var faceCount = 0

    // MARK: - Undo / redo

    private var undoStack: [Adjustments] = []
    private var redoStack: [Adjustments] = []
    private var lastCommitted: Adjustments = Adjustments()
    private var coalesceTask: Task<Void, Never>?

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Records the current adjustments as an undo step. Consecutive rapid
    /// changes (dragging one slider) collapse into a single step so undo does
    /// not need fifty presses to escape one drag.
    func commitAdjustments() {
        let current = adjustments
        guard current != lastCommitted else { return }
        coalesceTask?.cancel()
        undoStack.append(lastCommitted)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        lastCommitted = current
        updateUndoFlags()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(adjustments)
        adjustments = previous
        lastCommitted = previous
        updateUndoFlags()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(adjustments)
        adjustments = next
        lastCommitted = next
        updateUndoFlags()
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    /// Zeroes one effect and records it as a single undo step.
    func resetEffect(_ keyPath: WritableKeyPath<Adjustments, Double>) {
        guard adjustments[keyPath: keyPath] != 0 else { return }
        commitAdjustments()
        adjustments[keyPath: keyPath] = 0
        commitAdjustments()
    }

    /// Zeroes a whole group (skin, reshape or color/light) while leaving the
    /// other groups exactly as they were.
    func resetGroup(_ group: AdjustmentGroup) {
        guard !adjustments.isIdentity else { return }
        commitAdjustments()
        var next = Adjustments()
        switch group {
        case .skin:
            // Keep geometry and color/light.
            next = next.applyingReshape(adjustments.reshapeOnly)
                       .applyingColorLight(adjustments.colorLightOnly)
        case .reshape:
            next = next.applyingRetouch(adjustments.retouchOnly)
                       .applyingColorLight(adjustments.colorLightOnly)
        case .colorLight:
            next = next.applyingRetouch(adjustments.retouchOnly)
                       .applyingReshape(adjustments.reshapeOnly)
        }
        adjustments = next
        commitAdjustments()
    }

    /// UI copy. The app is English-only.
    let s = L10n.shared
    @Published private(set) var previewSize = CGSize(width: 1, height: 1)

    // Canvas view state. zoom == 1 means the image is fitted to the window.
    @Published var zoom: Double = 1
    @Published var panOffset: CGSize = .zero
    @Published private(set) var canvasSize: CGSize = .zero
    @Published var toolMode: ToolMode = .skin

    private let processor = ImageProcessor.shared
    private let previewMaxDimension: CGFloat = 1800

    /// Restores the neutral status shown when no image is open.
    func refreshDefaultStatus() {
        if !hasImage { status = s.dropHint }
    }

    private var sourceFull: CIImage?
    private var sourcePreview: CIImage?
    private var masksFull: MaskSet?
    private var masksPreview: MaskSet?
    private var renderTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var generation = 0

    // MARK: - Input

    func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a photo to retouch"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url: url)
    }

    func load(url: URL) {
        loadTask?.cancel()
        renderTask?.cancel()
        generation += 1
        let generation = self.generation

        isBusy = true
        status = s.readingImage
        imageName = url.lastPathComponent

        let processor = self.processor
        let previewMaxDimension = self.previewMaxDimension

        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                processor.load(from: url, previewMaxDimension: previewMaxDimension)
            }.value

            guard let self, self.generation == generation else { return }
            guard let result else {
                self.isBusy = false
                self.status = self.s.couldNotRead
                return
            }
            self.apply(result)
        }
    }

    private func apply(_ result: LoadResult) {
        sourceFull = result.sourceFull
        sourcePreview = result.sourcePreview
        masksFull = result.masksFull
        masksPreview = result.masksPreview
        faces = result.faces
        faceCount = result.faces.count
        originalImage = NSImage(cgImage: result.originalPreview,
                               size: NSSize(width: result.originalPreview.width, height: result.originalPreview.height))
        previewImage = NSImage(cgImage: result.preview,
                              size: NSSize(width: result.preview.width, height: result.preview.height))
        previewSize = CGSize(width: result.preview.width, height: result.preview.height)
        imageInfo = "\(Int(result.pixelSize.width)) × \(Int(result.pixelSize.height)) px"
        imageName = result.fileName
        hasImage = true
        adjustments = .zero
        comparePosition = 0.45
        resetView()
        isBusy = false

        if result.faces.isEmpty {
            status = s.noFaceColorOnly
        } else {
            status = s.facesDetected(result.faces.count)
        }
    }

    // MARK: - Zoom and pan

    /// Zoom limits. Fit (1×) up to 400%, which is what the UI exposes.
    /// The pixel-accurate cap is applied only to the *fit* scale, never used to
    /// clamp below 4×, so 400% is always reachable.
    let zoomRange: ClosedRange<Double> = 1...4

    /// Maximum zoom that still shows real image pixels. Used only as a hint; it
    /// never lowers the ceiling below the 400% the UI promises.
    private var pixelAccurateMaxZoom: Double {
        let w = Double(previewSize.width), h = Double(previewSize.height)
        let cw = Double(canvasSize.width), ch = Double(canvasSize.height)
        guard w > 0, h > 0, cw > 0, ch > 0 else { return zoomRange.upperBound }
        let fitScale = min(cw / w, ch / h)
        return max(1, 1 / fitScale)
    }

    var effectiveMaxZoom: Double { zoomRange.upperBound }

    /// True when zooming further would only stretch pixels rather than reveal
    /// detail. The UI can use this to warn, but it does not cap the zoom.
    var isBeyondPixelAccuracy: Bool { zoom > pixelAccurateMaxZoom }

    /// Size of the image on screen when fitted (no zoom).
    var fittedCanvasSize: CGSize {
        guard previewSize.width > 0, previewSize.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
        let scale = min(canvasSize.width / previewSize.width, canvasSize.height / previewSize.height)
        return CGSize(width: previewSize.width * scale, height: previewSize.height * scale)
    }

    /// Size of the image on screen including zoom.
    var displayedCanvasSize: CGSize {
        let fitted = fittedCanvasSize
        guard fitted.width > 0, fitted.height > 0 else { return .zero }
        return CGSize(width: fitted.width * zoom, height: fitted.height * zoom)
    }

    /// Keeps the zoomed image from being dragged out of the canvas.
    func clampPan() {
        let displayed = displayedCanvasSize
        guard displayed.width > 0, canvasSize.width > 0 else {
            panOffset = .zero
            return
        }
        let maxX = max(0, (displayed.width - canvasSize.width) / 2)
        let maxY = max(0, (displayed.height - canvasSize.height) / 2)
        panOffset = CGSize(width: min(maxX, max(-maxX, panOffset.width)),
                           height: min(maxY, max(-maxY, panOffset.height)))
    }

    func setZoom(_ value: Double, anchor: CGPoint? = nil) {
        let clamped = min(effectiveMaxZoom, max(zoomRange.lowerBound, value))
        let oldZoom = zoom
        let displayed = displayedCanvasSize

        // Zoom about the pointer: the image point under the cursor stays put.
        //   A = cursor position relative to the canvas centre
        //   pan' = A − (A − pan) × (zoom' / zoom)
        if let anchor, oldZoom > 0, displayed.width > 0, displayed.height > 0,
           canvasSize.width > 0, canvasSize.height > 0 {
            let ratio = clamped / oldZoom
            let ax = anchor.x - canvasSize.width / 2
            let ay = anchor.y - canvasSize.height / 2
            panOffset.width = ax - (ax - panOffset.width) * ratio
            panOffset.height = ay - (ay - panOffset.height) * ratio
        }

        zoom = clamped
        if clamped <= 1.0001 {
            panOffset = .zero
        } else {
            clampPan()
        }
    }

    func zoomIn() { setZoom(zoom * 1.5) }
    func zoomOut() { setZoom(zoom / 1.5) }

    func resetView() {
        zoom = 1
        panOffset = .zero
    }

    func updateCanvasSize(_ size: CGSize) {
        guard size != canvasSize else { return }
        canvasSize = size
        if zoom > effectiveMaxZoom { zoom = effectiveMaxZoom }
        clampPan()
    }

    // MARK: - Preview

    func schedulePreview() {
        guard let source = sourcePreview else { return }
        renderTask?.cancel()
        generation += 1
        let generation = self.generation

        let adjustments = self.adjustments
        let masks = self.masksPreview
        let processor = self.processor
        isBusy = true

        renderTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            if Task.isCancelled { return }
            // The user has stopped dragging for a moment: record an undo step.
            self?.commitAdjustments()

            let cgImage = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                let processed = processor.process(source, adjustments: adjustments, masks: masks)
                return processor.renderCGImage(processed, scale: 1)
            }.value

            guard let self, self.generation == generation else { return }
            if let cgImage {
                self.previewImage = NSImage(cgImage: cgImage,
                                           size: NSSize(width: cgImage.width, height: cgImage.height))
            }
            self.isBusy = false
        }
    }

    // MARK: - Adjustments

    func resetAll() {
        commitAdjustments()
        adjustments = .zero
        comparePosition = 0.45
        commitAdjustments()
    }

    func apply(_ preset: Preset) {
        adjustments = preset.adjustments
    }

    func binding(for keyPath: WritableKeyPath<Adjustments, Double>) -> Binding<Double> {
        Binding(get: { self.adjustments[keyPath: keyPath] },
                set: { self.adjustments[keyPath: keyPath] = $0 })
    }

    func isActive(_ preset: Preset) -> Bool {
        adjustments == preset.adjustments
    }

    // MARK: - Auto

    /// "Auto Color & Light": derives only the color/light fields from the image
    /// itself. Skin, teeth and eye adjustments are left exactly as they were.
    func autoColorLight() {
        guard let source = sourcePreview else { return }
        isBusy = true
        status = s.analyzingColor
        Task { [weak self] in
            let patch = await Task.detached(priority: .userInitiated) { () -> Adjustments? in
                guard let buffer = AutoAnalyzer.analysisBuffer(source) else { return nil }
                return AutoAnalyzer.autoColorLight(buffer)
            }.value
            guard let self else { return }
            self.isBusy = false
            guard let patch else {
                self.status = self.s.autoColorFailed
                return
            }
            // Only the color/light fields are replaced; the retouch and reshape
            // sliders are carried over untouched.
            self.commitAdjustments()
            self.adjustments = self.adjustments.applyingColorLight(patch)
            self.commitAdjustments()
            self.status = self.s.autoColorApplied
        }
    }

    /// "Auto Retouch": derives only the skin/eye/teeth fields. Color and light
    /// settings are left exactly as they were.
    func autoRetouch() {
        guard let source = sourcePreview else { return }
        guard !faces.isEmpty else {
            status = s.autoRetouchNeedsFace
            return
        }
        isBusy = true
        status = s.analyzingSkin
        let faces = self.faces
        let faceMask = self.masksPreview?.face
        Task { [weak self] in
            let patch = await Task.detached(priority: .userInitiated) { () -> Adjustments? in
                guard let buffer = AutoAnalyzer.analysisBuffer(source) else { return nil }
                let overall = AutoAnalyzer.stats(buffer).meanLuminance
                let maskBuffer = faceMask.flatMap { AutoAnalyzer.analysisBuffer($0) }
                return AutoAnalyzer.autoRetouch(buffer,
                                                faceMask: maskBuffer,
                                                faces: faces,
                                                globalMeanLuminance: overall)
            }.value
            guard let self else { return }
            self.isBusy = false
            guard let patch else {
                self.status = self.s.autoRetouchFailed
                return
            }
            // Only the retouch fields are replaced; geometry and color/light
            // are carried over untouched.
            self.commitAdjustments()
            self.adjustments = self.adjustments.applyingRetouch(patch)
            self.commitAdjustments()
            self.status = self.s.autoRetouchApplied
        }
    }

    // MARK: - Status text

    var faceStatusText: String {
        guard hasImage else { return s.noImageSelected }
        if faceCount == 0 { return s.noFaceDetected }
        return s.facesDetected(faceCount)
    }

    var faceStatusIsGood: Bool { faceCount > 0 }

    // MARK: - Export

    func presentExportSheet() {
        guard hasImage else { return }
        showExportSheet = true
    }

    func suggestedFileName() -> String {
        let base = (imageName as NSString).deletingPathExtension
        let name = base.isEmpty ? "retouched" : "\(base)-retouched"
        return "\(name).\(exportFormat.fileExtension)"
    }

    func saveExport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFileName()
        panel.allowedContentTypes = [exportFormat.utType]
        panel.canCreateDirectories = true
        panel.message = "Choose where to save the retouched image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        export(to: url)
    }

    func export(to url: URL) {
        guard let source = sourceFull else { return }
        let adjustments = self.adjustments
        let masks = self.masksFull
        let processor = self.processor
        let format = self.exportFormat
        let quality = self.exportQuality

        isBusy = true
        status = s.renderingExport

        Task { [weak self] in
            let success = await Task.detached(priority: .userInitiated) { () -> Bool in
                let processed = processor.process(source, adjustments: adjustments, masks: masks)
                return processor.write(processed, to: url, format: format, quality: quality)
            }.value

            guard let self else { return }
            self.isBusy = false
            if success {
                self.showExportSheet = false
                self.status = self.s.saved(url.lastPathComponent)
            } else {
                self.status = self.s.exportFailed
            }
        }
    }
}

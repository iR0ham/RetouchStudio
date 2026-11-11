import AppKit
import Combine
import CoreGraphics
import CoreImage
import SwiftUI
import StudioCore
import UniformTypeIdentifiers

@MainActor
final class EditorModel: ObservableObject {

    /// Preferences that outlive a photo, and the files under Open Recent.
    let settings = AppSettings.shared
    let recents = RecentStore.shared

    // Adjustments
    @Published var adjustments = Adjustments() {
        didSet { adjustmentsChanged() }
    }
    @Published var compareEnabled = true
    @Published var comparePosition: Double = 0.45 {
        didSet { settings.comparePosition = comparePosition }
    }
    /// True while Space is held. The canvas shows the untouched original, so
    /// the owner can check the edit against the photo without moving the split.
    @Published var isPeekingOriginal = false
    @Published var showFaceOverlay = false {
        didSet { settings.showFaceOverlay = showFaceOverlay }
    }
    /// How strongly Auto Retouch's derived values are applied. 100 applies the
    /// analysis as measured; lower values scale every effect down together.
    @Published var autoRetouchStrength: Double = 70 {
        didSet { settings.autoRetouchStrength = autoRetouchStrength }
    }
    /// How strongly Auto Color & Light's derived values are applied. The auto
    /// measures the photo; this decides how much of that measurement to use.
    @Published var autoColorStrength: Double = 100 {
        didSet { settings.autoColorStrength = autoColorStrength }
    }
    /// The language of the interface. Published so every view redraws the
    /// moment it changes.
    @Published var language: AppLanguage = AppLanguage.current {
        didSet { settings.language = language }
    }

    // Export
    @Published var showExportSheet = false
    @Published var exportFormat: ExportFormat = .jpeg {
        didSet { settings.exportFormat = exportFormat.rawValue }
    }
    @Published var exportQuality: Double = 0.92 {
        didSet { settings.exportQuality = exportQuality }
    }
    /// Longest exported edge in pixels; 0 keeps the photo's own size.
    @Published var exportLongEdge: Int = 0 {
        didSet { settings.exportLongEdge = exportLongEdge }
    }
    /// Ask the local upscaler for the pixels a larger long edge implies. It only
    /// applies while that edge is above the photo's own; see `usesExportUpscale`.
    @Published var exportAIUpscale = false {
        didSet { settings.exportAIUpscale = exportAIUpscale }
    }
    /// Leave GPS and camera identity out of exports.
    @Published var stripLocationMetadata = true {
        didSet { settings.stripLocationMetadata = stripLocationMetadata }
    }
    /// Signature burned into exported copies. Held in preferences rather than
    /// the project: it describes how this owner publishes, not how this photo
    /// was retouched.
    @Published var watermark = WatermarkSettings.disabled {
        didSet { settings.watermark = watermark }
    }

    // Batch export
    @Published var showBatchSheet = false
    /// Stamps and analysis describe the face that is open, so a batch starts
    /// with both switched off.
    @Published var batchIncludeStamps = false
    @Published var batchIncludeAnalysis = false
    @Published private(set) var isBatchRunning = false
    @Published private(set) var batchTotal = 0
    @Published private(set) var batchCompleted = 0
    @Published private(set) var batchSavedCount = 0
    @Published private(set) var batchSkippedCrops = 0
    @Published private(set) var batchHasReport = false

    // State
    @Published private(set) var originalImage: NSImage?
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var faces: [FaceGeometry] = []
    /// Which accepted face the owner is working on, as an index into `faces`
    /// (largest first). `nil` means automatic: the largest face for callouts
    /// and the median width for feature sizes.
    @Published private(set) var selectedFaceIndex: Int?
    /// The makeup palette each accepted face measured, in the same order.
    private var faceFamilies: [MakeupFamily] = []
    @Published private(set) var isBusy = false
    /// True while a full-quality export is rendering, so the export sheet can
    /// offer to cancel it instead of starting a second one.
    @Published private(set) var isExporting = false
    @Published private(set) var statusToken: StatusToken = .none
    @Published private(set) var imageName = ""
    @Published private(set) var imageURL: URL?
    @Published private(set) var hasImage = false
    @Published private(set) var faceCount = 0
    /// Where this edit was last saved as a project, if anywhere.
    @Published private(set) var projectURL: URL?
    /// Looks the owner saved from their own sliders, in the order they made them.
    @Published private(set) var userPresets: [UserPreset] = UserPresetStore.load()
    /// One small render per preset, made from the photo that is open.
    @Published private(set) var presetThumbs: [String: NSImage] = [:]
    /// Crop relative to the original photo, normalized with a top-left origin.
    /// `nil` means the whole frame.
    @Published private(set) var appliedCrop: CGRect?
    /// The crop being set in the overlay, relative to the image on screen.
    @Published var cropDraft: CGRect = CropGeometry.full
    @Published private(set) var cropAspect: CropAspect = .free
    /// Manual healing stamps, stored against the original photo.
    @Published private(set) var healSpots: [HealSpot] = [] {
        didSet { healSpotsChanged() }
    }
    /// Stickers placed by the art tool, stored against the original photo in
    /// the same coordinates as the healing stamps.
    @Published private(set) var stickers: [Sticker] = [] {
        didSet { stickersChanged() }
    }
    @Published var selectedSticker: UUID?
    /// Generative edits produced by the local AI helper. Each one is a layer of
    /// pixels plus an alpha; the photo itself is never rewritten.
    @Published private(set) var aiEdits: [AIEdit] = [] {
        didSet {
            guard !isLoadingState else { return }
            schedulePreview()
            updateCleanState()
        }
    }

    // Quick Edit
    /// True while the canvas is waiting for the click that marks the object.
    @Published var isAIPicking = false
    @Published var quickEditPreset: AIQuickPreset = .removeObject
    /// The owner's own words for a Reimagine. Empty means "use the preset's
    /// sentence", which is what the masked presets always do.
    @Published var quickEditPrompt = ""
    /// Where the owner clicked, normalized against the working (cropped) frame.
    /// `nil` until the canvas has a point.
    @Published private(set) var quickEditPoint: CGPoint?
    // Mask selection. Point, brush and box are alternative ways to say where;
    // a new point clears the mask and the first stroke clears the point, so a
    // job always has exactly one meaning.
    @Published var aiMaskTool: AIMaskTool = .point
    @Published private(set) var aiMaskStrokes: [AIMaskStroke] = []
    @Published private(set) var aiMaskBox: CGRect?
    @Published private(set) var aiMaskRefined: CGImage?
    @Published var aiMaskInverted = false {
        didSet { refreshAIMaskPreview() }
    }
    @Published var aiMaskExpand: Double = 4
    @Published var aiMaskFeather: Double = 2
    /// Brush diameter as a fraction of the photo width.
    @Published var aiMaskStrokeWidth: Double = 0.035
    @Published var aiMaskErasing = false
    /// Tinted selection for the canvas, derived from the mask.
    @Published private(set) var aiMaskPreview: CGImage?
    @Published private(set) var isRefiningMask = false
    @Published private(set) var aiMaskMessage: String?
    private var maskTask: Task<Void, Never>?
    @Published private(set) var quickEditStage: QuickEditStage = .idle
    @Published private(set) var isRunningQuickEdit = false
    private var aiTask: Task<Void, Never>?
    private var aiJobID: String?
    private var quickEditCancelRequested = false
    /// The analysis overlay's switches, regions and leader ends. It is drawn in
    /// its own layer rather than folded into the photo pipeline: choosing a
    /// region must not re-run every retouch pass on the picture.
    @Published var analysis = AnalysisSettings() {
        didSet { analysisChanged() }
    }
    /// The overlay as it stands, drawn at preview resolution. Kept here so
    /// panning and zooming do not redraw the mesh on every frame.
    @Published private(set) var analysisOverlay: CGImage?
    /// Brush diameter as a percentage of the short side, so one setting covers
    /// every photo size and the stamp means the same thing on preview and export.
    @Published var healBrushPercent: Double = 1.6 {
        didSet { settings.healBrushPercent = healBrushPercent }
    }

    // Smart Analyze
    /// What the last analysis measured. Nil until a photo has been read, and
    /// cleared whenever a different photo is loaded.
    @Published private(set) var smartReport: SmartAnalyzer.Report?
    @Published private(set) var isAnalyzingSmart = false
    @Published var showSmartSheet = false
    /// Which groups of the suggestion the owner wants applied.
    @Published var smartApplyRetouch = true
    @Published var smartApplyColorLight = true
    @Published var smartApplyHealSpots = true

    /// Pixel size of the working (possibly cropped) image, used for aspect math
    /// and the crop size readout.
    @Published private(set) var workingPixelSize: CGSize = .zero
    /// Turn baked into the current pixels. Stored edits describe this frame, so
    /// changing it rewrites their coordinates before the reload.
    @Published private(set) var documentOrientation: DocumentOrientation = .identity
    /// Size of the upright source before any crop, the frame orientation
    /// changes are mapped through.
    private(set) var sourcePixelSize: CGSize = .zero
    /// True when the sliders differ from the state that was loaded or last
    /// exported, which is what the discard prompt is about.
    @Published private(set) var hasUnsavedChanges = false
    /// Whether the subject silhouette that Body and Background need has been
    /// built. `unknown` means no such control has been touched yet, so the
    /// expensive segmentation has not run.
    @Published private(set) var subjectState: SubjectMaskState = .unknown
    /// True when Vision found a body pose with usable hips or shoulders, so the
    /// waist, arm and leg sliders have joints to work around.
    @Published private(set) var hasBodyPose = false

    /// Which pose-driven groups lack their joints on this photo, in words for
    /// the inspector. A pose can exist and still miss the pairs a slider needs;
    /// saying so beats leaving that slider looking broken.
    var bodyPoseGaps: [String] {
        guard let pose = masksPreview?.pose else { return [] }
        var gaps: [String] = []
        if !pose.hasWaistJoints { gaps.append(s.poseMissingWaist) }
        if !pose.hasArmJoints { gaps.append(s.poseMissingArms) }
        if !pose.hasLegJoints { gaps.append(s.poseMissingLegs) }
        return gaps
    }

    // MARK: - Operation coordination

    /// What kind of job holds the busy flag. Previews may be superseded by a
    /// newer preview or by any other job; everything else is exclusive.
    private enum OperationKind {
        case preview, load, export, batch, save, open, smart, ai
    }

    private struct OperationToken: Equatable {
        let kind: OperationKind
        let id: Int
    }

    /// The job that owns `isBusy`. A completion only clears the flag when its
    /// token is still the active one, so a slow preview can never end an export
    /// that started after it.
    private var activeOperation: OperationToken?
    private var operationCounter = 0
    /// Set when a blocking job stopped a preview in flight, so the canvas is
    /// painted again once that job finishes.
    private var previewInterrupted = false

    /// True while a job other than a preview is running. Menu items and entry
    /// points use this instead of raw `isBusy`, because a preview must not lock
    /// out Save, Export or Undo.
    var isOperationBlocking: Bool {
        guard let activeOperation else { return false }
        return activeOperation.kind != .preview
    }

    /// History edits re-read the photo, so they may replace a preview or an
    /// older re-read but must not cut in front of an export, a batch or a
    /// Smart analysis.
    var isHistoryBlocked: Bool { !canStart(.load) }

    private func canStart(_ kind: OperationKind) -> Bool {
        guard let active = activeOperation else { return true }
        switch active.kind {
        case .preview: return true
        case .load: return kind == .load
        default: return false
        }
    }

    private func begin(_ kind: OperationKind) -> OperationToken? {
        guard canStart(kind) else { return nil }
        if kind != .preview, renderTask != nil {
            renderTask?.cancel()
            renderTask = nil
            previewInterrupted = true
        }
        operationCounter += 1
        let token = OperationToken(kind: kind, id: operationCounter)
        activeOperation = token
        isBusy = true
        return token
    }

    /// The only place that clears `isBusy`. A stale token does nothing, which
    /// is what makes overlapping operations safe.
    private func end(_ token: OperationToken) {
        guard activeOperation == token else { return }
        activeOperation = nil
        isBusy = false
        guard previewInterrupted, token.kind != .preview else { return }
        previewInterrupted = false
        if hasImage { schedulePreview() }
    }

    /// Entry points that must not interrupt a render or a batch. A preview is
    /// not blocking: save and export may start while one is in flight.
    @discardableResult
    private func refuseIfBlocking() -> Bool {
        guard isOperationBlocking else { return false }
        statusToken = .operationBusy
        return true
    }

    // MARK: - Undo / redo

    /// Everything one undo step covers. Stamping the healing brush and reframing
    /// with the crop tool are edits exactly like moving a slider, so all of them
    /// travel through history together. The value lives in `DocumentState.swift`
    /// and the stacks live in `DocumentSession.swift`; the editor keeps the
    /// timer, guards and the work of applying a restored state.
    private var session = DocumentSession()
    private var coalesceTask: Task<Void, Never>?

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var currentState: DocumentState {
        DocumentState(adjustments: adjustments, healSpots: healSpots,
                      stickers: stickers, aiEdits: aiEdits, analysis: analysis,
                      crop: appliedCrop, orientation: documentOrientation,
                      selectedFaceIndex: selectedFaceIndex)
    }

    /// Slider drags fire continuously; recording every tick would make ⌘Z step
    /// through dozens of near-identical states. A short idle window after the
    /// last change collapses one gesture into one undo step.
    private func scheduleCommit() {
        coalesceTask?.cancel()
        coalesceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.commitAdjustments()
        }
    }

    /// Records the current state as an undo step.
    func commitAdjustments() {
        coalesceTask?.cancel()
        coalesceTask = nil
        session.commit(currentState)
        updateUndoFlags()
    }

    func undo() {
        // A newer load may replace an older one, which is what makes two quick
        // undos settle on the last frame instead of the first.
        guard canStart(.load) else {
            statusToken = .operationBusy
            return
        }
        // Flush a change whose debounce is still waiting, so ⌘Z right after a
        // drag undoes that drag instead of skipping past it.
        commitAdjustments()
        guard let previous = session.undo(current: currentState) else { return }
        restore(previous)
        updateUndoFlags()
        refreshStatusAfterHistoryChange()
    }

    func redo() {
        guard canStart(.load) else {
            statusToken = .operationBusy
            return
        }
        // Editing after an undo starts a new branch; the old redo history goes.
        guard currentState == session.lastCommitted else {
            commitAdjustments()
            return
        }
        guard let next = session.redo(current: currentState) else { return }
        restore(next)
        updateUndoFlags()
        refreshStatusAfterHistoryChange()
    }

    /// Assigning both published properties fires their `didSet`, which rebuilds
    /// the masks and repaints the canvas, so history never leaves a stale stamp
    /// on screen. A crop change also has to re-read the pixels, which happens
    /// off the main actor without touching the history stack.
    private func restore(_ state: DocumentState) {
        let cropChanged = state.crop != appliedCrop
        let orientationChanged = state.orientation != documentOrientation
        let selectionChanged = state.selectedFaceIndex != selectedFaceIndex
        adjustments = state.adjustments
        healSpots = state.healSpots
        stickers = state.stickers
        aiEdits = state.aiEdits
        analysis = state.analysis
        applyFaceSelection(state.selectedFaceIndex)
        selectedSticker = nil
        if selectionChanged {
            refreshAnalysisOverlay()
            if hasImage { schedulePreview() }
        }
        updateCleanState()
        guard cropChanged || orientationChanged else { return }
        appliedCrop = state.crop
        documentOrientation = state.orientation
        cropAspect = .free
        cropDraft = CropGeometry.full
        reloadCropped(restoring: true)
    }

    /// The pill used to keep saying "Auto Color & Light applied" after ⌘Z, when
    /// that change no longer existed. Fall back to the neutral face status.
    private func refreshStatusAfterHistoryChange() {
        guard hasImage else { return }
        statusToken = faceCount == 0 ? .noFaceColorOnly : .facesDetected(faceCount)
    }

    private func updateUndoFlags() {
        canUndo = session.canUndo(current: currentState)
        canRedo = session.canRedo(current: currentState)
    }

    private func adjustmentsChanged() {
        scheduleCommit()
        updateUndoFlags()
        updateCleanState()
    }

    private func healSpotsChanged() {
        rebuildSpotMasks()
        guard !isLoadingState else { return }
        scheduleCommit()
        updateUndoFlags()
        updateCleanState()
        if hasImage { schedulePreview() }
    }

    private func stickersChanged() {
        guard !isLoadingState else { return }
        scheduleCommit()
        updateUndoFlags()
        updateCleanState()
        if hasImage { schedulePreview() }
    }

    /// The overlay lives outside the photo pipeline, so a change repaints the
    /// lines only. The picture underneath is untouched by every one of these
    /// switches, which is why they never call `schedulePreview`.
    private func analysisChanged() {
        refreshAnalysisOverlay()
        guard !isLoadingState else { return }
        scheduleCommit()
        updateUndoFlags()
        updateCleanState()
    }

    /// Re-runs the overlay at preview resolution. Called on every settings
    /// change, on a new face set, and after a crop re-load.
    func refreshAnalysisOverlay() {
        guard analysis.isEnabled, hasImage, !faces.isEmpty,
              previewSize.width >= 2, previewSize.height >= 2 else {
            analysisOverlay = nil
            return
        }
        analysisOverlay = AnalysisRenderer.render(size: previewSize, faces: faces,
                                                  settings: analysis, focus: focusFace)
    }

    /// The face the owner picked, or nil for the automatic choice.
    var focusFace: FaceGeometry? {
        guard let selectedFaceIndex, faces.indices.contains(selectedFaceIndex) else { return nil }
        return faces[selectedFaceIndex]
    }

    /// Switches which face drives the callouts, the makeup palette and the
    /// feature sizes. It is part of the document, so it is an undo step and
    /// survives save/reopen.
    func selectFace(_ index: Int?) {
        guard hasImage else { return }
        let target = index.flatMap { faces.indices.contains($0) ? $0 : nil }
        guard target != selectedFaceIndex else { return }
        commitAdjustments()
        applyFaceSelection(target)
        commitAdjustments()
        updateCleanState()
        refreshAnalysisOverlay()
        schedulePreview()
    }

    private func applyFaceSelection(_ index: Int?) {
        selectedFaceIndex = index.flatMap { faces.indices.contains($0) ? $0 : nil }
        if let selectedFaceIndex, faceFamilies.indices.contains(selectedFaceIndex) {
            makeupFamily = faceFamilies[selectedFaceIndex]
        } else {
            makeupFamily = faceFamilies.first ?? .medium
        }
    }

    private func updateCleanState() {
        hasUnsavedChanges = hasImage && currentState != session.cleanState
        scheduleAutosave()
    }

    /// Undo history belongs to one photo. Carrying it across a load would let
    /// ⌘Z overwrite the new image with the previous image's slider values.
    private func resetHistory() {
        coalesceTask?.cancel()
        coalesceTask = nil
        session.reset(to: currentState)
        updateUndoFlags()
        updateCleanState()
    }

    /// Zeroes one effect and records it as a single undo step.
    func resetEffect(_ keyPath: WritableKeyPath<Adjustments, Double>) {
        guard adjustments[keyPath: keyPath] != 0 else { return }
        commitAdjustments()
        adjustments[keyPath: keyPath] = 0
        commitAdjustments()
    }

    /// Zeroes several effects together as one undo step, for a group that is not
    /// one of the five reset groups — the eye and teeth sliders, say.
    func resetEffects(_ keyPaths: [WritableKeyPath<Adjustments, Double>]) {
        guard keyPaths.contains(where: { adjustments[keyPath: $0] != 0 }) else { return }
        commitAdjustments()
        for key in keyPaths { adjustments[keyPath: key] = 0 }
        commitAdjustments()
    }

    /// Zeroes a whole group (skin, reshape, makeup, color/light, look, body or
    /// background) while leaving the other groups exactly as they were.
    func resetGroup(_ group: AdjustmentGroup) {
        guard !adjustments.isIdentity else { return }
        commitAdjustments()
        var next = Adjustments()
        switch group {
        case .skin:
            // Keep everything that is not skin.
            next = next.applyingReshape(adjustments.reshapeOnly)
                       .applyingMakeup(adjustments.makeupOnly)
                       .applyingColorLight(adjustments.colorLightOnly)
                       .applyingLook(adjustments.lookOnly)
                       .applyingBody(adjustments.bodyOnly)
                       .applyingBackground(adjustments.backgroundOnly)
        case .reshape:
            next = next.applyingRetouch(adjustments.retouchOnly)
                       .applyingMakeup(adjustments.makeupOnly)
                       .applyingColorLight(adjustments.colorLightOnly)
                       .applyingLook(adjustments.lookOnly)
                       .applyingBody(adjustments.bodyOnly)
                       .applyingBackground(adjustments.backgroundOnly)
        case .makeup:
            next = next.applyingRetouch(adjustments.retouchOnly)
                       .applyingReshape(adjustments.reshapeOnly)
                       .applyingColorLight(adjustments.colorLightOnly)
                       .applyingLook(adjustments.lookOnly)
                       .applyingBody(adjustments.bodyOnly)
                       .applyingBackground(adjustments.backgroundOnly)
        case .colorLight:
            next = next.applyingRetouch(adjustments.retouchOnly)
                       .applyingReshape(adjustments.reshapeOnly)
                       .applyingMakeup(adjustments.makeupOnly)
                       .applyingLook(adjustments.lookOnly)
                       .applyingBody(adjustments.bodyOnly)
                       .applyingBackground(adjustments.backgroundOnly)
        case .look:
            next = next.applyingRetouch(adjustments.retouchOnly)
                       .applyingReshape(adjustments.reshapeOnly)
                       .applyingColorLight(adjustments.colorLightOnly)
                       .applyingMakeup(adjustments.makeupOnly)
                       .applyingBody(adjustments.bodyOnly)
                       .applyingBackground(adjustments.backgroundOnly)
        case .body:
            next = next.applyingRetouch(adjustments.retouchOnly)
                       .applyingReshape(adjustments.reshapeOnly)
                       .applyingMakeup(adjustments.makeupOnly)
                       .applyingColorLight(adjustments.colorLightOnly)
                       .applyingLook(adjustments.lookOnly)
                       .applyingBackground(adjustments.backgroundOnly)
        case .background:
            next = next.applyingRetouch(adjustments.retouchOnly)
                       .applyingReshape(adjustments.reshapeOnly)
                       .applyingMakeup(adjustments.makeupOnly)
                       .applyingColorLight(adjustments.colorLightOnly)
                       .applyingLook(adjustments.lookOnly)
                       .applyingBody(adjustments.bodyOnly)
        }
        adjustments = next
        commitAdjustments()
    }

    /// Picks a look from the rail. The strength keeps its current value when a
    /// different look is swapped in, so comparing grades stays comparable.
    func setLook(_ look: FilmLook) {
        commitAdjustments()
        adjustments.look = look
        if look == .none {
            adjustments.lookStrength = 0
        } else if adjustments.lookStrength == 0 {
            adjustments.lookStrength = look.defaultStrength
        }
        commitAdjustments()
    }

    /// Picks a makeup colour and switches that region on with it. The already
    /// chosen colour still counts while the amount is zero, since that tap is
    /// the only way to turn the default on; otherwise it would be dead.
    func chooseMakeupShade(_ shade: MakeupShade) {
        let path = shade.region.colorPath
        let amountPath = shade.region.amountPath
        guard adjustments[keyPath: path] != shade.color
                || adjustments[keyPath: amountPath] == 0 else { return }
        commitAdjustments()
        adjustments[keyPath: path] = shade.color
        if adjustments[keyPath: amountPath] == 0 {
            adjustments[keyPath: amountPath] = shade.region.defaultAmount
        }
        commitAdjustments()
    }

    /// A colour from the picker or the hue / saturation sliders. It enables the
    /// region the same way a swatch does, so the change is always visible.
    func setMakeupColor(_ region: MakeupRegion, _ color: MakeupColor) {
        guard adjustments[keyPath: region.colorPath] != color else { return }
        adjustments[keyPath: region.colorPath] = color
        if adjustments[keyPath: region.amountPath] == 0 {
            adjustments[keyPath: region.amountPath] = region.defaultAmount
        }
    }

    func makeupColor(_ region: MakeupRegion) -> MakeupColor {
        adjustments[keyPath: region.colorPath]
    }

    func makeupColorBinding(_ region: MakeupRegion) -> Binding<MakeupColor> {
        Binding(get: { self.makeupColor(region) },
                set: { self.setMakeupColor(region, $0) })
    }

    /// Sliders work in whole units, so hue reads 0...360 and saturation 0...100
    /// while the stored colour keeps full precision.
    func makeupHueBinding(_ region: MakeupRegion) -> Binding<Double> {
        Binding(get: { self.makeupColor(region).hue },
                set: { self.setMakeupColor(region, self.makeupColor(region).with(hue: $0)) })
    }

    func makeupSaturationBinding(_ region: MakeupRegion) -> Binding<Double> {
        Binding(get: { self.makeupColor(region).saturation * 100 },
                set: { self.setMakeupColor(region, self.makeupColor(region).with(saturation: $0 / 100)) })
    }

    /// The HSL tool edits one band at a time; the picker lives in the panel and
    /// the sliders read the arrays through this binding.
    @Published var hslBand: HSLBand = .red

    func hslBinding(_ band: HSLBand,
                    _ component: WritableKeyPath<Adjustments, [Double]>) -> Binding<Double> {
        Binding(
            get: {
                let values = self.adjustments[keyPath: component]
                return band.rawValue < values.count ? values[band.rawValue] : 0
            },
            set: { value in
                var values = self.adjustments[keyPath: component]
                guard band.rawValue < values.count else { return }
                values[band.rawValue] = value
                self.adjustments[keyPath: component] = values
            })
    }

    /// Clears one hue band in all three components as a single undo step.
    func resetHSLBand(_ band: HSLBand) {
        let index = band.rawValue
        guard adjustments.hslHue[index] != 0
                || adjustments.hslSaturation[index] != 0
                || adjustments.hslLuminance[index] != 0 else { return }
        commitAdjustments()
        adjustments.hslHue[index] = 0
        adjustments.hslSaturation[index] = 0
        adjustments.hslLuminance[index] = 0
        commitAdjustments()
    }

    /// UI copy. The app speaks English or Persian, and the table follows the
    /// language the owner picked.
    var s: L10n {
        language == .persian ? PersianL10n.table : L10n.shared
    }
    @Published private(set) var previewSize = CGSize(width: 1, height: 1)

    // Canvas view state. zoom == 1 means the image is fitted to the window.
    @Published var zoom: Double = 1
    @Published var panOffset: CGSize = .zero
    @Published private(set) var canvasSize: CGSize = .zero
    @Published var toolMode: ToolMode = .skin

    // Makeup panel state. The family is what the photo's own skin measured,
    // until the owner picks another one — the palette should open on the
    // colours mixed for this face, not on a fixed default.
    @Published var makeupRegion: MakeupRegion = .lips
    @Published var makeupFamily: MakeupFamily = .medium

    private let processor = ImageProcessor.shared
    private let previewMaxDimension: CGFloat = 1800

    /// Restores the neutral status shown when no image is open.
    func refreshDefaultStatus() {
        if !hasImage { statusToken = .dropHint }
    }

    private var sourceFull: CIImage?
    private var sourcePreview: CIImage?
    /// The on-screen set only. Exports build their own set at export
    /// resolution and release it, so a document never keeps both.
    private var masksPreview: MaskSet?
    private var spotsPreview: SpotHealing?
    /// True while a load installs the stamps that came with the project, so the
    /// stamp `didSet` does not treat restored state as a new user edit.
    private var isLoadingState = false
    private var sourceColorSpace: CGColorSpace?
    private var sourceMetadata: [CFString: Any] = [:]
    private var renderTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var exportJob: Task<ExportService.Outcome, Never>?
    private var thumbTask: Task<Void, Never>?
    private var batchTask: Task<Void, Never>?
    /// The file the batch is writing right now. A detached task does not
    /// inherit the outer task's cancellation, so this reference is what lets
    /// `cancelBatchExport` reach the photo in flight.
    private var batchFileTask: Task<BatchOutcome, Never>?
    private var batchSources: [URL] = []
    private var batchFolder: URL?
    private var autosaveTask: Task<Void, Never>?
    private var recentsObserver: AnyCancellable?
    private var smartGeneration = 0
    private var offeredRecovery = false
    /// Set once the launch slots have been lifted into candidates. Every
    /// document-entry path checks it before it may touch the working copy, so
    /// an external open that arrives before the launch prompt cannot replace
    /// the previous session's only copy.
    private var recoveryPrepared = false
    /// A document restored from a recovery candidate stays here until the
    /// owner saves it as a project. Its only durable copy is the working slot,
    /// so autosave must not clear that slot just because no slider differs from
    /// the baseline.
    private var documentRecovered = false
    /// Candidates already acted on in this launch, including copies preserved
    /// while another candidate was restored. Keeps one pass from re-offering
    /// work it deliberately set aside.
    private var handledRecovery: Set<URL> = []

    /// The candidate a load is restoring. Carried through the asynchronous load
    /// so the candidate is deleted only after the restored document is proven
    /// to be in the working slot.
    struct RecoveryRestore {
        let candidateURL: URL
    }

    /// Headless tests replace the two recovery panels; production leaves these
    /// nil and the methods below use AppKit.
    var recoveryChoiceHandler: ((Bool, String?) -> RecoveryChoice)?
    var recoveryLocateHandler: ((RetouchProject) -> URL?)?
    /// Headless tests answer the unsaved-changes prompt without AppKit.
    /// Production leaves this nil.
    var discardChoiceHandler: (() -> Bool)?
    /// Headless tests shorten the autosave debounce so they can exercise the
    /// scheduled task without a real-time wait.
    var autosaveDebounceNanoseconds: UInt64 = 1_500_000_000
    /// Runs after the debounce and before the write decision, so a test can
    /// invalidate a task that has already started. Production leaves it nil.
    var autosaveWillWrite: (() -> Void)?
    /// Headless tests pause the file here to deliver a cancellation exactly
    /// before the write. Production leaves this nil.
    var batchFileWillWriteHook: (@Sendable (URL) -> Void)?
    /// Headless tests force the write stage's result. `nil` uses the real
    /// atomic writer; production leaves the property itself nil.
    var batchFileWriteResultOverride: (@Sendable (URL) -> Bool?)?
    /// Project file to rewrite once a relocated photo finishes loading.
    private var pendingRelink: URL?
    private var batchGeneration = 0
    private var generation = 0
    /// Invalidates an in-flight segmentation when the photo or crop changes.
    private var personGeneration = 0

    init() {
        // Defaults come from the saved preferences, so a restart opens with the
        // strengths and export choices the owner left behind.
        autoRetouchStrength = settings.autoRetouchStrength
        autoColorStrength = settings.autoColorStrength
        exportFormat = ExportFormat(rawValue: settings.exportFormat) ?? .jpeg
        exportQuality = settings.exportQuality
        exportLongEdge = settings.exportLongEdge
        exportAIUpscale = settings.exportAIUpscale
        stripLocationMetadata = settings.stripLocationMetadata
        watermark = settings.watermark
        healBrushPercent = settings.healBrushPercent
        showFaceOverlay = settings.showFaceOverlay
        comparePosition = settings.comparePosition

        // The Open Recent menu is built from this model's body, so a change in
        // the list has to reach the scene as well.
        recentsObserver = recents.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }

    // MARK: - Input

    func openImage() {
        guard !refuseIfBlocking() else { return }
        // Ask before the picker. Asking after it put a modal alert on top of the
        // window the panel had just left, which read as a jump and threw the
        // chosen file away if the owner backed out.
        guard confirmDiscardIfNeeded() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = s.choosePhotoToRetouch
        present(panel) { [weak self] url in
            guard let self, self.prepareToReplaceDocument() else { return }
            self.load(url: url)
        }
    }

    /// A user-confirmed open replaces the document, so the autosave copy of the
    /// old one may be discarded. Candidate copies are never touched here.
    ///
    /// Promotion runs before anything is removed: at launch the working slot may
    /// still hold the previous session's only copy. When it cannot be promoted
    /// the slot stays locked, and `false` tells the caller to keep the current
    /// document instead of replacing it.
    @discardableResult
    private func prepareToReplaceDocument() -> Bool {
        guard ensureRecoveryPrepared() else { return false }
        invalidatePendingAutosave()
        _ = RecoveryStore.removeWorking()
        documentRecovered = false
        return true
    }

    /// Attaches the picker to the editor window so it slides in as a sheet
    /// instead of appearing as a separate app-modal window in the middle of the
    /// screen. A window that already carries a sheet (the export panel, for
    /// example) falls back to the modal loop.
    private func present(_ panel: NSOpenPanel, then action: @escaping (URL) -> Void) {
        let window = NSApp.windows.first { $0.identifier?.rawValue == "editor" }
        guard let window, window.attachedSheet == nil else {
            guard panel.runModal() == .OK, let url = panel.url else { return }
            action(url)
            return
        }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            action(url)
        }
    }

    /// Entry point for drag-and-drop and for Finder / Open With.
    func requestLoad(url: URL) {
        guard !refuseIfBlocking() else { return }
        // Choosing a photo answers the launch question, but only after the
        // previous session's working copy has been lifted into a candidate.
        // Otherwise the incoming document's autosave would overwrite the only
        // recoverable copy before the launch pass ever ran.
        guard ensureRecoveryPrepared() else { return }
        offeredRecovery = true
        guard confirmDiscardIfNeeded() else { return }
        guard prepareToReplaceDocument() else { return }
        load(url: url)
    }

    /// Finder can send either a photo or a project; route by extension.
    func requestOpen(url: URL) {
        if url.pathExtension.lowercased() == RetouchProject.fileExtension {
            openProject(at: url)
        } else {
            requestLoad(url: url)
        }
    }

    /// True when it is safe to replace the current photo.
    func confirmDiscardIfNeeded() -> Bool {
        guard hasUnsavedChanges else { return true }
        if let discardChoiceHandler { return discardChoiceHandler() }
        let alert = NSAlert()
        alert.messageText = s.unsavedTitle
        alert.informativeText = s.unsavedMessage
        alert.alertStyle = .warning
        // Save first, the way a document window behaves: a detour through the
        // save panel must not cost the edits either.
        let save = alert.addButton(withTitle: s.saveBeforeClosing)
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command
        let discard = alert.addButton(withTitle: s.discardChanges)
        discard.hasDestructiveAction = true
        // The first button inherits Return as its key equivalent; clear it so
        // only Cancel below answers Return.
        discard.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: s.cancel)
        // Cancel is the default: Return must never throw away edits.
        cancel.keyEquivalent = "\r"
        // AppKit does not wire Esc to the cancel button for programmatic
        // alerts, so dismiss the modal ourselves.
        let escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            NSApp.stopModal(withCode: .abort)
            return nil
        }
        let response = alert.runModal()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if response == .abort { alert.window.orderOut(nil) }
        if response == .alertFirstButtonReturn {
            saveProject()
            // A cancelled save panel leaves the document dirty, so the close
            // or load that asked stays cancelled rather than dropping the work.
            return !hasUnsavedChanges
        }
        return response == .alertSecondButtonReturn
    }

    /// The user confirmed they are done with these adjustments, so the current
    /// values become the clean baseline. Without this, closing the window would
    /// ask again during the termination that follows.
    func discardUnsavedChanges() {
        // A task already past its sleep must not recreate the copy this
        // discard is about to remove.
        invalidatePendingAutosave()
        session.markClean(currentState)
        // The owner explicitly ended this document. Its autosave copy goes with
        // it; candidate copies waiting for their own decision stay.
        documentRecovered = false
        _ = RecoveryStore.removeWorking()
        updateCleanState()
    }

    func load(url: URL, restoring project: RetouchProject? = nil,
              projectURL: URL? = nil, relinkURL: URL? = nil,
              recoveryRestore: RecoveryRestore? = nil) {
        // A newer load wins over an older one, but no load may cut in front of
        // an export, a batch or a Smart analysis.
        guard let token = begin(.load) else {
            statusToken = .operationBusy
            return
        }
        loadTask?.cancel()
        pendingRelink = relinkURL
        batchGeneration += 1
        batchTask?.cancel()
        batchFileTask?.cancel()
        batchFileTask = nil
        batchTask = nil
        isBatchRunning = false
        showBatchSheet = false
        generation += 1
        let generation = self.generation

        statusToken = .readingImage

        let processor = self.processor
        let previewMaxDimension = self.previewMaxDimension
        let crop = project?.crop
        let orientation = project?.orientation ?? .identity

        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                processor.load(from: url, previewMaxDimension: previewMaxDimension,
                               crop: crop, orientation: orientation)
            }.value

            guard let self, self.generation == generation else { return }
            guard let result else {
                // The previous document is still on screen: do not let a failed
                // open rename it or leave a project rewrite queued for it.
                self.pendingRelink = nil
                self.end(token)
                self.statusToken = .couldNotRead
                return
            }
            self.apply(result, restoring: project, projectURL: projectURL,
                       recoveryRestore: recoveryRestore)
            self.end(token)
            if !self.healSpots.isEmpty || !self.stickers.isEmpty { self.schedulePreview() }
        }
    }

    /// Updates everything the pipeline needs for a new set of pixels, without
    /// touching adjustments, history or clean baselines. Both a fresh load and
    /// a crop re-load go through here.
    private func install(_ result: LoadResult) {
        sourceFull = result.sourceFull
        sourcePreview = result.sourcePreview
        masksPreview = result.masksPreview
        sourceColorSpace = result.colorSpace
        sourceMetadata = result.metadata
        faces = result.faces
        faceCount = result.faces.count
        // Each accepted face gets its own palette, so switching the selection
        // switches the makeup family to that face's measured skin.
        faceFamilies = result.faces.map { face in
            AutoAnalyzer.cheekLuminance(result.originalPreview, face: face)
                .map(MakeupFamily.of(skinLuminance:)) ?? .medium
        }
        applyFaceSelection(nil)
        // A new set of pixels means the old silhouette no longer describes it.
        personGeneration += 1
        subjectState = .unknown
        hasBodyPose = false
        originalImage = NSImage(cgImage: result.originalPreview,
                               size: NSSize(width: result.originalPreview.width, height: result.originalPreview.height))
        previewImage = NSImage(cgImage: result.preview,
                              size: NSSize(width: result.preview.width, height: result.preview.height))
        previewSize = CGSize(width: result.preview.width, height: result.preview.height)
        workingPixelSize = result.pixelSize
        sourcePixelSize = result.sourcePixelSize
        imageName = result.fileName
        imageURL = result.url
        cropDraft = CropGeometry.full
        hasImage = true
        isPeekingOriginal = false
        // A point marked against different pixels means nothing here.
        quickEditPoint = nil
        isAIPicking = false
        quickEditStage = .idle
        quickEditPrompt = ""
        clearAIMaskContents()
        aiMaskMessage = nil
        buildPresetThumbs()
        refreshAnalysisOverlay()
    }

    private func apply(_ result: LoadResult,
                       restoring project: RetouchProject? = nil,
                       projectURL: URL? = nil,
                       recoveryRestore: RecoveryRestore? = nil) {
        // Loading is not an edit. Every assignment below, including the ones
        // whose observers would schedule an autosave, stays out of the
        // recovery store until the restored document is complete.
        isLoadingState = true
        install(result)
        self.projectURL = projectURL

        if let project {
            exportFormat = ExportFormat(rawValue: project.exportFormat) ?? .jpeg
            exportQuality = project.exportQuality
            exportLongEdge = project.exportLongEdge ?? 0
            autoRetouchStrength = project.autoRetouchStrength
            autoColorStrength = project.autoColorStrength ?? 100
            adjustments = project.adjustments
            appliedCrop = project.crop
            documentOrientation = project.orientation ?? .identity
        } else {
            adjustments = .zero
            appliedCrop = nil
            documentOrientation = .identity
        }
        // The stamps arrive with the project, so they are installed without the
        // change handling a user stamp needs.
        healSpots = project?.healSpots ?? []
        stickers = project?.stickers ?? []
        aiEdits = project?.aiEdits ?? []
        analysis = project?.analysis ?? AnalysisSettings()
        applyFaceSelection(project?.selectedFace)
        selectedSticker = nil
        rebuildSpotMasks()
        refreshAnalysisOverlay()

        cropAspect = .free
        session.markClean(currentState)
        comparePosition = settings.comparePosition
        resetHistory()
        documentRecovered = recoveryRestore != nil
        if recoveryRestore != nil {
            // Until the working slot is written below, a crash copy lives
            // nowhere else. It counts as unsaved so closing warns and the
            // recovery data stays.
            session.markClean(DocumentState())
            hasUnsavedChanges = hasImage && currentState != DocumentState()
        }
        isLoadingState = false
        resetView()
        // The report belongs to the photo that was just replaced.
        smartGeneration += 1
        smartReport = nil
        isAnalyzingSmart = false
        showSmartSheet = false
        if let projectURL {
            recents.add(projectURL, isProject: true)
        } else {
            recents.add(result.url, isProject: false)
        }
        if project != nil {
            statusToken = .projectOpened
        } else if result.faces.isEmpty {
            statusToken = .noFaceColorOnly
        } else {
            statusToken = .facesDetected(result.faces.count)
        }
        // A project whose patch files were removed from the store must say so:
        // silently dropping an edit would change the picture without asking.
        let missingEdits = AICompositor.missing(aiEdits).count
        if missingEdits > 0 { statusToken = .aiAssetsMissing(missingEdits) }

        // The photo was found somewhere other than the recorded path. Rewrite
        // the project once, so the next open resolves straight to it.
        if let relinkURL = pendingRelink {
            pendingRelink = nil
            rewriteProject(at: relinkURL)
            if project != nil { statusToken = .projectRelinked }
        }
        if let recoveryRestore {
            finishRestore(recoveryRestore)
        }
    }

    // MARK: - Crop

    /// Pixel aspect ratio of the working image, width ÷ height.
    var workingAspect: CGFloat {
        guard workingPixelSize.width > 0, workingPixelSize.height > 0 else { return 1 }
        return workingPixelSize.width / workingPixelSize.height
    }

    /// Pixel aspect ratio of the whole photo. Sticker sizes are stored against
    /// the photo's short side, while the canvas works in the cropped frame.
    var sourceAspect: CGFloat {
        guard let crop = appliedCrop, crop.width > 0, crop.height > 0 else { return workingAspect }
        guard workingPixelSize.width > 0, workingPixelSize.height > 0 else { return 1 }
        return (workingPixelSize.width / crop.width) / (workingPixelSize.height / crop.height)
    }

    /// Pixel size of the draft crop, for the live readout.
    var cropDraftPixelSize: CGSize {
        CGSize(width: (cropDraft.width * workingPixelSize.width).rounded(),
               height: (cropDraft.height * workingPixelSize.height).rounded())
    }

    var cropDraftIsFull: Bool { CropGeometry.isFull(cropDraft) }
    var canApplyCrop: Bool { hasImage && !isBusy && !cropDraftIsFull }
    var canResetCrop: Bool { hasImage && !isBusy && (appliedCrop != nil || !cropDraftIsFull) }

    /// Fresh draft and a fitted view whenever the crop tool opens.
    func beginCrop() {
        cropDraft = CropGeometry.full
        cropAspect = .free
        resetView()
    }

    func setCropAspect(_ aspect: CropAspect) {
        cropAspect = aspect
        guard let target = aspect.ratio(originalAspect: workingAspect) else { return }
        // Fit the new shape inside the current draft, so changing the aspect
        // never jumps the crop to an unrelated part of the photo.
        cropDraft = CropGeometry.aspectFit(target, imageAspect: workingAspect, in: cropDraft)
    }

    func applyCrop() {
        guard hasImage, !isBusy else { return }
        let composed = CropGeometry.clamped(CropGeometry.composed(cropDraft, over: appliedCrop))
        let target: CGRect? = CropGeometry.isFull(composed) ? nil : composed
        guard target != appliedCrop else { return }
        // A pending slider drag is its own step; the framing change is another,
        // so ⌘Z gives the previous frame back without also undoing the drag.
        commitAdjustments()
        appliedCrop = target
        // Leader ends were pinned against the old frame; the face has moved, so
        // they go back to the automatic layout as part of the same step.
        if !analysis.endpoints.isEmpty { analysis.resetEndpoints() }
        commitAdjustments()
        updateCleanState()
        reloadCropped(restoring: false)
    }

    func resetCrop() {
        guard hasImage, !isBusy, appliedCrop != nil || !cropDraftIsFull else { return }
        commitAdjustments()
        appliedCrop = nil
        cropAspect = .free
        cropDraft = CropGeometry.full
        if !analysis.endpoints.isEmpty { analysis.resetEndpoints() }
        commitAdjustments()
        updateCleanState()
        reloadCropped(restoring: false)
    }

    // MARK: - Orientation

    var straightenAngle: Double { documentOrientation.angle }
    var canOrient: Bool { hasImage && !isBusy }

    func rotateClockwise() {
        applyOrientation(documentOrientation.rotatedClockwise(), status: .rotated)
    }

    func rotateCounterClockwise() {
        applyOrientation(documentOrientation.rotatedCounterClockwise(), status: .rotated)
    }

    func flipHorizontally() {
        applyOrientation(documentOrientation.flippedHorizontally(), status: .flipped)
    }

    func setStraightenAngle(_ degrees: Double) {
        let clamped = min(DocumentOrientation.maxStraighten,
                          max(-DocumentOrientation.maxStraighten, degrees))
        applyOrientation(documentOrientation.straightened(to: clamped), status: .straightened)
    }

    /// Bakes a new orientation into the pixels and rewrites every stored edit
    /// from the old frame into the new one. The turn is one undo step: history
    /// keeps the coordinates and the orientation together, so undoing it needs
    /// no second mapping.
    private func applyOrientation(_ target: DocumentOrientation, status: StatusToken) {
        guard hasImage, !isBusy, target != documentOrientation else { return }
        let base = sourcePixelSize
        guard base.width >= 1, base.height >= 1 else { return }
        let delta = DocumentOrientation.compose(target, over: documentOrientation.inverted)
        commitAdjustments()

        isLoadingState = true
        if let crop = appliedCrop {
            // The crop window belongs to the frame, not to the pixels: a
            // straighten turns the photo under it the way every editor does.
            // Quarter turns and flips move it exactly, so only the angle is
            // left out of this mapping.
            let window = DocumentOrientation(quarterTurns: delta.quarterTurns,
                                             flipped: delta.flipped)
            let mapped = CropGeometry.clamped(window.mapRect(crop, base: base))
            appliedCrop = CropGeometry.isFull(mapped) ? nil : mapped
        }
        healSpots = healSpots.map {
            HealSpot(center: delta.mapPoint($0.center, base: base),
                     radius: delta.mapShortSideFraction($0.radius, base: base))
        }
        stickers = stickers.map { sticker in
            var mapped = sticker
            mapped.center = delta.mapPoint(sticker.center, base: base)
            mapped.size = Double(delta.mapShortSideFraction(CGFloat(sticker.size), base: base))
            return mapped
        }
        aiEdits = aiEdits.map { edit in
            var mapped = edit
            mapped.box = delta.mapRect(edit.box, base: base)
            mapped.patchOrientation = DocumentOrientation.compose(
                delta, over: edit.patchOrientation ?? .identity)
            return mapped
        }
        // Leader ends were pinned against the old frame; the automatic layout
        // re-flows onto the turned face as part of the same step.
        if !analysis.endpoints.isEmpty { analysis.resetEndpoints() }
        if !analysis.anchors.isEmpty { analysis.resetAnchors() }
        documentOrientation = target
        cropAspect = .free
        cropDraft = CropGeometry.full
        isLoadingState = false

        commitAdjustments()
        updateCleanState()
        reloadCropped(restoring: false, status: status)
    }

    /// Re-reads the source with the current crop and orientation, and rebuilds
    /// masks and previews. History is never touched here: a crop or a turn is
    /// already an undo step, and an undo that changes it calls back in with
    /// `restoring` so the restored analysis pins survive the re-load.
    /// `generation` makes a slow reload from an older undo lose to the newer one.
    private func reloadCropped(restoring: Bool, status: StatusToken? = nil) {
        guard let imageURL else { return }
        guard let token = begin(.load) else {
            statusToken = .operationBusy
            return
        }
        loadTask?.cancel()
        generation += 1
        let generation = self.generation
        let crop = appliedCrop
        let orientation = documentOrientation
        let selection = selectedFaceIndex
        let processor = self.processor
        let previewMaxDimension = self.previewMaxDimension
        let url = imageURL

        statusToken = .applyingCrop

        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                processor.load(from: url, previewMaxDimension: previewMaxDimension,
                               crop: crop, orientation: orientation)
            }.value

            guard let self, self.generation == generation else { return }
            guard let result else {
                self.end(token)
                self.statusToken = .couldNotRead
                return
            }
            self.install(result)
            // The faces are the same people under a smaller frame: cropping
            // must not silently drop back to the automatic face.
            self.applyFaceSelection(selection)
            self.refreshAnalysisOverlay()
            // The stamps live in original-photo coordinates, so a new crop moves
            // them onto the new frame before the canvas repaints.
            self.rebuildSpotMasks()
            self.updateCleanState()
            self.end(token)
            let hasEdits = self.adjustments != .zero || selection != nil
                || !self.healSpots.isEmpty || !self.stickers.isEmpty || !self.aiEdits.isEmpty
            if hasEdits { self.schedulePreview() }
            if !restoring {
                self.statusToken = status ?? (crop == nil ? .cropReset : .cropApplied)
            }
        }
    }

    /// True when the active tool owns the pointer over the canvas, so pan,
    /// zoom and the compare handle must stand aside.
    var toolOwnsCanvas: Bool {
        toolMode == .crop || toolMode == .heal || toolMode == .art
            || toolMode == .analysis || isAIPicking
    }

    /// When the app last became active. The click that brings the window
    /// forward still reaches the canvas, so tools that place something on a
    /// click ignore pointer edits for a moment after it.
    private var lastActivation = Date.distantPast

    func noteActivation() {
        lastActivation = Date()
    }

    /// The key-up that ends a Space peek never arrives when the app loses focus,
    /// so the peek is cleared from the activation notification as well.
    func endPeek() {
        isPeekingOriginal = false
    }

    /// Picks a tool from a bare key. The number row covers the first ten and
    /// the two keys beside it reach art and analysis.
    @discardableResult
    func selectTool(shortcut key: String) -> Bool {
        let numbers: [String: Int] = [
            "1": 1, "2": 2, "3": 3, "4": 4, "5": 5,
            "6": 6, "7": 7, "8": 8, "9": 9, "0": 10,
            "-": 11, "−": 11, "=": 12, "+": 12,
            "۱": 1, "۲": 2, "۳": 3, "۴": 4, "۵": 5,
            "۶": 6, "۷": 7, "۸": 8, "۹": 9, "۰": 10,
        ]
        guard let number = numbers[key], number <= ToolMode.allCases.count else { return false }
        toolMode = ToolMode.allCases[number - 1]
        return true
    }

    /// `[` and `]` move the healing brush by one size step, inside the same
    /// limits as the slider.
    func nudgeHealBrush(by delta: Double) {
        healBrushPercent = min(6, max(0.4, healBrushPercent + delta))
    }

    var acceptsPointerEdit: Bool {
        Date().timeIntervalSince(lastActivation) > 0.3
    }

    // MARK: - Healing brush

    /// Brush radius as a fraction of the working image's short side. Storing the
    /// size this way makes one brush behave identically on preview and export.
    var healBrushRadius: CGFloat { CGFloat(max(0.2, healBrushPercent) / 200) }

    /// Brush diameter in working pixels, for the readout beside the slider.
    var healBrushPixels: Int {
        let short = min(workingPixelSize.width, workingPixelSize.height)
        return Int((healBrushRadius * 2 * short).rounded())
    }

    var canClearHealSpots: Bool { hasImage && !healSpots.isEmpty }

    /// Stamps as the canvas sees them, with the index into `healSpots` so a
    /// click can remove the stamp it landed on.
    var visibleHealSpots: [(index: Int, spot: HealSpot)] {
        HealGeometry.indexed(healSpots, crop: appliedCrop)
    }

    /// One click does two jobs, the way a spot tool in a retouch app reads:
    /// inside an existing stamp it takes that stamp back, anywhere else it
    /// places a new one.
    func tapHeal(at point: CGPoint) {
        guard hasImage else { return }
        let clamped = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
        let visible = visibleHealSpots
        if let hit = visible.first(where: {
            HealGeometry.shortSideDistance($0.spot.center, clamped, aspect: workingAspect)
                <= $0.spot.radius
        }) {
            healSpots.remove(at: hit.index)
            statusToken = healSpots.isEmpty ? .healCleared : .healStampRemoved
            return
        }
        let center = HealGeometry.originalCenter(clamped, crop: appliedCrop)
        let radius = HealGeometry.originalRadius(healBrushRadius, crop: appliedCrop)
        healSpots.append(HealSpot(center: center, radius: radius))
        statusToken = .healStampAdded(healSpots.count)
    }

    func clearHealSpots() {
        guard !healSpots.isEmpty else { return }
        healSpots.removeAll()
        statusToken = .healCleared
    }

    /// Rebuilds the healing masks at preview resolution. The export builds its
    /// own masks at full resolution inside `ExportService`, so a stamp edit no
    /// longer pays for a full-size render it may never use.
    private func rebuildSpotMasks() {
        let working = HealGeometry.workingSpots(healSpots, crop: appliedCrop)
        spotsPreview = sourcePreview.flatMap { processor.spotsMask(extent: $0.extent, spots: working) }
    }

    // MARK: - AI edits

    var hasAIEdits: Bool { !aiEdits.isEmpty }
    var canRemoveAIEdit: Bool { !aiEdits.isEmpty && !isOperationBlocking }
    var aiMaskSelection: AIMaskSelection {
        AIMaskSelection(strokes: aiMaskStrokes, box: aiMaskBox,
                        refined: aiMaskRefined, inverted: aiMaskInverted)
    }
    var aiMaskHasSelection: Bool { aiMaskSelection.hasContent }
    var canRunQuickEdit: Bool {
        hasImage && !isRunningQuickEdit && !isOperationBlocking && !isRefiningMask
            && (quickEditPreset.isFullFrame
                || aiMaskHasSelection
                || (quickEditPoint != nil && quickEditPreset != .healArea))
    }

    /// Starts picking: the canvas takes the pointer and the next click marks
    /// what the preset should act on.
    func beginQuickEdit() {
        guard hasImage, !isOperationBlocking else {
            statusToken = .operationBusy
            return
        }
        quickEditPoint = nil
        clearAIMaskContents()
        aiMaskMessage = nil
        quickEditStage = .idle
        isAIPicking = true
    }

    func cancelQuickEditPicking() {
        isAIPicking = false
    }

    func selectAIMaskTool(_ tool: AIMaskTool) {
        guard hasImage, !isRunningQuickEdit, !isOperationBlocking else { return }
        aiMaskTool = tool
        aiMaskMessage = nil
        if tool != .point { quickEditPoint = nil }
        isAIPicking = true
    }

    func selectQuickEditPreset(_ preset: AIQuickPreset) {
        guard !isRunningQuickEdit else { return }
        quickEditPreset = preset
        if preset.isFullFrame {
            // Reimagine redraws the frame; a leftover mask would only confuse
            // the overlay, so the canvas goes back to a plain photo.
            quickEditPoint = nil
            clearAIMaskContents()
            isAIPicking = false
        } else if preset == .healArea {
            quickEditPoint = nil
            if aiMaskTool == .point { aiMaskTool = .brush }
        }
    }

    func placeQuickEditPoint(_ point: CGPoint) {
        guard isAIPicking, !isRunningQuickEdit else { return }
        clearAIMaskContents()
        quickEditPoint = CGPoint(x: min(1, max(0, point.x)),
                                 y: min(1, max(0, point.y)))
        // The point is placed: give the canvas back so the owner can pan and
        // compare before deciding to run the edit.
        isAIPicking = false
    }

    // MARK: - Mask selection

    func appendMaskStroke(_ stroke: AIMaskStroke) {
        guard !isRunningQuickEdit else { return }
        quickEditPoint = nil
        aiMaskMessage = nil
        aiMaskStrokes.append(stroke)
        refreshAIMaskPreview()
    }

    func setMaskBox(_ box: CGRect) {
        guard !isRunningQuickEdit else { return }
        quickEditPoint = nil
        aiMaskMessage = nil
        aiMaskRefined = nil
        aiMaskBox = box
        refreshAIMaskPreview()
    }

    /// The box is the starting point; SAM turns it into an edge-following mask
    /// on the same local helper. A failure leaves the box usable.
    func refineMaskWithSAM() {
        guard let box = aiMaskBox, !isRefiningMask, !isRunningQuickEdit,
              let source = originalImage?.cgImage(forProposedRect: nil,
                                                  context: nil, hints: nil),
              let token = begin(.ai) else { return }
        isRefiningMask = true
        aiMaskMessage = nil
        maskTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<CGImage, Error> in
                do { return .success(try QuickEditRunner.samMask(image: source, box: box)) }
                catch { return .failure(error) }
            }.value
            guard let self else { return }
            self.maskTask = nil
            self.isRefiningMask = false
            switch outcome {
            case .success(let mask):
                self.aiMaskRefined = mask
                self.refreshAIMaskPreview()
            case .failure(let error):
                self.aiMaskMessage = self.localizedAIFailure(error)
            }
            self.end(token)
        }
    }

    func clearAIMask() {
        guard !isRunningQuickEdit else { return }
        clearAIMaskContents()
        aiMaskMessage = nil
        isAIPicking = false
    }

    func clearQuickEditSelection() {
        guard !isRunningQuickEdit else { return }
        quickEditPoint = nil
        clearAIMaskContents()
        aiMaskMessage = nil
        isAIPicking = false
    }

    private func clearAIMaskContents() {
        aiMaskStrokes = []
        aiMaskBox = nil
        aiMaskRefined = nil
        refreshAIMaskPreview()
    }

    private func refreshAIMaskPreview() {
        guard aiMaskHasSelection, previewSize.width >= 2, previewSize.height >= 2 else {
            aiMaskPreview = nil
            return
        }
        let selection = aiMaskSelection
        aiMaskPreview = AIMaskRenderer.mask(
            size: previewSize, strokes: selection.strokes, box: selection.box,
            refined: selection.refined, inverted: selection.inverted)
            .flatMap(AIMaskRenderer.alphaMask)
    }

    /// Worker errors that mean "the machine is not set up" get a sentence the
    /// owner can act on instead of the helper's internal wording.
    private func localizedAIFailure(_ error: Error) -> String {
        switch (error as? AIWorkerFailure)?.code {
        case -32011: return L10n.current.aiModelMissing
        case -32010: return L10n.current.aiLicenseBlocked
        case -32602: return L10n.current.aiMaskTooLarge
        default: return error.localizedDescription
        }
    }

    /// Runs the selected preset against the working photo. The helper gets a
    /// copy; its reply is stored as two files and enters history as one step,
    /// so a long generation cannot leave a half-edit in the document.
    func runQuickEdit() {
        guard canRunQuickEdit,
              let source = originalImage?.cgImage(forProposedRect: nil,
                                                  context: nil, hints: nil),
              let token = begin(.ai) else { return }
        let point = quickEditPoint
        let mask = aiMaskSelection
        isAIPicking = false
        isRunningQuickEdit = true
        quickEditCancelRequested = false
        quickEditStage = .preparing
        statusToken = .aiWorking

        let crop = appliedCrop
        let preset = quickEditPreset
        let fullFrame = preset.isFullFrame
        // Only Reimagine takes the owner's words. The masked presets keep
        // their own instruction so an old prompt cannot change their meaning.
        let custom = quickEditPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = fullFrame && !custom.isEmpty ? custom : preset.prompt
        let seed = Int.random(in: 1...Int(Int32.max))
        let dilate = Int(aiMaskExpand.rounded())
        let feather = Int(aiMaskFeather.rounded())

        aiTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<AIEdit, Error> in
                do {
                    return .success(try QuickEditRunner.run(
                        image: source, point: point, mask: mask, crop: crop,
                        preset: preset, prompt: prompt, seed: seed,
                        fullFrame: fullFrame,
                        dilate: dilate, feather: feather,
                        onJob: { id in
                            Task { @MainActor in
                                self?.aiJobID = id
                                if self?.quickEditCancelRequested == true {
                                    WorkerClient.shared.cancel(job: id)
                                }
                            }
                        },
                        progress: { step in
                            Task { @MainActor in
                                self?.quickEditStage = .denoising(step: step)
                            }
                        }))
                } catch {
                    return .failure(error)
                }
            }.value

            guard let self else { return }
            self.aiTask = nil
            self.aiJobID = nil
            self.isRunningQuickEdit = false
            switch outcome {
            case .success(let edit):
                self.quickEditStage = .finished(seconds: edit.seconds)
                self.quickEditPoint = nil
                self.clearAIMaskContents()
                self.addAIEdit(edit)
            case .failure(let error):
                // The card carries the reason, so the status line must not
                // keep claiming the helper is still generating.
                self.statusToken = .none
                if (error as? AIWorkerFailure)?.code == -32014 {
                    self.quickEditStage = .idle
                } else {
                    self.quickEditStage = .failed(self.localizedAIFailure(error))
                }
            }
            self.end(token)
            // The edit landed while `.ai` still owned the pipeline, so the
            // preview requested by `aiEdits` was refused. Paint it now.
            if case .success = outcome { self.schedulePreview() }
        }
    }

    /// Stops the running job at its next denoise step. The helper acknowledges
    /// at once, so the button never appears stuck.
    func cancelQuickEdit() {
        guard isRunningQuickEdit else { return }
        quickEditCancelRequested = true
        if let id = aiJobID { WorkerClient.shared.cancel(job: id) }
    }

    /// Removes the most recent edit. Undo can bring it back, so the files stay
    /// on disk until the edit store is pruned.
    func removeLastAIEdit() {
        guard canRemoveAIEdit else { return }
        commitAdjustments()
        aiEdits.removeLast()
        quickEditStage = .idle
        updateUndoFlags()
    }

    /// Records an edit whose pixels are already in the store. One history step
    /// covers it exactly as it was before and after, so the slider debounce
    /// cannot fold the edit into an earlier slider drag.
    func addAIEdit(_ edit: AIEdit) {
        commitAdjustments()
        aiEdits.append(edit)
        statusToken = .aiApplied
        // The append happens after the commit above, so the toolbar needs an
        // explicit refresh or it offers no undo for the edit it just added.
        updateUndoFlags()
    }

    // MARK: - Art (stickers)

    /// Art tool state for the next sticker, and for the selected one.
    @Published var stickerKind: StickerKind = .star
    @Published var stickerSize: Double = Sticker.defaultSize * 100   // % of short side
    @Published var stickerRotation: Double = 0                       // degrees
    @Published var stickerOpacity: Double = 100                      // %
    @Published var stickerColor: MakeupColor = Sticker.defaultColor

    var hasStickers: Bool { !stickers.isEmpty }

    var canDeleteSticker: Bool { selectedSticker != nil }

    /// Stickers as the canvas sees them, keeping the stored index.
    var visibleStickers: [(index: Int, sticker: Sticker)] {
        ArtGeometry.indexed(stickers, crop: appliedCrop, aspect: sourceAspect)
    }

    private var selectedStickerValue: Sticker? {
        guard let selectedSticker else { return nil }
        return stickers.first { $0.id == selectedSticker }
    }

    /// The glyph the canvas draws for a sticker. Rotation and opacity are
    /// applied by the view; the glyph itself is composited once per kind and
    /// colour and cached.
    func stickerGlyph(_ sticker: Sticker) -> NSImage? {
        ArtRenderer.glyph(sticker)
    }

    /// One tap: select the sticker under the pointer, or place a new one.
    func tapArt(at point: CGPoint) {
        guard hasImage else { return }
        let clamped = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
        if let hit = stickerID(at: clamped) {
            selectedSticker = hit
            return
        }
        placeSticker(at: clamped)
    }

    /// The topmost sticker under a working-frame point, if any. The canvas
    /// needs the same answer to start a drag, so it lives here rather than in
    /// the overlay.
    func stickerID(at point: CGPoint) -> UUID? {
        visibleStickers.last(where: { hitSticker($0.sticker, at: point) })?.sticker.id
    }

    private func hitSticker(_ sticker: Sticker, at point: CGPoint) -> Bool {
        let radius = max(0.015, sticker.size * 0.55)
        return hypot(sticker.center.x - point.x, sticker.center.y - point.y) <= radius
    }

    private func placeSticker(at point: CGPoint) {
        let sticker = Sticker(
            kind: stickerKind,
            center: ArtGeometry.originalCenter(point, crop: appliedCrop),
            size: ArtGeometry.originalSize(max(2, stickerSize) / 100,
                                           crop: appliedCrop,
                                           aspect: sourceAspect),
            rotation: stickerRotation,
            opacity: stickerOpacity / 100,
            color: stickerColor)
        stickers.append(sticker)
        selectedSticker = sticker.id
        statusToken = .stickerAdded(stickers.count)
    }

    func selectSticker(_ id: UUID?) {
        selectedSticker = id
    }

    /// Live move while a sticker is dragged; the stored coordinate is the
    /// original photo's, so a crop keeps it attached.
    func moveSticker(_ id: UUID, to point: CGPoint) {
        guard let index = stickers.firstIndex(where: { $0.id == id }) else { return }
        stickers[index].center = ArtGeometry.originalCenter(
            CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y))),
            crop: appliedCrop)
    }

    func updateSelectedSticker(_ update: (inout Sticker) -> Void) {
        guard let selectedSticker,
              let index = stickers.firstIndex(where: { $0.id == selectedSticker }) else { return }
        update(&stickers[index])
    }

    /// Live resize from the corner handle. `workingFraction` is a share of the
    /// working frame's short side, which is the unit the overlay draws in.
    func resizeSelectedSticker(workingFraction: Double) {
        let clamped = min(1.2, max(0.02, workingFraction))
        updateSelectedSticker {
            $0.size = ArtGeometry.originalSize(clamped, crop: appliedCrop, aspect: sourceAspect)
        }
        stickerSize = clamped * 100
    }

    /// Live rotation from the handle above a selected sticker, in degrees.
    func rotateSelectedSticker(_ degrees: Double) {
        let normalized = ((degrees + 180).truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) - 180
        updateSelectedSticker { $0.rotation = normalized }
        stickerRotation = normalized
    }

    func duplicateSelectedSticker() {
        guard let selected = selectedStickerValue else { return }
        var copy = selected
        copy.id = UUID()
        // Offset in the working frame so the copy is visible beside the
        // original instead of sitting exactly under it.
        let center = ArtGeometry.workingCenter(selected.center, crop: appliedCrop)
        let shifted = CGPoint(x: min(0.98, max(0.02, center.x + 0.04)),
                              y: min(0.98, max(0.02, center.y + 0.04)))
        copy.center = ArtGeometry.originalCenter(shifted, crop: appliedCrop)
        stickers.append(copy)
        self.selectedSticker = copy.id
        statusToken = .stickerAdded(stickers.count)
    }

    func deleteSelectedSticker() {
        guard let selectedSticker,
              let index = stickers.firstIndex(where: { $0.id == selectedSticker }) else { return }
        stickers.remove(at: index)
        self.selectedSticker = nil
        statusToken = .stickerRemoved
    }

    func clearStickers() {
        guard !stickers.isEmpty else { return }
        commitAdjustments()
        stickers.removeAll()
        selectedSticker = nil
        commitAdjustments()
        statusToken = .stickersCleared
    }

    // The controls edit the selected sticker when there is one, and otherwise
    // set what the next tap will place. That keeps one panel usable both ways.

    func stickerKindBinding() -> Binding<StickerKind> {
        Binding(get: { self.selectedStickerValue?.kind ?? self.stickerKind },
                set: { value in
                    self.stickerKind = value
                    self.updateSelectedSticker { $0.kind = value }
                })
    }

    func stickerSizeBinding() -> Binding<Double> {
        Binding(get: {
            let working = self.selectedStickerValue.map {
                ArtGeometry.workingSize($0.size, crop: self.appliedCrop, aspect: self.sourceAspect)
            } ?? self.stickerSize / 100
            return working * 100
        },
                set: { value in
                    self.stickerSize = value
                    self.updateSelectedSticker {
                        $0.size = ArtGeometry.originalSize(max(2, value) / 100,
                                                           crop: self.appliedCrop,
                                                           aspect: self.sourceAspect)
                    }
                })
    }

    func stickerRotationBinding() -> Binding<Double> {
        Binding(get: { self.selectedStickerValue?.rotation ?? self.stickerRotation },
                set: { value in
                    self.stickerRotation = value
                    self.updateSelectedSticker { $0.rotation = value }
                })
    }

    func stickerOpacityBinding() -> Binding<Double> {
        Binding(get: { (self.selectedStickerValue?.opacity ?? self.stickerOpacity / 100) * 100 },
                set: { value in
                    self.stickerOpacity = value
                    self.updateSelectedSticker { $0.opacity = value / 100 }
                })
    }

    func stickerColorBinding() -> Binding<MakeupColor> {
        Binding(get: { self.selectedStickerValue?.color ?? self.stickerColor },
                set: { value in
                    self.stickerColor = value
                    self.updateSelectedSticker { $0.color = value }
                })
    }

    // MARK: - Face analysis

    /// The overlay can only be drawn on a photo that has a face to measure.
    var analysisReady: Bool { hasImage && !faces.isEmpty }

    /// Vision found the face but traced no feature points, so the callouts run
    /// from the face box. The overlay still draws; the panel says why the dots
    /// are approximate.
    var analysisUsesFaceBoxFallback: Bool {
        guard analysisReady,
              let face = AnalysisRenderer.primaryFace(faces, focus: focusFace) else { return false }
        return !face.hasLandmarks
    }

    var canResetAnalysisPins: Bool { !analysis.endpoints.isEmpty || !analysis.anchors.isEmpty }

    var analysisEnabledBinding: Binding<Bool> {
        Binding(get: { self.analysis.isEnabled },
                set: { self.analysis.isEnabled = $0 })
    }

    var analysisMeshBinding: Binding<Bool> {
        Binding(get: { self.analysis.showsMesh },
                set: { self.analysis.showsMesh = $0 })
    }

    var analysisOutlineBinding: Binding<Bool> {
        Binding(get: { self.analysis.showsFaceOutline },
                set: { self.analysis.showsFaceOutline = $0 })
    }

    var analysisGlowBinding: Binding<Bool> {
        Binding(get: { self.analysis.glow },
                set: { self.analysis.glow = $0 })
    }

    var analysisOpacityBinding: Binding<Double> {
        Binding(get: { self.analysis.lineOpacity * 100 },
                set: { self.analysis.lineOpacity = min(1, max(0.05, $0 / 100)) })
    }

    var analysisMarginBinding: Binding<Double> {
        Binding(get: { self.analysis.marginPercent },
                set: { self.analysis.marginPercent = min(30, max(4, $0)) })
    }

    var analysisWeightBinding: Binding<Double> {
        Binding(get: { self.analysis.lineWeight },
                set: { self.analysis.lineWeight = min(240, max(60, $0)) })
    }

    var analysisTintBinding: Binding<AnalysisTint> {
        Binding(get: { self.analysis.tint },
                set: { self.analysis.tint = $0 })
    }

    /// A switch that decides which areas get a shape and a leader line.
    func analysisRegionBinding(_ region: AnalysisRegion) -> Binding<Bool> {
        Binding(get: { self.analysis.regions.contains(region) },
                set: { on in
                    if on { self.analysis.regions.insert(region) }
                    else { self.analysis.regions.remove(region) }
                })
    }

    /// Leader ends as the canvas draws them: the same normalized, bottom-left
    /// coordinates the renderer uses.
    var analysisLeaders: [(region: AnalysisRegion, end: CGPoint)] {
        guard analysis.isEnabled,
              let face = AnalysisRenderer.primaryFace(faces, focus: focusFace) else { return [] }
        let ends = AnalysisRenderer.layout(face: face, settings: analysis)
        return analysis.primaryCallouts.compactMap { region in
            ends[region].map { (region, $0) }
        }
    }

    /// The leader end under a working-frame point, within `tolerance` in the
    /// same normalized units. The canvas starts a drag with this.
    func analysisRegion(at point: CGPoint, tolerance: CGFloat) -> AnalysisRegion? {
        var hit: (region: AnalysisRegion, distance: CGFloat)?
        for leader in analysisLeaders {
            let distance = hypot(leader.end.x - point.x, leader.end.y - point.y)
            guard distance <= tolerance else { continue }
            if hit == nil || distance < hit!.distance {
                hit = (leader.region, distance)
            }
        }
        return hit?.region
    }

    func dragAnalysisEnd(_ region: AnalysisRegion, to point: CGPoint) {
        analysis.setEndpoint(CGPoint(x: min(1, max(0, point.x)),
                                     y: min(1, max(0, point.y))),
                             for: region)
    }

    /// Where each face-side dot sits: the owner's pin when there is one, the
    /// feature the renderer picked otherwise.
    var analysisAnchors: [(region: AnalysisRegion, point: CGPoint)] {
        guard analysis.isEnabled,
              let face = AnalysisRenderer.primaryFace(faces, focus: focusFace) else { return [] }
        return analysis.primaryCallouts.compactMap { region in
            let point = analysis.anchor(for: region)
                ?? AnalysisRenderer.anchor(region, face: face)
            return (region, point)
        }
    }

    func analysisAnchor(at point: CGPoint, tolerance: CGFloat) -> AnalysisRegion? {
        analysisAnchors.reduce(nil as (AnalysisRegion, CGFloat)?) { best, anchor in
            let distance = hypot(anchor.point.x - point.x, anchor.point.y - point.y)
            guard distance <= tolerance else { return best }
            guard let best else { return (anchor.region, distance) }
            return distance < best.1 ? (anchor.region, distance) : best
        }?.0
    }

    func dragAnalysisAnchor(_ region: AnalysisRegion, to point: CGPoint) {
        analysis.setAnchor(CGPoint(x: min(1, max(0, point.x)),
                                   y: min(1, max(0, point.y))),
                           for: region)
    }

    /// Both kinds of pin go back at once: they are the same gesture to the
    /// owner, so one reset covers the lines and the dots.
    func resetAnalysisPins() {
        guard !analysis.endpoints.isEmpty || !analysis.anchors.isEmpty else { return }
        commitAdjustments()
        analysis.resetEndpoints()
        analysis.resetAnchors()
        commitAdjustments()
    }

    // MARK: - Lens and backdrop colours

    /// A lens colour picked by hand switches the iris tool on, the same way a
    /// makeup swatch does.
    func setLensColor(_ color: MakeupColor) {
        guard adjustments.lensColor != color else { return }
        adjustments.lensColor = color
        if adjustments.lensTint == 0 { adjustments.lensTint = 45 }
    }

    func lensColorBinding() -> Binding<MakeupColor> {
        Binding(get: { self.adjustments.lensColor },
                set: { self.setLensColor($0) })
    }

    func setBackgroundFillColor(_ color: MakeupColor) {
        guard adjustments.backgroundFillColor != color else { return }
        adjustments.backgroundFillColor = color
        if adjustments.backgroundFill == 0, !adjustments.backgroundRemove {
            adjustments.backgroundFill = 100
        }
    }

    func backgroundFillColorBinding() -> Binding<MakeupColor> {
        Binding(get: { self.adjustments.backgroundFillColor },
                set: { self.setBackgroundFillColor($0) })
    }

    /// Copies a chosen photo into the backdrop store and attaches it to this
    /// document. The original file is read once here, so an unreadable choice
    /// is refused before the document changes.
    func chooseBackdropImage() {
        guard hasImage else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = s.chooseBackdropMessage
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard CIImage(contentsOf: url,
                      options: [CIImageOption.applyOrientationProperty: true]) != nil else {
            statusToken = .backdropFailed
            return
        }
        do {
            let name = try BackdropStore.store(url)
            adjustments.backgroundImage = name
            adjustments.backgroundImageName = url.lastPathComponent
            adjustments.backgroundImageAmount = 100
        } catch {
            statusToken = .backdropFailed
        }
    }

    func clearBackdropImage() {
        guard !adjustments.backgroundImage.isEmpty else { return }
        adjustments.backgroundImage = ""
        adjustments.backgroundImageName = ""
        adjustments.backgroundImageAmount = 100
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

    /// Builds the subject silhouette the first time a Body or Background
    /// control moves. A portrait load never pays for segmentation unless one of
    /// those tools is actually used, and the answer is kept for this photo
    /// until the pixels change.
    private func ensurePersonMask() {
        guard adjustments.usesPersonTools, let source = sourcePreview else { return }
        if masksPreview?.person != nil {
            subjectState = .available
            return
        }
        guard subjectState != .detecting, subjectState != .unavailable else { return }

        subjectState = .detecting
        personGeneration += 1
        let token = personGeneration
        Task { [weak self] in
            let analysis = await Task.detached(priority: .userInitiated) {
                PersonAnalyzer.analysis(for: source)
            }.value

            guard let self, self.personGeneration == token else { return }
            guard let analysis else {
                self.subjectState = .unavailable
                self.hasBodyPose = false
                return
            }
            if self.masksPreview == nil {
                self.masksPreview = .personOnly(analysis.mask, pose: analysis.pose)
            } else {
                self.masksPreview?.person = analysis.mask
                self.masksPreview?.pose = analysis.pose
            }
            self.subjectState = .available
            self.hasBodyPose = analysis.pose != nil
            // The first render ran without the silhouette, so it has to be
            // painted again now that Body and Background have their mask.
            self.schedulePreview()
        }
    }

    func schedulePreview() {
        guard let source = sourcePreview else { return }
        // Previews coalesce among themselves but never cut in front of a
        // load, an export or a batch; that job repaints the canvas when done.
        guard let token = begin(.preview) else { return }
        if adjustments.usesPersonTools { ensurePersonMask() }
        renderTask?.cancel()
        generation += 1
        let generation = self.generation

        let adjustments = self.adjustments
        let masks = self.masksPreview
        let faces = self.faces
        let focus = focusFace
        let spots = self.spotsPreview
        let art = ArtGeometry.workingStickers(stickers, crop: appliedCrop, aspect: sourceAspect)
        let edits = aiEdits
        let crop = appliedCrop
        let colorSpace = self.sourceColorSpace
        let processor = self.processor

        renderTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            if Task.isCancelled {
                if let self, self.activeOperation == token { self.renderTask = nil }
                self?.end(token)
                return
            }

            let cgImage = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                let ai = AICompositor.layers(edits, crop: crop)
                let processed = processor.process(source, adjustments: adjustments,
                                                  masks: masks, faces: faces, spots: spots,
                                                  art: art, ai: ai, focus: focus)
                return processor.renderCGImage(processed, scale: 1, colorSpace: colorSpace)
            }.value

            // A newer preview, a load or an export has taken over: its token
            // owns the canvas and the busy flag now.
            guard let self, self.generation == generation,
                  self.activeOperation == token else { return }
            self.renderTask = nil
            if let cgImage {
                self.previewImage = NSImage(cgImage: cgImage,
                                           size: NSSize(width: cgImage.width, height: cgImage.height))
            }
            self.end(token)
        }
    }

    // MARK: - Adjustments

    func resetAll() {
        guard hasImage, !refuseIfBlocking() else { return }
        commitAdjustments()
        let cropChanged = appliedCrop != nil
        let frameChanged = cropChanged || documentOrientation != .identity
        adjustments = .zero
        if !healSpots.isEmpty { healSpots.removeAll() }
        if !aiEdits.isEmpty { aiEdits.removeAll() }
        stickers.removeAll()
        selectedSticker = nil
        analysis = AnalysisSettings()
        applyFaceSelection(nil)
        refreshAnalysisOverlay()
        comparePosition = settings.comparePosition
        if frameChanged {
            appliedCrop = nil
            documentOrientation = .identity
            cropAspect = .free
            cropDraft = CropGeometry.full
        }
        // Sliders, stamps, stickers, analysis and framing go back in one step,
        // so one ⌘Z returns the whole document.
        commitAdjustments()
        updateCleanState()
        if frameChanged { reloadCropped(restoring: false) }
    }

    /// True when every group, stamp, sticker, analysis pin and the framing
    /// match a new document. The Reset All menu item keys off this, not off the
    /// sliders alone.
    var isDocumentPristine: Bool {
        adjustments.isIdentity && healSpots.isEmpty && stickers.isEmpty
            && aiEdits.isEmpty
            && analysis == AnalysisSettings() && appliedCrop == nil
            && documentOrientation == .identity
    }

    func apply(_ preset: Preset) {
        commitAdjustments()
        adjustments = preset.adjustments
    }

    func apply(_ preset: UserPreset) {
        commitAdjustments()
        adjustments = preset.adjustments
    }

    func binding(for keyPath: WritableKeyPath<Adjustments, Double>) -> Binding<Double> {
        Binding(get: { self.adjustments[keyPath: keyPath] },
                set: { self.adjustments[keyPath: keyPath] = $0 })
    }

    func isActive(_ preset: Preset) -> Bool {
        adjustments == preset.adjustments
    }

    func isActive(_ preset: UserPreset) -> Bool {
        adjustments == preset.adjustments
    }

    // MARK: - Saved looks

    /// Saves the current sliders as a named look. Re-using a name replaces the
    /// old one, which is what "save over it" means to everyone.
    func saveCurrentAsPreset(named raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        userPresets.removeAll { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
        userPresets.append(UserPreset(name: name, adjustments: adjustments))
        UserPresetStore.save(userPresets)
        statusToken = .presetSaved(name)
        buildPresetThumbs()
    }

    func removeUserPreset(_ preset: UserPreset) {
        userPresets.removeAll { $0.id == preset.id }
        UserPresetStore.save(userPresets)
        presetThumbs.removeValue(forKey: preset.id)
    }

    // MARK: - Preset thumbnails

    /// Renders one small tile per preset from the photo that is really open, so
    /// the choice shows the effect instead of a word. Rebuilt whenever the
    /// photo or the saved looks change; the tiles are cheap because they run on
    /// a 320-point copy of the preview with its own masks.
    func buildPresetThumbs() {
        thumbTask?.cancel()
        guard let source = sourcePreview, let faces = facesIfLoaded else {
            presetThumbs = [:]
            return
        }
        let colorSpace = sourceColorSpace
        let processor = self.processor
        let entries: [(id: String, adjustments: Adjustments)] =
            Preset.all.map { ($0.id.rawValue, $0.adjustments) }
            + userPresets.map { ($0.id, $0.adjustments) }

        thumbTask = Task { [weak self] in
            let rendered = await Task.detached(priority: .utility) { () -> [String: NSImage] in
                var out: [String: NSImage] = [:]
                let long = max(source.extent.width, source.extent.height)
                guard long > 0 else { return out }
                let scale = min(1, 320 / long)
                let small = scale >= 1
                    ? source
                    : source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                        .cropped(to: CGRect(x: 0, y: 0,
                                            width: (source.extent.width * scale).rounded(),
                                            height: (source.extent.height * scale).rounded()))
                let masks = processor.buildMasks(extent: small.extent, faces: faces, image: small)

                // A tile is a landscape slot, so each thumbnail is cropped
                // around the primary face with the tile's own proportions; the
                // uncropped frame would show whatever sits mid-photo, and a
                // square one would cut away the hair and backdrop that carry a
                // film grade.
                let pixels = small.extent
                let box = faces.first?.boundingBox
                    ?? CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
                let faceHeight = min(1.7 * box.height * pixels.height, pixels.height)
                let cropW = min(1.55 * faceHeight, pixels.width)
                let centre = CGPoint(x: box.midX * pixels.width,
                                     y: (1 - box.midY) * pixels.height)
                let crop = CGRect(
                    x: min(max(0, centre.x - cropW / 2), max(0, pixels.width - cropW)),
                    y: min(max(0, centre.y - faceHeight / 2), max(0, pixels.height - faceHeight)),
                    width: cropW, height: faceHeight)

                for entry in entries {
                    if Task.isCancelled { return [:] }
                    let image = processor.process(small, adjustments: entry.adjustments,
                                                  masks: masks, faces: faces)
                    guard let rendered = processor.renderCGImage(image, scale: 1, colorSpace: colorSpace)
                    else { continue }
                    let cg = rendered.cropping(to: crop) ?? rendered
                    out[entry.id] = NSImage(cgImage: cg,
                                            size: NSSize(width: cg.width, height: cg.height))
                }
                return out
            }.value
            guard let self, !Task.isCancelled else { return }
            self.presetThumbs = rendered
        }
    }

    /// The faces of the loaded photo, or nil when there is nothing loaded.
    private var facesIfLoaded: [FaceGeometry]? {
        hasImage ? faces : nil
    }

    // MARK: - Auto

    /// The measured suggestion, in words, for the status line: what the
    /// analyzer decided to do, and therefore what it found. Smart Analyze is
    /// the one generative entry; the per-tool Generate buttons this once
    /// reported for applied the same measurements without ever showing them.
    func retouchReadout(_ a: Adjustments, spots: Int) -> [String] {
        var parts: [String] = []
        if a.smooth >= 16 { parts.append(s.autoSaidSmoothing) }
        else if a.smooth >= 6 { parts.append(s.autoSaidLightSmoothing) }
        if a.blemish > 0 { parts.append(s.autoSaidBlemishes(max(1, spots))) }
        if a.wrinkle >= 4 { parts.append(s.autoSaidLines) }
        if a.darkCircles >= 8 { parts.append(s.autoSaidDarkCircles) }
        if a.skinToneEvens >= 10 { parts.append(s.autoSaidTone) }
        if a.skinBrighten >= 3 { parts.append(s.autoSaidBrighter) }
        if a.teethWhiten > 0 { parts.append(s.autoSaidTeeth) }
        if a.eyeBrighten > 0 { parts.append(s.autoSaidEyes) }
        return parts
    }

    /// True when at least one detected face actually shows teeth. The teeth
    /// mask only exists in that case, so the UI can explain the skip.
    var hasVisibleTeeth: Bool { faces.contains { $0.hasVisibleTeeth } }

    // MARK: - Smart Analyze

    var canSmartAnalyze: Bool { hasImage && !isBusy && !isAnalyzingSmart }

    /// Reads the photo and *shows* what it found before changing anything. The
    /// report is a measurement: which face has blemishes, whether the under-eye
    /// area is darker than the cheek, how strong the lines are, and what the
    /// color/light numbers come out as. Nothing moves until `applySmartReport`.
    func smartAnalyze() {
        guard let source = sourcePreview, !isAnalyzingSmart else { return }
        guard let operation = begin(.smart) else {
            statusToken = .operationBusy
            return
        }
        smartGeneration += 1
        let token = smartGeneration
        isAnalyzingSmart = true
        statusToken = .analyzingSmart
        let faces = self.faces
        let skinMask = masksPreview?.skin
        let processor = ImageProcessor.shared

        Task { [weak self] in
            let report = await Task.detached(priority: .userInitiated) { () -> SmartAnalyzer.Report? in
                guard let buffer = AutoAnalyzer.analysisBuffer(source) else { return nil }
                let maskBuffer = skinMask.flatMap { AutoAnalyzer.analysisBuffer($0) }
                // Blemishes are read from a face-sized crop: the 512 px buffer
                // cannot tell a spot from a compression block on a small face.
                let crops = faces.map {
                    processor.faceCrop(for: $0, in: source, skinMask: skinMask)
                }
                return SmartAnalyzer.analyze(buffer: buffer, skinMask: maskBuffer,
                                             faces: faces, crops: crops)
            }.value
            guard let self, self.smartGeneration == token else { return }
            self.isAnalyzingSmart = false
            self.end(operation)
            guard let report else {
                self.statusToken = .smartFailed
                return
            }
            self.smartReport = report
            self.smartApplyRetouch = true
            self.smartApplyColorLight = true
            self.smartApplyHealSpots = !report.spots.isEmpty
            self.showSmartSheet = true
            self.statusToken = .smartReady
        }
    }

    /// Applies the checked parts of the last report as one undo step. The
    /// strength sliders decide how much of each patch is used, so Smart
    /// Analyze never applies more than the owner's own setting.
    func applySmartReport() {
        guard let report = smartReport else { return }
        commitAdjustments()
        var next = adjustments
        var appliedRetouch = Adjustments()
        if smartApplyRetouch {
            appliedRetouch = report.retouch.scaledRetouch(by: autoRetouchStrength)
            next = next.applyingRetouch(appliedRetouch, fields: .smart)
        }
        if smartApplyColorLight {
            let patch = report.colorLight.scaledColorLight(by: autoColorStrength)
            next = next.applyingColorLight(patch, fields: .autoColorLight)
        }
        adjustments = next
        if smartApplyHealSpots {
            addSuggestedHealSpots(report.spots)
        }
        commitAdjustments()
        showSmartSheet = false
        // The status line names what the measurements became, in the same words
        // the report used — an apply that found nothing to fix says so.
        let words = retouchReadout(appliedRetouch, spots: report.spots.count)
        statusToken = words.isEmpty ? .smartApplied : .smartAppliedReport(words)
    }

    /// Converts the analyzer's working-coordinate spots into stamps against the
    /// original photo, skipping any the owner already healed by hand.
    private func addSuggestedHealSpots(_ spots: [SmartAnalyzer.Spot]) {
        let existing = HealGeometry.workingSpots(healSpots, crop: appliedCrop)
        var addedWorking: [HealSpot] = []
        var added: [HealSpot] = []
        for spot in spots {
            let working = HealSpot(center: spot.center, radius: spot.radius)
            let covered = (existing + addedWorking).contains {
                HealGeometry.shortSideDistance($0.center, working.center, aspect: workingAspect)
                    <= max($0.radius, working.radius)
            }
            guard !covered else { continue }
            addedWorking.append(working)
            added.append(HealSpot(
                center: HealGeometry.originalCenter(spot.center, crop: appliedCrop),
                radius: HealGeometry.originalRadius(spot.radius, crop: appliedCrop)))
        }
        guard !added.isEmpty else { return }
        healSpots.append(contentsOf: added)
    }

    /// How many findings a report holds, for the card's one-line summary.
    var smartFindingCount: Int {
        guard let report = smartReport else { return 0 }
        return report.faces.reduce(report.photoFindings.count) { $0 + $1.findings.count }
    }

    // MARK: - Preferences

    /// Copies edited preferences back into the open document, so the Settings
    /// window changes what is on screen right away.
    func refreshPreferences() {
        autoRetouchStrength = settings.autoRetouchStrength
        autoColorStrength = settings.autoColorStrength
        exportFormat = ExportFormat(rawValue: settings.exportFormat) ?? .jpeg
        exportQuality = settings.exportQuality
        exportLongEdge = settings.exportLongEdge
        exportAIUpscale = settings.exportAIUpscale
        stripLocationMetadata = settings.stripLocationMetadata
        watermark = settings.watermark
        healBrushPercent = settings.healBrushPercent
        showFaceOverlay = settings.showFaceOverlay
        language = settings.language
    }

    func resetPreferences() {
        settings.resetToDefaults()
        refreshPreferences()
        statusToken = .settingsReset
    }

    func openRecent(_ entry: RecentEntry) {
        guard entry.exists else {
            recents.remove(entry)
            statusToken = .recentMissing(entry.name)
            return
        }
        requestOpen(url: entry.url)
    }

    // MARK: - Recovery

    /// Writes the working recovery copy while the photo has unsaved work.
    /// Debounced, so a slider drag touches the disk once instead of on every
    /// tick. Candidates are never written here: a postponed copy has its own
    /// immutable file and nothing in this path can reach it.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard settings.recoveryEnabled, !isLoadingState else { return }
        guard hasImage, hasUnsavedChanges, let project = makeProject() else {
            // A clean document no longer needs its autosave copy. A restored
            // document is the exception: the working slot is its only durable
            // copy until the owner saves a project.
            if hasImage, !documentRecovered {
                _ = RecoveryStore.removeWorking(ifSourcePath: imageURL?.path)
            }
            return
        }
        let snapshot = RecoverySnapshot.capture(project)
        let epoch = RecoveryStore.epoch
        let delay = autosaveDebounceNanoseconds
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            // Tests park here to invalidate a task that already started but has
            // not committed. Production leaves the hook nil.
            self.autosaveWillWrite?()
            guard !Task.isCancelled,
                  RecoveryStore.epoch == epoch,
                  !self.isLoadingState,
                  self.imageURL?.path == snapshot.project.imagePath else { return }
            self.persistAutosave(snapshot)
        }
    }

    /// Cancels the debounced autosave of a document that is being discarded or
    /// replaced and invalidates a task that already resumed past its sleep.
    /// `Task.cancel()` cannot stop that task on its own because nothing
    /// suspends between the check and the write, so the store epoch is bumped
    /// as well. The bump happens before the next document schedules anything,
    /// which keeps a legitimate autosave of the new document valid.
    private func invalidatePendingAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        RecoveryStore.invalidatePendingAutosaves()
    }

    private func persistAutosave(_ snapshot: RecoverySnapshot) {
        guard settings.recoveryEnabled else { return }
        if !RecoveryStore.writeWorking(snapshot) {
            // This write is what protects the next launch; staying silent would
            // let the owner close the window believing the copy is safe.
            statusToken = .recoveryStorageFailed
        }
    }

    /// Runs the debounced autosave now through the same path. Tests use this so
    /// they never have to sleep past the delay.
    func flushAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard settings.recoveryEnabled, !isLoadingState,
              hasImage, hasUnsavedChanges, let project = makeProject() else { return }
        persistAutosave(RecoverySnapshot.capture(project))
    }

    // MARK: - Recovery

    /// Asks once, at launch, whether to reopen crash copies. Every unresolved
    /// copy is offered in turn; Cancel postpones the whole pass and leaves all
    /// of them on disk.
    func offerRecoveryIfNeeded() {
        guard !offeredRecovery, !hasImage, settings.recoveryEnabled else { return }
        // The pass only counts as offered after the launch slots are safe. A
        // failed promotion leaves the working copy in place, and the next
        // document entry retries the barrier instead of pretending it ran.
        guard ensureRecoveryPrepared() else { return }
        offeredRecovery = true
        handledRecovery.removeAll()
        offerNextRecoveryCandidate()
    }

    /// The single recovery-readiness barrier shared by the launch pass and
    /// every document-entry path. It lifts `working.retouch` and the legacy
    /// slots into independent candidates once per session, before a new
    /// document can remove the working copy or autosave over it.
    ///
    /// A working copy that could not be promoted is still the only copy of the
    /// previous session: the store is locked, so autosave and removal both
    /// refuse to touch it, and this returns `false` so the caller keeps the
    /// current document. A legacy file that could not be renamed stays in its
    /// read-only slot, is reported, and does not block the open. A failed
    /// attempt is retried by the next caller because `recoveryPrepared` is only
    /// set after a safe launch. Promotion is not gated on the recovery
    /// preference: the preference controls offering and new autosaves, not
    /// whether an existing copy may be destroyed by an open.
    @discardableResult
    private func ensureRecoveryPrepared() -> Bool {
        if recoveryPrepared { return true }
        let launch = RecoveryStore.prepareForLaunch()
        if launch.quarantined > 0 { statusToken = .recoveryQuarantined(launch.quarantined) }
        if launch.failed {
            statusToken = .recoveryStorageFailed
            if FileManager.default.fileExists(atPath: RecoveryStore.workingURL.path) {
                return false
            }
        }
        recoveryPrepared = true
        return true
    }

    private enum RecoveryPassStep {
        case next
        case stop
    }

    /// Offers the oldest unresolved candidate this pass has not handled yet.
    /// A restore is asynchronous; its completion calls back into this loop.
    private func offerNextRecoveryCandidate() {
        guard settings.recoveryEnabled else { return }
        while true {
            let listing = RecoveryStore.loadCandidates()
            if listing.quarantined > 0 { statusToken = .recoveryQuarantined(listing.quarantined) }
            if listing.failed {
                // The unreadable file is still on disk and is retried on the
                // next launch, but it must not hide the copies that can be read.
                statusToken = .recoveryStorageFailed
            }
            guard let candidate = listing.candidates.first(where: {
                !handledRecovery.contains($0.url)
            }) else { return }
            switch offerRecoveryCandidate(candidate) {
            case .next: continue
            case .stop: return
            }
        }
    }

    private func offerRecoveryCandidate(_ candidate: RecoveryStore.Candidate) -> RecoveryPassStep {
        var project = candidate.snapshot.project
        var state = RecoveryStore.sourceState(for: candidate.snapshot)

        if case .missing = state {
            switch recoveryChoice(missingSource: true, sourceName: nil) {
            case .locate:
                // Closing the Locate panel is not permission to delete the
                // edit; leave the candidate exactly where it is.
                guard let picked = locateRecoveryPhoto(for: project) else { return .stop }
                project.imagePath = picked.path
                // The panel grants access to the photo the owner picked, not to
                // whatever the old path used to point at.
                project.imageBookmark = bookmark(for: picked)
                state = .available(picked)
            case .discard:
                return discardRecoveryCandidate(candidate)
            case .cancel, .restore:
                return .stop
            }
        }

        switch state {
        case .missing:
            return .stop
        case .changed(let source):
            // Size or date says this is not the photo the edits were made for.
            // Ask explicitly; never apply silently to a different image.
            switch recoveryChoice(missingSource: false, changedSource: true,
                                  sourceName: source.lastPathComponent) {
            case .restore:
                return beginRestore(candidate, project: project, source: source)
            case .discard:
                return discardRecoveryCandidate(candidate)
            case .cancel, .locate:
                return .stop
            }
        case .available(let source):
            switch recoveryChoice(missingSource: false, sourceName: source.lastPathComponent) {
            case .restore:
                return beginRestore(candidate, project: project, source: source)
            case .discard:
                return discardRecoveryCandidate(candidate)
            case .cancel, .locate:
                return .stop
            }
        }
    }

    private func discardRecoveryCandidate(_ candidate: RecoveryStore.Candidate) -> RecoveryPassStep {
        guard RecoveryStore.removeCandidate(at: candidate.url) else {
            // The file is still the only copy of this candidate; stop rather
            // than repeat the same prompt.
            statusToken = .recoveryCandidateNotRemoved
            return .stop
        }
        return .next
    }

    /// Snapshots the live document, then starts the load. The candidate is
    /// deleted only in `finishRestore`, after the working copy is verified.
    private func beginRestore(_ candidate: RecoveryStore.Candidate,
                              project: RetouchProject, source: URL) -> RecoveryPassStep {
        if hasImage {
            if hasUnsavedChanges {
                guard let live = makeProject(),
                      let preserved = RecoveryStore.saveCandidate(RecoverySnapshot.capture(live))
                else {
                    statusToken = .recoveryStorageFailed
                    return .stop
                }
                // Preserved for the next launch, not re-offered now.
                handledRecovery.insert(preserved)
            } else if let working = RecoveryStore.readWorking() {
                // A document restored earlier has no unsaved slider, but the
                // working slot is its only durable copy. Preserve it before the
                // next candidate takes that slot.
                guard let preserved = RecoveryStore.saveCandidate(working) else {
                    statusToken = .recoveryStorageFailed
                    return .stop
                }
                handledRecovery.insert(preserved)
            }
        }
        handledRecovery.insert(candidate.url)
        load(url: source, restoring: project,
             recoveryRestore: RecoveryRestore(candidateURL: candidate.url))
        return .stop
    }

    /// Deletes the candidate only after the restored document is durable in the
    /// working slot. write -> verify -> delete leaves a complete copy after a
    /// crash at every step.
    private func finishRestore(_ restore: RecoveryRestore) {
        guard let project = makeProject(),
              RecoveryStore.writeWorking(RecoverySnapshot.capture(project)) else {
            // The candidate is still the only durable copy; keep it and stop.
            statusToken = .recoveryStorageFailed
            return
        }
        guard RecoveryStore.removeCandidate(at: restore.candidateURL) else {
            // The restored document is safe in the working slot; the old copy
            // is left behind for the next launch, which reports it again.
            statusToken = .recoveryCandidateNotRemoved
            return
        }
        // Only the prompt order is deferred: durability above is synchronous.
        DispatchQueue.main.async { [weak self] in
            self?.offerNextRecoveryCandidate()
        }
    }

    /// The first prompt's buttons are Locate, Cancel, Discard. Escape and a
    /// closed alert arrive as `.abort` and are treated as Cancel.
    static func missingSourceChoice(for response: NSApplication.ModalResponse) -> RecoveryChoice {
        switch response {
        case .alertFirstButtonReturn: return .locate
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// The second prompt's buttons are Restore, Cancel, Discard. Same rule:
    /// only the third button is destructive.
    static func restoreChoice(for response: NSApplication.ModalResponse) -> RecoveryChoice {
        switch response {
        case .alertFirstButtonReturn: return .restore
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    private func recoveryChoice(missingSource: Bool, changedSource: Bool = false,
                                sourceName: String?) -> RecoveryChoice {
        if let recoveryChoiceHandler {
            return recoveryChoiceHandler(missingSource, sourceName)
        }
        let alert = NSAlert()
        alert.messageText = s.recoveryTitle
        if missingSource {
            alert.informativeText = s.projectPhotoMissing
        } else if changedSource {
            alert.informativeText = s.recoveryChangedMessage(sourceName ?? "")
        } else {
            alert.informativeText = s.recoveryMessage(sourceName ?? "")
        }
        alert.alertStyle = missingSource || changedSource ? .warning : .informational
        alert.addButton(withTitle: missingSource ? s.projectLocateTitle : s.recoveryRestore)
        alert.addButton(withTitle: s.cancel)
        let discard = alert.addButton(withTitle: s.recoveryDiscard)
        discard.hasDestructiveAction = true
        discard.keyEquivalent = ""
        // AppKit does not wire Esc to the cancel button for programmatic
        // alerts. Escape and a closed window both mean Cancel: only the
        // explicit destructive button may delete the recovery copy.
        let escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            NSApp.stopModal(withCode: .abort)
            return nil
        }
        let response = alert.runModal()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if response == .abort { alert.window.orderOut(nil) }
        return missingSource
            ? Self.missingSourceChoice(for: response)
            : Self.restoreChoice(for: response)
    }

    private func locateRecoveryPhoto(for project: RetouchProject) -> URL? {
        if let recoveryLocateHandler { return recoveryLocateHandler(project) }
        return locatePhoto(for: project)
    }

    // MARK: - Status text

    /// What just happened, in the language that is in force now.
    var status: String { s.statusText(statusToken) }

    /// The pixel size of the photo that is open, in the digits of the current
    /// language.
    var imageInfo: String {
        guard workingPixelSize.width > 0, workingPixelSize.height > 0 else { return "" }
        return "\(Digits.num(Int(workingPixelSize.width))) × \(Digits.num(Int(workingPixelSize.height))) px"
    }

    /// Whether the chosen edge asks for more pixels than the photo has.
    var exportEnlargementRequested: Bool {
        let size = workingPixelSize
        guard exportLongEdge > 0, size.width > 0, size.height > 0 else { return false }
        return max(size.width, size.height) < CGFloat(exportLongEdge)
    }

    /// Whether the export can reach a larger size at all. The upscaler is a
    /// fixed 4x pass with a 40 MP output ceiling, so both the request being an
    /// enlargement and the photo fitting that ceiling decide this.
    var exportUpscaleAvailable: Bool {
        let size = workingPixelSize
        guard exportLongEdge > 0, size.width > 0, size.height > 0 else { return false }
        let longest = max(size.width, size.height)
        return longest < CGFloat(exportLongEdge) && ExportUpscale.canHandle(size)
    }

    /// The upscaling that will actually run, if any. Both the snapshot and the
    /// size text read this, so the sheet cannot advertise something the export
    /// will not do.
    var usesExportUpscale: Bool { exportAIUpscale && exportUpscaleAvailable }

    /// Rough wall time for the pass, from the rate measured on this machine.
    var exportUpscaleEstimate: Int {
        ExportUpscale.estimatedSeconds(for: workingPixelSize)
    }

    /// Pixel size the export will actually write. Downscaling never enlarges a
    /// photo; a larger long edge is only reached through the upscaler.
    var exportPixelSize: CGSize {
        let size = workingPixelSize
        guard exportLongEdge > 0, size.width > 0, size.height > 0 else { return size }
        let longest = max(size.width, size.height)
        if longest >= CGFloat(exportLongEdge) {
            let scale = CGFloat(exportLongEdge) / longest
            return CGSize(width: (size.width * scale).rounded(),
                          height: (size.height * scale).rounded())
        }
        guard usesExportUpscale else { return size }
        let edge = ExportUpscale.outputLongEdge(sourceLong: longest,
                                                requested: CGFloat(exportLongEdge))
        let scale = edge / longest
        return CGSize(width: (size.width * scale).rounded(),
                      height: (size.height * scale).rounded())
    }

    var exportPixelText: String {
        let size = exportPixelSize
        guard size.width >= 1, size.height >= 1 else { return "" }
        return "\(Digits.num(Int(size.width))) × \(Digits.num(Int(size.height))) px"
    }

    var windowTitle: String {
        guard hasImage, !imageName.isEmpty else { return s.appName }
        return hasUnsavedChanges ? "\(imageName) — \(s.edited)" : imageName
    }

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
        // A file name that says "analysis" promises callouts the export cannot
        // draw when Vision found no face.
        guard analysis.isEnabled, !faces.isEmpty else {
            return "\(name).\(exportFormat.fileExtension)"
        }
        switch analysis.exportMode {
        case .onPhoto:
            return "\(name)-analysis.\(exportFormat.fileExtension)"
        case .poster:
            return "\(name)-analysis-poster.\(exportFormat.fileExtension)"
        case .overlayOnly:
            return "\(name)-analysis-lines.png"
        }
    }

    /// PNG because an overlay-only export is lines on transparency.
    private var effectiveExportFormat: ExportFormat {
        analysis.isEnabled && analysis.exportMode == .overlayOnly && !faces.isEmpty
            ? .png : exportFormat
    }

    func saveExport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFileName()
        panel.allowedContentTypes = [effectiveExportFormat.utType]
        panel.canCreateDirectories = true
        panel.message = s.chooseExportLocation
        guard panel.runModal() == .OK, let url = panel.url else { return }
        export(to: url)
    }

    /// The document as an export describes it. Both the single-photo export and
    /// batch export start here, so their snapshots cannot diverge.
    func makeExportSnapshot(includeStamps: Bool = true,
                            includeAnalysis: Bool = true) -> ExportSnapshot? {
        guard hasImage else { return nil }
        return ExportSnapshot(adjustments: adjustments,
                              healSpots: healSpots,
                              stickers: stickers,
                              aiEdits: aiEdits,
                              analysis: analysis,
                              crop: appliedCrop,
                              orientation: documentOrientation,
                              selectedFaceIndex: selectedFaceIndex,
                              format: effectiveExportFormat,
                              quality: exportQuality,
                              longEdge: exportLongEdge > 0 ? CGFloat(exportLongEdge) : nil,
                              stripsPrivacyMetadata: stripLocationMetadata,
                              includeStamps: includeStamps,
                              includeAnalysis: includeAnalysis,
                              aiUpscale: usesExportUpscale,
                              watermark: watermark)
    }

    func export(to url: URL) {
        guard let image = sourceFull, let snapshot = makeExportSnapshot() else { return }
        // Refuse before rendering: the source is immutable even when the chosen
        // destination is a symlink, a hard link, or a case-only alias of it.
        // The same check runs again at the commit point inside ExportService.
        if let imageURL, ExportService.referencesSameFile(url, imageURL) {
            statusToken = .exportRefusedOriginal
            return
        }
        let protectedURL = imageURL
        guard let token = begin(.export) else {
            statusToken = .operationBusy
            return
        }
        // A photo small enough to load at full size already has a set on
        // screen; otherwise hand nothing over and the renderer builds one at
        // export resolution, then drops it.
        let masks = sourcePreview?.extent.size == image.extent.size ? masksPreview : nil
        let source = ExportSource(image: image,
                                  masks: masks,
                                  faces: faces,
                                  photoAspect: sourceAspect,
                                  colorSpace: sourceColorSpace,
                                  metadata: sourceMetadata)

        isExporting = true
        statusToken = .renderingExport

        // A 4x pass can run for minutes, so the helper's tile count becomes the
        // status line instead of a frozen "rendering" message.
        let progressSink: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in self?.statusToken = .upscaling(done, total) }
        }
        let job = Task.detached(priority: .userInitiated) {
            ExportService.run(snapshot, source: source, to: url,
                              protecting: protectedURL,
                              progress: progressSink)
        }
        exportJob = job
        exportTask = Task { [weak self] in
            let outcome = await job.value
            guard let self else { return }
            self.exportJob = nil
            self.exportTask = nil
            self.isExporting = false
            // `end` releases the busy flag exactly once, whether the job saved,
            // failed or was cancelled.
            self.end(token)
            switch outcome {
            case .saved:
                self.showExportSheet = false
                self.statusToken = .saved(url.lastPathComponent)
                // An exported copy is not a saved project: the edits still
                // live only in this window, so the clean baseline must not move.
            case .cancelled:
                self.statusToken = .exportCancelled
            case .failed:
                self.statusToken = .exportFailed
            case .refusedSource:
                self.statusToken = .exportRefusedOriginal
            }
        }
    }

    /// Stops the one-photo export. The render job checks cancellation before it
    /// commits, so a cancelled export never writes a partial file.
    func cancelExport() {
        exportJob?.cancel()
    }

    // MARK: - Projects

    func saveProject() {
        guard !refuseIfBlocking() else { return }
        if let projectURL {
            writeProject(to: projectURL)
        } else {
            saveProjectAs()
        }
    }

    func saveProjectAs() {
        guard hasImage, !refuseIfBlocking() else { return }
        let base = (imageName as NSString).deletingPathExtension
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(base.isEmpty ? "retouch" : base).\(RetouchProject.fileExtension)"
        panel.allowedContentTypes = [RetouchProject.contentType]
        panel.canCreateDirectories = true
        panel.message = s.chooseProjectLocation
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeProject(to: url)
    }

    /// The open document as it would be written to disk. Shared by Save Project
    /// and by the crash-recovery copy, so the two can never drift apart.
    private func makeProject() -> RetouchProject? {
        guard let imageURL else { return nil }
        return RetouchProject(imagePath: imageURL.path,
                              imageBookmark: bookmark(for: imageURL),
                              adjustments: adjustments,
                              exportFormat: exportFormat.rawValue,
                              exportQuality: exportQuality,
                              exportLongEdge: exportLongEdge == 0 ? nil : exportLongEdge,
                              autoRetouchStrength: autoRetouchStrength,
                              autoColorStrength: autoColorStrength,
                              crop: appliedCrop,
                              healSpots: healSpots.isEmpty ? nil : healSpots,
                              stickers: stickers.isEmpty ? nil : stickers,
                              aiEdits: aiEdits.isEmpty ? nil : aiEdits,
                              analysis: analysis == AnalysisSettings() ? nil : analysis,
                              selectedFace: selectedFaceIndex,
                              orientation: documentOrientation.isIdentity ? nil : documentOrientation)
    }

    private func writeProject(to url: URL) {
        guard let project = makeProject() else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(project).write(to: url, options: .atomic)
            projectURL = url
            recents.add(url, isProject: true)
            // The edit is now persisted, so the discard prompt has nothing to
            // protect until the next change, and the autosave copy is redundant.
            session.markClean(currentState)
            documentRecovered = false
            updateCleanState()
            statusToken = .projectSaved(url.lastPathComponent)
        } catch {
            statusToken = .projectSaveFailed
        }
    }

    func openProject() {
        guard !refuseIfBlocking() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [RetouchProject.contentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = s.chooseProject
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    /// Opening a project replaces the current photo, so it shares the discard
    /// guard with normal loading.
    func openProject(at url: URL) {
        guard !refuseIfBlocking() else { return }
        guard ensureRecoveryPrepared() else { return }
        offeredRecovery = true
        guard confirmDiscardIfNeeded() else { return }
        do {
            let project = try JSONDecoder().decode(RetouchProject.self, from: Data(contentsOf: url))
            guard project.version <= RetouchProject.currentVersion else {
                statusToken = .projectTooNew(project.version)
                return
            }
            var source = resolveProjectImage(project, projectURL: url)
            if source == nil { source = locatePhoto(for: project) }
            guard let source else {
                statusToken = .projectPhotoMissing
                return
            }
            let recorded = URL(fileURLWithPath: project.imagePath).standardizedFileURL
            let relocated = source.standardizedFileURL != recorded
            guard prepareToReplaceDocument() else { return }
            load(url: source, restoring: project, projectURL: url,
                 relinkURL: relocated ? url : nil)
        } catch {
            statusToken = .projectOpenFailed
        }
    }

    /// Where the photo a project points at lives now, in order of trust: the
    /// bookmark survives a move, the absolute path covers an unmoved file, and
    /// a file sitting next to the project covers a moved folder. `nil` means
    /// the owner has to point at it.
    func resolveProjectImage(_ project: RetouchProject, projectURL: URL?) -> URL? {
        let manager = FileManager.default
        if let data = project.imageBookmark,
           let url = resolveBookmark(data),
           manager.fileExists(atPath: url.path) {
            return url
        }
        let absolute = URL(fileURLWithPath: project.imagePath)
        if manager.fileExists(atPath: absolute.path) { return absolute }
        if let projectURL {
            let sibling = projectURL.deletingLastPathComponent()
                .appendingPathComponent((project.imagePath as NSString).lastPathComponent)
            if manager.fileExists(atPath: sibling.path) { return sibling }
        }
        return nil
    }

    private func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                        bookmarkDataIsStale: &stale)
    }

    private func locatePhoto(for project: RetouchProject) -> URL? {
        let panel = NSOpenPanel()
        panel.title = s.projectLocateTitle
        panel.message = s.projectLocateMessage((project.imagePath as NSString).lastPathComponent)
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Writes the project again with the photo's current path and bookmark.
    /// The clean baseline is untouched: relinking records where the photo is,
    /// it does not save pending edits.
    private func rewriteProject(at url: URL) {
        guard let project = makeProject() else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(project).write(to: url, options: .atomic)
        } catch {
            // The photo still opens; only the next launch will ask again.
        }
    }

    // MARK: - Batch export

    /// Applies the current adjustments to several photos and writes them into
    /// one folder. Each photo gets its own face detection and masks, so the
    /// same slider values land on each face instead of on fixed coordinates.
    func batchExport() {
        guard hasImage, !isBatchRunning, !refuseIfBlocking() else { return }
        let sources = NSOpenPanel()
        sources.title = s.batchChoosePhotos
        sources.allowedContentTypes = [.image]
        sources.allowsMultipleSelection = true
        sources.canChooseDirectories = false
        guard sources.runModal() == .OK, !sources.urls.isEmpty else { return }

        let destination = NSOpenPanel()
        destination.title = s.batchChooseFolder
        destination.canChooseDirectories = true
        destination.canChooseFiles = false
        destination.allowsMultipleSelection = false
        guard destination.runModal() == .OK, let folder = destination.url else { return }

        batchSources = sources.urls
        batchFolder = folder
        batchTotal = sources.urls.count
        batchCompleted = 0
        batchSavedCount = 0
        batchSkippedCrops = 0
        batchHasReport = false
        showBatchSheet = true
    }

    /// Runs the job the sheet is showing, with the options it is showing.
    func startBatchExport() {
        guard !isBatchRunning, !batchSources.isEmpty, let folder = batchFolder else { return }
        runBatch(batchSources, to: folder)
    }

    func cancelBatchExport() {
        batchTask?.cancel()
        // The file runs in its own detached task, which does not inherit the
        // batch's cancellation, so it must be cancelled by name.
        batchFileTask?.cancel()
    }

    func dismissBatchSheet() {
        guard !isBatchRunning else { return }
        showBatchSheet = false
    }

    /// The batch uses the same snapshot and the same renderer as a single
    /// export; only the pixels and the measurements differ per file.
    func runBatch(_ urls: [URL], to folder: URL) {
        guard let snapshot = makeExportSnapshot(includeStamps: batchIncludeStamps,
                                                includeAnalysis: batchIncludeAnalysis) else {
            return
        }
        guard let token = begin(.batch) else {
            statusToken = .operationBusy
            return
        }
        batchGeneration += 1
        let batch = batchGeneration
        batchTask?.cancel()
        batchFileTask?.cancel()
        batchFileTask = nil

        let documentAspect = sourceAspect
        let documentURL = imageURL?.resolvingSymlinksInPath()
        let processor = self.processor
        let previewMaxDimension = self.previewMaxDimension
        let willWrite = batchFileWillWriteHook
        let writeResult = batchFileWriteResultOverride

        isBatchRunning = true
        batchTotal = urls.count
        batchCompleted = 0
        batchSavedCount = 0
        batchSkippedCrops = 0
        batchHasReport = false
        statusToken = .batchStarting

        batchTask = Task { [weak self] in
            var saved = 0
            var skipped = 0
            var completed = 0
            var cancelled = false
            for (index, url) in urls.enumerated() {
                if Task.isCancelled {
                    cancelled = true
                    break
                }
                self?.statusToken = .batchProgress(index + 1, urls.count)

                let fileTask = Task.detached(priority: .userInitiated) { () -> BatchOutcome in
                    Self.exportOne(url, to: folder, snapshot: snapshot,
                                   documentAspect: documentAspect,
                                   documentURL: documentURL,
                                   processor: processor,
                                   previewMaxDimension: previewMaxDimension,
                                   willWrite: willWrite,
                                   writeResult: writeResult)
                }
                if let self, self.batchGeneration == batch {
                    self.batchFileTask = fileTask
                }
                let outcome = await fileTask.value
                if let self, self.batchGeneration == batch, self.batchFileTask == fileTask {
                    self.batchFileTask = nil
                }

                switch outcome {
                case .cancelled:
                    cancelled = true
                case .failed:
                    break
                case .exported(let skippedCrop):
                    saved += 1
                    if skippedCrop { skipped += 1 }
                }
                if cancelled || Task.isCancelled { break }

                completed = index + 1
                if let self, self.batchGeneration == batch {
                    self.batchCompleted = completed
                    self.batchSavedCount = saved
                    self.batchSkippedCrops = skipped
                }
            }

            guard let self, self.batchGeneration == batch else { return }
            self.batchFileTask = nil
            self.batchTask = nil
            self.isBatchRunning = false
            self.batchHasReport = true
            let wasCancelled = cancelled || Task.isCancelled
            self.end(token)
            if wasCancelled {
                self.statusToken = .batchCancelled
            } else {
                self.statusToken = .batchFinished(saved: saved, total: urls.count,
                                                  cropsSkipped: skipped)
            }
        }
    }

    /// One file of a batch job, off the main actor. Every input that describes
    /// geometry comes from this file: its own load, its own masks and faces,
    /// its own aspect. The document's crop is used only when the shape matches.
    private nonisolated static func exportOne(_ url: URL,
                                              to folder: URL,
                                              snapshot: ExportSnapshot,
                                              documentAspect: CGFloat,
                                              documentURL: URL?,
                                              processor: ImageProcessor,
                                              previewMaxDimension: CGFloat,
                                              willWrite: (@Sendable (URL) -> Void)?,
                                              writeResult: (@Sendable (URL) -> Bool?)?) -> BatchOutcome {
        // A cancelled batch must stop before loading or rendering the next
        // photo, not after it has already paid for both.
        if Task.isCancelled { return .cancelled }
        let fileAspect = ExportService.pixelAspect(of: url) ?? 0
        var fileSnapshot = BatchExportPolicy.snapshot(
            snapshot, fileURL: url, documentURL: documentURL,
            documentAspect: documentAspect, fileAspect: fileAspect)
        let skippedCrop = snapshot.crop != nil && fileSnapshot.crop == nil

        guard let result = processor.load(from: url,
                                          previewMaxDimension: previewMaxDimension,
                                          crop: fileSnapshot.crop,
                                          orientation: fileSnapshot.orientation) else {
            return .failed
        }
        if Task.isCancelled { return .cancelled }
        // Each file builds its own set inside the renderer, one file at a time.
        let source = ExportSource(image: result.sourceFull,
                                  masks: nil,
                                  faces: result.faces,
                                  photoAspect: fileAspect,
                                  colorSpace: result.colorSpace,
                                  metadata: result.metadata)
        // Upscaling was decided for the document. A file that already reaches
        // the requested size does not need it, and one past the 4x ceiling is
        // written at its own size rather than failing the whole batch.
        if fileSnapshot.aiUpscale {
            let longest = max(result.pixelSize.width, result.pixelSize.height)
            if longest >= (fileSnapshot.longEdge ?? 0)
                || !ExportUpscale.canHandle(result.pixelSize) {
                fileSnapshot.aiUpscale = false
            }
        }
        guard let rendered = try? ExportService.renderFinal(fileSnapshot, source: source) else {
            return .failed
        }
        if Task.isCancelled { return .cancelled }
        let out = uniqueOutputURL(for: url, in: folder, format: fileSnapshot.format)
        willWrite?(out)
        // The hook and the write are the last two steps, so a cancellation that
        // lands here leaves no file at all rather than a truncated one.
        if Task.isCancelled { return .cancelled }
        let saved = writeResult?(out) ?? ExportService.write(
            rendered, snapshot: fileSnapshot, to: out,
            colorSpace: fileSnapshot.aiUpscale
                ? ExportUpscale.workingColorSpace
                : result.colorSpace,
            metadata: result.metadata,
            protecting: url)
        // A file that produced no export is a failure, not a skipped crop.
        guard saved else { return .failed }
        return .exported(skippedCrop: skippedCrop)
    }

    private nonisolated static func uniqueOutputURL(for url: URL,
                                                    in folder: URL,
                                                    format: ExportFormat) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        var out = folder.appendingPathComponent("\(base)-retouched.\(format.fileExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: out.path) {
            out = folder.appendingPathComponent("\(base)-retouched-\(counter).\(format.fileExtension)")
            counter += 1
        }
        return out
    }
}

private enum BatchOutcome {
    case exported(skippedCrop: Bool)
    case failed
    /// The file stopped before writing anything, so it is not a failure and not
    /// a saved photo.
    case cancelled
}

/// State of the subject silhouette Body and Background rely on.
enum SubjectMaskState {
    case unknown
    case detecting
    case available
    /// Vision found no subject; the two scene tools have nothing to separate.
    case unavailable
}

import Foundation
import StudioCore

/// Every user-facing string in the app, kept in one table so the copy stays
/// consistent and is easy to audit.
///
/// A class rather than a struct so `PersianL10n` can override every line and
/// the app can swap the whole table at once.
class L10n {
    static let shared = L10n()

    /// The table the app is speaking right now.
    static var current: L10n {
        AppLanguage.current == .persian ? PersianL10n.table : shared
    }

    // App / general
    var appName: String { "Retouch Studio" }
    var edited: String { "Edited" }
    var noImageOpen: String { "No image open" }
    var noImageSelected: String { "No image selected" }

    // Toolbar
    var open: String { "Open" }
    var export: String { "Export" }
    var reset: String { "Reset" }
    var compare: String { "Compare" }
    var faceBox: String { "Face Box" }
    var openHelp: String { "Open an image (⌘O)" }
    var exportHelp: String { "Save the retouched image (⌘E)" }
    var resetHelp: String { "Reset all adjustments (⌘R)" }
    var compareHelp: String { "Show the before/after comparison (hold Space to see the original)" }
    var faceBoxHelp: String { "Show the detected face box and regions" }

    // Sections
    var auto: String { "Auto" }
    var presets: String { "Presets" }
    var myLooks: String { "My Looks" }
    var lookNamePrompt: String { "Name this look" }
    var saveLook: String { "Save" }
    var presetSaved: String { "Saved look" }
    var deleteLookHelp: String { "Delete this look" }
    var noLooksYet: String { "Nothing saved yet. Set the sliders, then name the look here." }
    var faceDetection: String { "Face Detection" }
    var skin: String { "Skin" }
    var reshape: String { "Reshape" }
    var faceDetail: String { "Face Detail" }
    var colorLight: String { "Color & Light" }
    var exportSection: String { "Export" }

    // Auto
    var autoColorLight: String { "Auto Color & Light" }
    var autoRetouch: String { "Auto Retouch" }
    var autoColorLightHelp: String {
        "Scales how much of the measured color and light fix is applied: levels, exposure, contrast, color, warmth and clarity."
    }
    var autoRetouchHelp: String {
        "Scales how much of the measured skin fix is applied: smoothing, blemishes, lines, tone, teeth and eyes."
    }
    var teethNotVisible: String {
        "Teeth aren't visible in this photo, so whitening has nothing to target."
    }

    // Sliders
    var skinSmoothing: String { "Skin Smoothing" }
    var skinBrightness: String { "Skin Brightness" }
    var blemishRemoval: String { "Blemish Removal" }
    var teethWhitening: String { "Teeth Whitening" }
    var eyeBrightness: String { "Eye Brightness" }
    var eyeSharpen: String { "Eye Sharpen" }
    var exposure: String { "Exposure" }
    var contrast: String { "Contrast" }
    var blacks: String { "Blacks" }
    var whites: String { "Whites" }
    var saturation: String { "Saturation" }
    var vibrance: String { "Vibrance" }
    var warmth: String { "Warmth" }
    var clarity: String { "Clarity" }
    var vignette: String { "Vignette" }
    var texturePreserve: String { "Texture Preserve" }
    var wrinkleReduction: String { "Wrinkle Reduction" }
    var skinTone: String { "Even Skin Tone" }
    var darkCircles: String { "Dark Circles" }
    var eyeSize: String { "Eye Size" }
    var noseSize: String { "Nose Width" }
    var noseTip: String { "Nose Tip" }
    var lipSize: String { "Lip Size" }
    var cheekSize: String { "Cheeks" }
    var jawWidth: String { "Jawline" }
    var chinLength: String { "Chin" }
    var faceWidth: String { "Face Width" }
    var faceLength: String { "Face Length" }
    var reshapeScope: String {
        "Shapes facial features only."
    }
    var skinFinish: String { "Skin Finish" }
    var shine: String { "Shine Control" }
    var irisEnhance: String { "Iris Detail" }
    var lashDarken: String { "Lash Depth" }
    var lensTint: String { "Contact Lens" }
    var lensColor: String { "Lens Color" }
    var teethAlign: String { "Teeth Alignment" }
    var lipGloss: String { "Lip Gloss" }
    var hairShine: String { "Hair Shine" }
    var hairVolume: String { "Hair Volume" }
    var splitTone: String { "Split Tone" }

    // Curve and HSL
    var toneCurve: String { "Tone Curve" }
    var curveShadows: String { "Shadows" }
    var curveMidtones: String { "Midtones" }
    var curveHighlights: String { "Highlights" }
    var curveNote: String {
        "Drag a point to lift or lower that part of the tonal range. The curve works on brightness only, so colours stay put."
    }
    var hsl: String { "HSL" }
    var luminance: String { "Luminance" }
    var hslNote: String {
        "Targets one colour family at a time. Bands overlap smoothly, so a colour between two of them is shared, never cut in half."
    }

    // Body and background
    var bodySmoothing: String { "Body Smoothing" }
    var bodyBrightness: String { "Body Brightness" }
    var bodySlim: String { "Body Slim" }
    var bodyWaist: String { "Waist" }
    var bodyArms: String { "Arms" }
    var bodyLegs: String { "Legs" }
    var poseScope: String {
        "Waist, arms and legs follow the joints Vision finds, so each move narrows the body part it names instead of the whole frame."
    }
    var poseMissing: String {
        "No shoulders or hips were found in this photo, so Waist, Arms and Legs have nothing to anchor to."
    }
    /// A pose can exist and still miss the pairs a given slider needs; these
    /// say which group is waiting, instead of leaving that slider looking
    /// broken.
    var poseMissingWaist: String {
        "Hips and shoulders were not both found, so Waist has nothing to anchor to."
    }
    var poseMissingArms: String {
        "No shoulder and elbow pair was found, so Arms has nothing to anchor to."
    }
    var poseMissingLegs: String {
        "No hip and knee pair was found, so Legs has nothing to anchor to."
    }
    var backgroundBlur: String { "Background Blur" }
    var backgroundTone: String { "Background Tone" }
    var backgroundSaturation: String { "Background Saturation" }
    var backgroundFill: String { "Background Fill" }
    var backgroundFillColor: String { "Fill Color" }
    var backgroundRemove: String { "Remove Background" }
    var backdropImageTitle: String { "Backdrop Image" }
    var chooseBackdrop: String { "Choose Image…" }
    var chooseBackdropMessage: String { "Choose an image for the background" }
    var backdropStrength: String { "Backdrop Strength" }
    var backdropClearHelp: String { "Remove the chosen backdrop" }
    var backdropNote: String {
        "The image is copied into the app, so the project still works if the original moves."
    }
    var backdropFailed: String { "That image could not be read as a backdrop." }
    var backgroundRemoveNote: String {
        "Removal makes the background transparent. PNG and TIFF keep that; JPEG writes it onto white."
    }
    var bodyScope: String {
        "Reads the subject Vision finds, so it works on full-length photos where the face is small."
    }
    var backgroundScope: String {
        "Everything behind the subject is softened and graded; the subject edge is feathered so there is no cut-out halo."
    }
    var subjectDetecting: String { "Finding the subject…" }
    var subjectMissing: String {
        "No subject was found in this photo, so Body and Background have nothing to separate."
    }
    var resetGroupHelp: String { "Reset this section" }
    /// Makeup is one group spread over seven regions, so its glyph spells out
    /// what it actually clears.
    var resetMakeupHelp: String { "Reset lips, cheeks, contour, eyes, brows and hair" }

    // Makeup
    var makeupColor: String { "Color" }
    var makeupCustomColor: String { "Custom" }
    var pickColorHelp: String { "Pick any color" }
    var hue: String { "Hue" }
    var opacity: String { "Opacity" }
    var makeupNote: String {
        "Cosmetics keep the shading underneath them, so lips, cheeks, contour, eyes and hair stay three-dimensional."
    }
    var makeupNoFace: String {
        "No face has been detected, so there is nothing for makeup to color."
    }
    var undoHelp: String { "Undo (⌘Z)" }
    var redoHelp: String { "Redo (⇧⌘Z)" }
    var undoMenu: String { "Undo" }
    var redoMenu: String { "Redo" }
    var doubleClickHint: String {
        "Double-click a slider to reset just that effect"
    }
    /// The one-line explanation shown when a slider is hovered.
    func sliderHint(_ hint: SliderHint) -> String { hint.english }

    // Face status
    var noFaceDetected: String { "No face detected" }
    func facesDetected(_ n: Int) -> String {
        "\(Digits.num(n)) face\(n == 1 ? "" : "s") detected"
    }
    var faceToolsNeedFace: String {
        "Skin, teeth and eye tools have no effect until a face is detected."
    }
    var showFaceOverlay: String { "Show face box and regions" }
    var compareToggle: String { "Compare (before / after)" }

    // Status messages
    var dropHint: String { "Drop a photo here, or click Open." }
    var readingImage: String { "Reading image…" }
    var couldNotRead: String {
        "Could not read that file. Choose a valid image."
    }
    var noFaceColorOnly: String {
        "No face found — only the Color & Light tools apply."
    }
    var analyzingColor: String { "Analyzing color and light…" }
    var analyzingSkin: String { "Analyzing skin and face…" }

    // Auto Retouch readout: what the analyzer actually measured, so a photo that
    // needed almost nothing says that instead of looking broken.
    var autoSaidLightSmoothing: String { "light smoothing" }
    var autoSaidSmoothing: String { "texture softened" }
    func autoSaidBlemishes(_ n: Int) -> String {
        n == 1 ? "1 blemish healed" : "\(Digits.num(n)) blemishes healed"
    }
    var autoSaidLines: String { "fine lines reduced" }
    var autoSaidDarkCircles: String { "under-eye lifted" }
    var autoSaidTone: String { "tone evened" }
    var autoSaidBrighter: String { "skin brightened" }
    var autoSaidTeeth: String { "teeth whitened" }
    var autoSaidEyes: String { "eyes brightened" }
    var autoSaidClean: String { "nothing to correct — this skin is already clean" }
    func autoRetouchReport(_ measures: [String]) -> String {
        "Auto Retouch: " + (measures.isEmpty ? [autoSaidClean] : measures).joined(separator: ", ") + "."
    }
    var renderingExport: String { "Rendering full-quality export…" }
    func upscaling(_ done: Int, _ total: Int) -> String {
        "Upscaling \(Digits.num(done)) of \(Digits.num(total)) tiles…"
    }
    func saved(_ name: String) -> String { "Saved \(name)" }
    var exportFailed: String { "Could not save the export." }
    var exportRefusedOriginal: String {
        "That is the photo you are editing. Choose a different name or folder."
    }
    var exportCancelled: String { "Export cancelled." }
    var cancelExport: String { "Cancel Export" }
    var operationBusy: String {
        "Another operation is still running — try again when it finishes."
    }

    // Unsaved changes
    var unsavedTitle: String { "Discard unsaved adjustments?" }
    var unsavedMessage: String {
        "This photo has edits that haven't been saved to a project or exported. If you continue, they will be lost."
    }
    var discardChanges: String { "Discard Changes" }
    /// Offered in the unsaved-changes alert, so closing is never a choice
    /// between losing the work and cancelling.
    var saveBeforeClosing: String { "Save Project" }

    // Projects
    var saveProjectMenu: String { "Save Project" }
    var saveProjectAsMenu: String { "Save Project As…" }
    var openProjectMenu: String { "Open Project…" }
    var chooseProjectLocation: String { "Choose where to save the project" }
    var chooseProject: String { "Choose a Retouch Studio project" }
    func projectSaved(_ name: String) -> String { "Saved project \(name)" }
    var projectSaveFailed: String { "Could not save the project." }
    var projectOpened: String { "Project restored." }
    var projectOpenFailed: String { "Could not open that project." }
    var projectPhotoMissing: String {
        "The photo this project refers to is no longer at that path."
    }
    var projectLocateTitle: String { "Locate Photo" }
    func projectLocateMessage(_ name: String) -> String {
        "Choose where \u{201C}\(name)\u{201D} is now. The project will remember the new place."
    }
    func projectTooNew(_ version: Int) -> String {
        "This project was written by a newer version of the app (v\(Digits.num(version)))."
    }
    var projectRelinked: String { "Project opened and the photo's new location was saved." }
    var recoveryStorageFailed: String {
        "Recovery could not be updated. The unsaved work is not protected for the next launch."
    }
    func recoveryQuarantined(_ count: Int) -> String {
        count == 1
            ? "A damaged recovery copy was set aside instead of deleted."
            : "\(Digits.num(count)) damaged recovery copies were set aside instead of deleted."
    }
    var recoveryCandidateNotRemoved: String {
        "The recovered photo is saved, but its old recovery copy could not be removed."
    }
    func recoveryNeedsNewerBuild(_ features: [String]) -> String {
        let list = features.joined(separator: ", ")
        return list.isEmpty
            ? "A recovery copy needs a newer version of the app."
            : "A recovery copy needs a newer version of the app (\(list))."
    }

    // Batch
    var batchExportMenu: String { "Batch Export…" }
    var batchChoosePhotos: String { "Choose photos to export" }
    var batchChooseFolder: String { "Choose a folder for the exported photos" }
    var batchStarting: String { "Starting batch export…" }
    func batchProgress(_ index: Int, _ total: Int) -> String {
        "Exporting \(Digits.num(index)) of \(Digits.num(total))…"
    }
    func batchFinished(_ saved: Int, _ total: Int, cropsSkipped: Int, failed: Int) -> String {
        let savedText = saved == total
            ? "\(Digits.num(saved)) photos saved"
            : "\(Digits.num(saved)) of \(Digits.num(total)) photos saved"
        let skippedText = cropsSkipped > 0
            ? " · \(Digits.num(cropsSkipped)) crops skipped (different shape)"
            : ""
        let failedText = failed > 0 ? " · \(Digits.num(failed)) failed" : ""
        return "Batch export finished: \(savedText)\(skippedText)\(failedText)."
    }
    var batchCancelled: String { "Batch export cancelled." }
    var batchSheetTitle: String { "Batch Export" }
    func batchSelected(_ count: Int) -> String {
        count == 1 ? "1 photo selected" : "\(Digits.num(count)) photos selected"
    }
    var batchIncludeStamps: String { "Healing stamps and stickers" }
    var batchIncludeStampsDetail: String {
        "Only right when the other photos share this photo's blemishes."
    }
    var batchIncludeAnalysis: String { "Analysis overlay" }
    var batchIncludeAnalysisDetail: String { "Callouts follow each photo's own face." }
    var batchStart: String { "Start Export" }
    var batchDone: String { "Done" }

    // Crop
    var applyingCrop: String { "Applying crop…" }
    var cropApplied: String { "Crop applied." }
    var cropReset: String { "Crop reset to the original framing." }
    var rotated: String { "Photo rotated." }
    var flipped: String { "Photo flipped." }
    var straightened: String { "Straighten applied." }
    var orientationLabel: String { "Orientation" }
    var rotateLeft: String { "Left" }
    var rotateRight: String { "Right" }
    var flipHorizontal: String { "Flip" }
    var straightenLabel: String { "Straighten" }
    var levelAction: String { "Level" }

    // Healing brush
    var healCleared: String { "Healing stamps cleared." }
    var healSubtitle: String { "Click a blemish to heal it. Click a stamp to take it back." }
    func healStampAdded(_ count: Int) -> String {
        count == 1 ? "Healing stamp added — ⌘Z removes it." : "Healing stamps: \(Digits.num(count))."
    }
    var healStampRemoved: String { "Healing stamp removed." }

    // Stickers
    var artTitle: String { "Stickers" }
    var artSubtitle: String { "Place stickers and art on the photo" }
    var artShape: String { "Shape" }
    var artSize: String { "Size" }
    var artRotation: String { "Rotation" }
    var artDelete: String { "Delete Sticker" }
    var artDuplicate: String { "Duplicate" }
    var artClear: String { "Clear All Stickers" }
    var artDragResize: String { "Drag to resize" }
    var artDragRotate: String { "Drag to rotate" }
    var artNote: String {
        "Click the photo to place a sticker. Click one to select it, then drag it, or use its handles to resize and rotate."
    }
    var stickerRemoved: String { "Sticker removed." }
    var stickersCleared: String { "Stickers cleared." }
    func stickerAdded(_ count: Int) -> String {
        count == 1 ? "Sticker placed — ⌘Z removes it." : "Stickers: \(Digits.num(count))."
    }
    func stickerKindTitle(_ kind: StickerKind) -> String {
        switch kind {
        case .star: return "Star"
        case .heart: return "Heart"
        case .sparkle: return "Sparkle"
        case .flower: return "Flower"
        case .butterfly: return "Butterfly"
        case .lightning: return "Lightning"
        }
    }

    // Face analysis
    var analysisTitle: String { "Face Analysis" }
    var analysisSubtitle: String { "Landmarks, shapes and leader lines — no text" }
    var analysisEnable: String { "Show the analysis overlay" }
    var analysisStyle: String { "Style" }
    var analysisStyleOutline: String { "Dashed shapes" }
    var analysisStyleMesh: String { "Face mesh" }
    var analysisFaceOutline: String { "Face outline" }
    var analysisAreas: String { "Areas" }
    var analysisInk: String { "Line colour" }
    var analysisWeight: String { "Line weight" }
    var analysisStrength: String { "Line strength" }
    var analysisGlow: String { "Glow" }
    var analysisResetEnds: String { "Reset dots and ends" }
    var analysisDragEnd: String { "Drag a dot or an end to place it" }
    var analysisNote: String {
        "The picture carries no text. Drag the dot on the face to move where a line starts, and its end to choose where your label goes."
    }
    var analysisMeshNote: String {
        "In mesh mode the areas only choose which leader lines are drawn."
    }
    var analysisNoFace: String {
        "No face found. The analysis needs a clear, front-facing face."
    }
    var analysisNoLandmarks: String {
        "This face has no feature points. The dots and lines follow the face box."
    }
    var faceSelectionTitle: String { "Subject" }
    var faceSelectionAuto: String { "Auto" }
    func faceSelectionName(_ index: Int) -> String { "Face \(Digits.num(index + 1))" }
    var analysisExportSection: String { "Face analysis" }
    var analysisExportSectionHelp: String {
        "Chooses whether the face overlay is drawn on the export, and how."
    }
    var analysisExportMode: String { "Export as" }
    var analysisMargin: String { "Margin" }
    var analysisNeedsFace: String {
        "No face was detected, so the analysis cannot be drawn. This copy is saved as an ordinary photo."
    }

    func analysisRegionTitle(_ region: AnalysisRegion) -> String {
        switch region {
        case .forehead: return "Forehead"
        case .eyeArea: return "Eye area"
        case .underEye: return "Under-eye"
        case .brows: return "Brows"
        case .texture: return "Texture"
        case .pigmentation: return "Pigmentation"
        case .jawline: return "Jawline"
        case .lips: return "Lips"
        case .nose: return "Nose"
        case .chin: return "Chin"
        }
    }

    func analysisExportTitle(_ mode: AnalysisExportMode) -> String {
        switch mode {
        case .onPhoto: return "On the photo"
        case .poster: return "Poster with margin"
        case .overlayOnly: return "Lines only (PNG)"
        }
    }

    func analysisTintTitle(_ tint: AnalysisTint) -> String {
        switch tint {
        case .chalk: return "Chalk"
        case .lime: return "Lime"
        case .sky: return "Sky"
        case .ember: return "Ember"
        case .ink: return "Ink"
        }
    }

    // Drop zone
    var dropTitle: String { "Drop a portrait here" }
    var dropSubtitle: String {
        "Or use the button below — JPEG, PNG, HEIC and TIFF are supported"
    }
    var openImage: String { "Open Image" }
    var featureSmooth: String { "Smooth skin without blurring eyes or lips" }
    var featureBlemish: String { "Remove blemishes, brighten skin" }
    var featureTeeth: String { "Whiten teeth, brighten eyes" }
    var featureColor: String { "Full control of color, light, clarity and vignette" }
    var featureZoom: String { "Drag to move the photo, pinch or ⌘-scroll to zoom" }

    // Canvas controls
    var fit: String { "Fit" }
    var zoomOut: String { "Zoom out (⌘−)" }
    var zoomIn: String { "Zoom in (⌘+)" }
    var fitToWindow: String { "Fit to window (⌘0 or double-click)" }
    var canvasHelp: String {
        "Drag to pan • pinch or ⌘-scroll to zoom • double-click for 100% • hold Space for the original"
    }
    var before: String { "Before" }
    var after: String { "After" }

    // Export sheet
    var format: String { "Format" }
    var formatHelp: String { "Chooses the file type for the export." }
    var quality: String { "Quality" }
    var exportLongEdge: String { "Long edge" }
    var exportLongEdgeHelp: String {
        "Caps the longest side. Original keeps the photo at its own size."
    }
    var exportOriginal: String { "Original" }
    func exportSize(_ info: String) -> String { "Output: \(info)" }
    func originalSize(_ info: String) -> String { "Original size: \(info)" }
    func suggestedName(_ name: String) -> String { "Suggested name: \(name)" }
    var exportUpscale: String { "AI upscale 4×" }
    var exportUpscaleDetail: String {
        "Adds detail with the local Swin2SR model, then trims to the chosen edge. Nothing leaves this Mac."
    }
    var exportUpscaleTooLarge: String {
        "This photo is too large for a 4× pass. The limit is 40 MP of output, about 2.5 MP in."
    }
    func exportUpscaleEstimate(_ seconds: Int) -> String {
        let minutes = max(1, Int((Double(seconds) / 60).rounded()))
        return "About \(Digits.num(minutes)) min on this Mac."
    }
    var exportUpscaleUnavailable: String {
        "The local AI helper is not installed, so the standard resampler is used."
    }
    var exportUpscaleFailed: String { "The upscaler could not finish." }
    var cancel: String { "Cancel" }
    var save: String { "Save…" }
    var saveExport: String { "Save Export…" }
    var exportFullQuality: String {
        "Exports are always written at the full quality and size of the original."
    }
    var watermarkSection: String { "Watermark" }
    var watermarkText: String { "Text" }
    var watermarkTextPlaceholder: String { "Name or ©" }
    var watermarkOpacity: String { "Opacity" }
    var watermarkSize: String { "Size" }
    var watermarkNote: String {
        "Drawn on saved copies only; the editor preview stays clean."
    }
    func watermarkPosition(_ position: WatermarkSettings.Position) -> String {
        switch position {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        case .center: return "Center"
        }
    }
    var histogramLabel: String { "Histogram" }

    // Menus
    var retouchMenu: String { "Retouch" }
    var languageMenu: String { "Language" }
    var openMenu: String { "Open Image…" }
    var closeWindow: String { "Close Window" }
    var exportMenu: String { "Export…" }
    var resetMenu: String { "Reset All Adjustments" }
    var showCompareMenu: String { "Show Compare" }
    var showFaceOverlayMenu: String { "Show Face Overlay" }
    var zoomInMenu: String { "Zoom In" }
    var zoomOutMenu: String { "Zoom Out" }
    var fitMenu: String { "Fit to Window" }

    // MARK: - Smart Analyze

    var smartAnalyze: String { "Smart Analyze" }
    var smartSubtitle: String { "Reads the face, then proposes the fixes." }
    var smartAction: String { "Analyze" }
    var smartReview: String { "Review Report" }
    var smartHelp: String {
        "Measures skin texture, blemishes, lines, under-eye shadows, shine, uneven tone, teeth and eyes, then shows the findings before anything changes. (⇧⌘A)"
    }
    var smartSheetTitle: String { "What this photo needs" }
    var smartSheetSubtitle: String {
        "Nothing has changed yet. Switch off anything you don't want, then apply."
    }
    var smartPhotoSection: String { "COLOR & LIGHT" }
    var smartFaceSection: String { "FACE" }
    var smartFindings: String { "Findings" }
    var smartNothingFound: String { "Nothing stood out — this photo is already in good shape." }
    var smartApplyRetouch: String { "Retouch sliders" }
    var smartApplyColor: String { "Color & light" }
    var smartApplyHeal: String { "Heal detected spots" }
    var smartNoSpots: String { "No isolated blemishes found" }
    func smartSpotCount(_ n: Int) -> String {
        n == 1 ? "1 spot will be healed" : "\(Digits.num(n)) spots will be healed"
    }
    var smartApply: String { "Apply Suggestions" }
    var smartCancel: String { "Cancel" }
    var analyzingSmart: String { "Reading the face…" }
    var smartFailed: String { "Could not analyze this photo." }
    var smartReady: String { "Analysis ready — review what was found." }
    var smartApplied: String { "Smart suggestions applied." }
    func smartAppliedReport(_ measures: [String]) -> String {
        "Applied: " + measures.joined(separator: ", ") + "."
    }
    func smartSummary(_ findings: Int, _ faces: Int) -> String {
        findings == 1
            ? "1 finding on \(Digits.num(faces)) face\(faces == 1 ? "" : "s")"
            : "\(Digits.num(findings)) findings on \(Digits.num(faces)) face\(faces == 1 ? "" : "s")"
    }
    var smartNoFace: String {
        "No face detected. Smart Analyze still reads color and light, but skin tools need a face."
    }

    // MARK: - Settings, About, Help

    var settingsTitle: String { "Settings" }
    /// macOS titles this window itself, in the system language. The app writes
    /// its own so the title bar follows the switch like the rest of the text.
    var settingsWindowTitle: String { "\(appName) \(settingsTitle)" }
    var settingsLanguage: String { "LANGUAGE" }
    var settingsLanguageHelp: String { "Choose the language of the interface." }
    var settingsAuto: String { "AUTO" }
    var settingsAutoNote: String {
        "How much of each measured fix Smart Analyze applies."
    }
    var settingsExport: String { "EXPORT" }
    var settingsExportHelp: String {
        "File format, quality and metadata for saved copies."
    }
    var settingsStripMetadata: String { "Remove identifying image metadata" }
    var settingsStripMetadataNote: String {
        "Leaves GPS, camera make and model, serial numbers, creator, capture time and other identifying details out of exports. Orientation, resolution and colour profile are kept."
    }
    var settingsTools: String { "TOOLS" }
    var settingsToolsHelp: String { "Healing brush size and the face overlay." }
    var settingsRecovery: String { "RECOVERY" }
    var settingsRecoveryToggle: String { "Keep a recovery copy of unsaved work" }
    var settingsRecoveryNote: String {
        "Survives a crash or a force quit. Cleared as soon as the photo is saved or exported."
    }
    var settingsFaceOverlay: String { "Show face box and regions" }
    var settingsBrush: String { "Healing brush size" }
    var settingsReset: String { "Restore Defaults" }
    var settingsResetNote: String {
        "Resets the starting values. The photo that is open keeps its current sliders."
    }
    var settingsResetStatus: String { "Preferences reset to defaults." }

    // AI models
    var settingsModels: String { "AI MODELS" }
    var settingsModelsNote: String {
        "Downloading a model needs the internet once; after that every tool runs offline."
    }
    var settingsModelsManage: String { "Manage Models…" }
    var modelsTitle: String { "AI Models" }
    var modelsOfflineNote: String {
        "Models run on this Mac. Nothing is uploaded, and no model is downloaded without your approval."
    }
    var modelsInstalled: String { "Installed" }
    var modelsMissing: String { "Not installed" }
    var modelsDownload: String { "Download…" }
    var modelsDownloadAgain: String { "Download again…" }
    var modelsVerify: String { "Verify" }
    var modelsRemove: String { "Remove…" }
    var modelsClose: String { "Done" }
    var modelsChecking: String { "Checking…" }
    var modelsVerified: String { "Checksums match." }
    func modelsVerifyFailed(_ file: String) -> String { "Checksum mismatch: \(file)" }
    func modelsDownloadTitle(_ name: String) -> String { "Download \(name)?" }
    func modelsDownloadBody(files: Int, size: String, license: String) -> String {
        let count = files == 1 ? "1 file" : "\(files) files"
        return "\(count), \(size). License: \(license). This is the only step that uses the internet."
    }
    var modelsDownloadAction: String { "Download" }
    var modelsCancel: String { "Cancel" }
    func modelsDownloading(_ percent: Int) -> String { "Downloading… \(percent)%" }
    var modelsDownloadingUnknown: String { "Downloading…" }
    func modelsDownloaded(_ name: String) -> String { "\(name) is installed." }
    var modelsDownloadCancelled: String { "Download cancelled. Nothing was installed." }
    var modelsDownloadFailed: String { "The download did not finish. Nothing was installed." }
    func modelsRemoveTitle(_ name: String) -> String { "Remove \(name)?" }
    var modelsRemoveBody: String {
        "The model files are deleted from this Mac. You can download them again later."
    }
    var modelsRemoveAction: String { "Remove" }
    func modelsRemoved(_ name: String) -> String { "\(name) was removed." }
    var modelsSizeUnknown: String { "Size unknown" }
    var modelsHelperMissing: String { "The AI helper is not available on this Mac." }

    var aiRuntimeTitle: String { "AI runtime" }
    var aiRuntimeInstalledChip: String { "Installed" }
    var aiRuntimeMissingChip: String { "Not installed" }
    var aiRuntimeBody: String {
        "The AI tools need a local helper runtime, about 390 MB. The app downloads it only after showing the file, its size and its SHA256 and receiving your approval."
    }
    var aiRuntimeInstall: String { "Download runtime" }
    var aiRuntimeDownloadTitle: String { "Download the AI runtime?" }
    func aiRuntimeDownloadBody(file: String, size: String, hash: String) -> String {
        "This downloads \(file) (\(size)) from github.com and verifies its SHA256 (\(hash)) before installing it. Model weights are still downloaded separately, after their own approval."
    }
    var aiRuntimeDownloading: String { "Downloading the runtime…" }
    var aiRuntimeVerifying: String { "Verifying the download…" }
    var aiRuntimeInstalling: String { "Installing the runtime…" }
    var aiRuntimeDownloadFailed: String { "The runtime did not download. Nothing was installed." }
    var aiRuntimeChecksumFailed: String {
        "The downloaded file did not match its SHA256. Nothing was installed."
    }
    var aiRuntimeExtractFailed: String { "The runtime could not be unpacked. Nothing was installed." }
    var aiRuntimeInstallFailed: String {
        "The runtime could not be installed. The previous runtime was kept."
    }
    var aiRuntimeInstallFailedNothing: String {
        "The runtime could not be installed. No previous runtime was replaced."
    }
    var aiRuntimeInstallFailedRollback: String {
        "The runtime could not be installed, and the previous runtime could not be restored. Download it again in Settings."
    }
    var aiRuntimeInstallFailedPreserved: String {
        "The runtime could not be installed. The previous runtime was preserved for recovery and will be retried."
    }
    var aiRuntimeRecoveryFailed: String {
        "The AI runtime could not be recovered safely. Existing runtime files were preserved; restart the app to retry, or download the runtime again in Settings."
    }
    var aiRuntimeValidationFailed: String {
        "The installed AI runtime did not pass its startup check. Restart the app to retry, or download the runtime again in Settings."
    }
    var aiRuntimeBusy: String {
        "The AI runtime is in use by another Retouch Studio window. Close it, then try again."
    }
    var aiRuntimeInstalledNote: String { "Installed — models can be downloaded now." }
    var aiRuntimeNotInstalled: String {
        "The AI runtime is not installed. Download it in Settings → AI models, then try again."
    }
    var aiRuntimeIntelUnavailable: String {
        "The AI helper runs only on Apple silicon. This Intel Mac uses the full editor without AI."
    }
    var aiRuntimeUnavailable: String {
        "The AI helper is not available in this build yet. The rest of the editor works without it."
    }
    var aiHelperStarting: String {
        "The AI helper is still starting. Try again in a moment."
    }
    func modelsTaskName(_ task: String) -> String {
        switch task {
        case "segmentation": return "Selection"
        case "upscaling": return "Upscaling"
        case "inpainting": return "Healing"
        case "generative-edit": return "Object removal"
        default: return task
        }
    }
    func modelsUsedFor(_ action: String) -> String { "Used for: \(action)" }
    var modelsInUse: String { "In use" }
    var modelsNeverUsed: String { "Not used yet" }
    func modelsLastUsed(_ when: String) -> String { "Last used: \(when)" }
    var modelsJustNow: String { "just now" }
    func modelsMinutesAgo(_ count: Int) -> String {
        count == 1 ? "1 minute ago" : "\(count) minutes ago"
    }
    func modelsHoursAgo(_ count: Int) -> String {
        count == 1 ? "1 hour ago" : "\(count) hours ago"
    }
    func modelsDaysAgo(_ count: Int) -> String {
        count == 1 ? "1 day ago" : "\(count) days ago"
    }

    var aboutTitle: String { "About Retouch Studio" }
    var aboutTagline: String { "Portrait retouching, measured." }
    var aboutDescription: String {
        "Retouch Studio is a local-first portrait retoucher for macOS. It measures the photo first — skin, eyes, teeth, hair, light and framing — so automatic edits only move what the measurements justify, then puts twelve tools in your hands: skin, healing, reshape, eyes and teeth, makeup, colour and light, looks, crop, body, background, stickers and analysis. Every change is non-destructive: undo it, save the session as a .retouch project, or export at full quality."
    }
    var aboutVersion: String { "Version" }
    var updateCheck: String { "Check for Updates" }
    var updateChecking: String { "Checking for updates…" }
    var updateUpToDate: String { "You have the newest version." }
    var updateAvailable: String { "Version %@ is available." }
    var updateIncompatible: String { "This update cannot be installed here: %@" }
    var updateFailed: String { "The update check failed: %@" }
    var updateFeedMissing: String { "This build has no update feed configured." }
    var updateDownloading: String { "Downloading and verifying version %@…" }
    var updateReady: String { "Version %@ is installed. Relaunch to use it." }
    var updateInstall: String { "Download & Install" }
    var updateRelaunch: String { "Relaunch" }
    var aboutDeveloper: String { "Developer" }
    var aboutDeveloperRole: String { "Role" }
    var aboutDeveloperRoleValue: String { "Design and development" }
    var aboutContact: String { "Contact" }
    var aboutWebsite: String { "Website" }
    var aboutCopyright: String { "Copyright" }
    var aboutRights: String { "All rights reserved." }
    var aboutEngine: String {
        "Everything runs on this Mac — no account, no upload and no telemetry. Built with SwiftUI, Core Image and Vision; the optional AI helper runs on Apple silicon."
    }
    var settingsDeveloper: String { "DEVELOPER" }
    var settingsDeveloperHelp: String { "Who built the app, and the running version." }
    var helpTitle: String { "Retouch Studio Help" }
    var helpIntro: String {
        "Open a portrait, read it with Smart Analyze, then fine-tune by hand. Everything runs on this Mac — no photos are uploaded."
    }
    var helpWorkflow: String { "WORKFLOW" }
    var helpShortcuts: String { "KEYBOARD" }
    var helpWorkflowSteps: [String] {
        ["Open or drop a photo.",
         "Press Smart Analyze to see what the face needs.",
         "Apply the suggestions, then adjust the sliders.",
         "Save the project, or export the finished image."]
    }
    var helpShortcutRows: [(String, String)] {
        [("⌘O", "Open an image"),
         ("⇧⌘O", "Open a project"),
         ("⌘S / ⇧⌘S", "Save project / Save project as"),
         ("⌘E / ⇧⌘E", "Export / Batch export"),
         ("⇧⌘A", "Smart Analyze"),
         ("⌘R", "Reset all adjustments"),
         ("⌘Z / ⇧⌘Z", "Undo / Redo"),
         ("⌘,", "Settings"),
         ("⌘+ / ⌘− / ⌘0", "Zoom in / out / fit"),
         ("1–0", "Pick a tool"),
         ("[ / ]", "Healing brush size"),
         ("Space", "Hold to see the original")]
    }

    // MARK: - Recent files and recovery

    var openRecentMenu: String { "Open Recent" }
    var openRecentEmpty: String { "No Recent Files" }
    var clearRecentMenu: String { "Clear Menu" }
    func recentMissing(_ name: String) -> String { "\(name) is no longer at that location." }
    var recoveryTitle: String { "Reopen unsaved work?" }
    func recoveryMessage(_ name: String) -> String {
        "Retouch Studio found edits to \(name) that were never saved, left behind when the app closed unexpectedly."
    }
    func recoveryChangedMessage(_ name: String) -> String {
        "\(name) changed on disk after these edits were saved. Restoring applies the edits to the photo as it is now."
    }
    var recoveryRestore: String { "Restore Edits" }
    var recoveryDiscard: String { "Discard" }

    // MARK: - Named things
    //
    // Presets, tools and regions are enums with a name each. The name lives
    // here rather than on the enum so one switch covers every case in both
    // languages and a new case cannot slip through untranslated.

    /// Puts a status event into words. Every piece already lives in the table,
    /// so this only chooses the sentence — which is what lets the status line
    /// be re-read in the new language instead of keeping the old one.
    func statusText(_ token: StatusToken) -> String {
        switch token {
        case .none: return ""
        case .facesDetected(let count): return facesDetected(count)
        case .noFaceColorOnly: return noFaceColorOnly
        case .dropHint: return dropHint
        case .readingImage: return readingImage
        case .couldNotRead: return couldNotRead
        case .projectOpened: return projectOpened
        case .applyingCrop: return applyingCrop
        case .cropReset: return cropReset
        case .cropApplied: return cropApplied
        case .rotated: return rotated
        case .flipped: return flipped
        case .straightened: return straightened
        case .healCleared: return healCleared
        case .healStampRemoved: return healStampRemoved
        case .healStampAdded(let count): return healStampAdded(count)
        case .stickerAdded(let count): return stickerAdded(count)
        case .stickerRemoved: return stickerRemoved
        case .stickersCleared: return stickersCleared
        case .presetSaved(let name): return "\(presetSaved): \(name)"
        case .analyzingSmart: return analyzingSmart
        case .smartFailed: return smartFailed
        case .smartReady: return smartReady
        case .smartApplied: return smartApplied
        case .smartAppliedReport(let measures): return smartAppliedReport(measures)
        case .aiWorking: return aiWorking
        case .aiApplied: return aiApplied
        case .aiAssetsMissing(let count): return aiAssetsMissing(count)
        case .settingsReset: return settingsResetStatus
        case .backdropFailed: return backdropFailed
        case .recentMissing(let name): return recentMissing(name)
        case .renderingExport: return renderingExport
        case .upscaling(let done, let total): return upscaling(done, total)
        case .saved(let name): return saved(name)
        case .exportFailed: return exportFailed
        case .exportRefusedOriginal: return exportRefusedOriginal
        case .exportCancelled: return exportCancelled
        case .operationBusy: return operationBusy
        case .projectSaved(let name): return projectSaved(name)
        case .projectSaveFailed: return projectSaveFailed
        case .projectPhotoMissing: return projectPhotoMissing
        case .projectOpenFailed: return projectOpenFailed
        case .projectTooNew(let version): return projectTooNew(version)
        case .projectRelinked: return projectRelinked
        case .recoveryStorageFailed: return recoveryStorageFailed
        case .recoveryQuarantined(let count): return recoveryQuarantined(count)
        case .recoveryCandidateNotRemoved: return recoveryCandidateNotRemoved
        case .recoveryNeedsNewerBuild(let features): return recoveryNeedsNewerBuild(features)
        case .batchStarting: return batchStarting
        case .batchProgress(let index, let total): return batchProgress(index, total)
        case .batchFinished(let saved, let total, let skipped, let failed):
            return batchFinished(saved, total, cropsSkipped: skipped, failed: failed)
        case .batchCancelled: return batchCancelled
        }
    }

    func toolTitle(_ tool: ToolMode) -> String {
        switch tool {
        case .skin: return "Skin"
        case .heal: return "Healing"
        case .reshape: return "Reshape"
        case .detail: return "Eyes & Teeth"
        case .makeup: return "Makeup"
        case .color: return "Color & Light"
        case .look: return "Looks"
        case .crop: return "Crop"
        case .body: return "Body"
        case .background: return "Background"
        case .art: return artTitle
        case .analysis: return analysisTitle
        }
    }

    func toolSubtitle(_ tool: ToolMode) -> String {
        switch tool {
        case .skin: return "Texture, tone and blemishes"
        case .heal: return "Stamp out blemishes by hand"
        case .reshape: return "Shape facial features"
        case .detail: return "Whiten teeth and brighten eyes"
        case .makeup: return "Lips, cheeks and brows"
        case .color: return "Exposure, color and light"
        case .look: return "Film grades and grain"
        case .crop: return "Reframe the photo"
        case .body: return "Smooth, tone and slim the figure"
        case .background: return "Blur and grade what is behind the subject"
        case .art: return artSubtitle
        case .analysis: return analysisSubtitle
        }
    }

    var presetsHint: String { "Starting points for skin, shape and color" }

    func panelTitle(_ panel: Panel) -> String {
        switch panel {
        case .presets: return "Presets"
        case .skin: return "Skin"
        case .shape: return "Shape"
        case .eyes: return "Eyes & Teeth"
        case .makeup: return "Makeup"
        case .color: return "Color & Light"
        case .looks: return "Looks"
        case .body: return "Body"
        case .background: return "Background"
        case .art: return artTitle
        case .analysis: return analysisTitle
        }
    }

    func lookTitle(_ look: FilmLook) -> String {
        switch look {
        case .none: return "None"
        case .warmGold: return "Warm Gold"
        case .portraitFilm: return "Portrait"
        case .nightStock: return "Night Stock"
        case .crossProcess: return "Cross Process"
        case .fadedMatte: return "Faded Matte"
        }
    }

    func makeupFamilyTitle(_ family: MakeupFamily) -> String {
        switch family {
        case .fair: return "Fair"
        case .light: return "Light"
        case .medium: return "Medium"
        case .tan: return "Tan"
        case .deep: return "Deep"
        }
    }

    func makeupRegionTitle(_ region: MakeupRegion) -> String {
        switch region {
        case .lips: return "Lips"
        case .cheeks: return "Cheeks"
        case .contour: return "Contour"
        case .shadow: return "Shadow"
        case .liner: return "Liner"
        case .brows: return "Brows"
        case .hair: return "Hair"
        }
    }

    func cropAspectTitle(_ aspect: CropAspect) -> String {
        switch aspect {
        case .free: return "Free"
        case .original: return "Original"
        case .square: return "1:1"
        case .portrait: return "4:5"
        case .wide: return "16:9"
        }
    }

    func hueBandTitle(_ band: HSLBand) -> String {
        switch band {
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .cyan: return "Cyan"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .magenta: return "Magenta"
        }
    }

    func presetGroupTitle(_ group: PresetGroup) -> String {
        switch group {
        case .everyday: return "Everyday"
        case .skin: return "Skin"
        case .beauty: return "Beauty"
        case .color: return "Color"
        case .film: return "Film"
        case .makeup: return "Makeup"
        }
    }

    func presetTitle(_ id: PresetID) -> String {
        switch id {
        case .natural: return "Natural"
        case .clean: return "Clean"
        case .fresh: return "Fresh"
        case .minimal: return "Barely There"
        case .softlight: return "Soft Light"
        case .airbrush: return "Airbrush"
        case .texture: return "Kept Texture"
        case .matte: return "Matte"
        case .glow: return "Dewy Glow"
        case .eventone: return "Even Tone"
        case .bronze: return "Bronze"
        case .porcelain: return "Porcelain"
        case .glamour: return "Glamour"
        case .studio: return "Studio"
        case .editorial: return "Editorial"
        case .beauty: return "Beauty"
        case .bridal: return "Bridal"
        case .sculpt: return "Sculpt"
        case .male: return "Masculine"
        case .warmsun: return "Warm Sun"
        case .cool: return "Cool Tone"
        case .vibrant: return "Vibrant"
        case .muted: return "Muted"
        case .pastel: return "Pastel"
        case .punchy: return "Punchy"
        case .fade: return "Matte Fade"
        case .noir: return "Noir"
        case .monosoft: return "Soft Mono"
        case .golden: return "Golden Hour"
        case .portra: return "Portrait Film"
        case .cinema: return "Cinematic"
        case .faded: return "Faded Print"
        case .cross: return "Cross Process"
        case .kodachrome: return "Vintage Slide"
        case .rose: return "Rose"
        case .coral: return "Coral"
        case .berry: return "Berry"
        case .redcarpet: return "Red Carpet"
        case .nude: return "No-Makeup"
        case .brows: return "Defined"
        }
    }

    // MARK: - Smart Analyze findings

    func findingTitle(_ kind: SmartAnalyzer.Finding.Kind) -> String {
        switch kind {
        case .texture: return "Skin texture"
        case .blemish: return "Blemishes"
        case .wrinkles: return "Fine lines"
        case .darkCircles: return "Under-eye shadows"
        case .shine: return "Shine"
        case .unevenTone: return "Uneven tone"
        case .teeth: return "Teeth"
        case .eyes: return "Eyes"
        case .exposure: return "Exposure"
        case .contrast: return "Contrast"
        case .levels: return "Levels"
        case .whiteBalance: return "White balance"
        case .color: return "Color"
        case .detail: return "Detail"
        case .balanced: return "Color and light"
        }
    }

    func findingDetail(_ detail: SmartAnalyzer.Finding.Detail) -> String {
        switch detail {
        case .texturePronounced: return "Pores and texture are pronounced"
        case .textureVisible: return "Some visible texture"
        case .textureFine: return "Texture is fine — smoothing kept low"
        case .spots(let count):
            return count == 1 ? "1 spot found" : "\(Digits.num(count)) spots found"
        case .linesHeavy: return "Lines on the forehead and around the eyes"
        case .linesLight: return "A few fine lines"
        case .underEyeStrong: return "Noticeably darker than the cheek"
        case .underEyeMild: return "Mildly darker than the cheek"
        case .underEyeFaint: return "Barely visible"
        case .shineHeavy: return "The T-zone is catching the light"
        case .shineLight: return "A little shine on the T-zone"
        case .tonePatchy: return "Visible patchiness across the skin"
        case .toneSlight: return "Slight variation in skin tone"
        case .teethWarm: return "Teeth look warm — whitening would help"
        case .teethSlight: return "A slight warmth in the teeth"
        case .eyesDim: return "The whites could be brighter"
        case .eyesCatchlight: return "Catchlight detail can be sharpened"
        case .exposureDark: return "The photo sits a little dark"
        case .exposureBright: return "The photo sits a little bright"
        case .contrastFlat: return "Mid-tones are flat"
        case .levelsFaded: return "The ends of the range are faded"
        case .castBlue: return "A blue cast"
        case .castWarm: return "A warm cast"
        case .colorDull: return "Colors are a little dull"
        case .detailSoft: return "The frame is a little soft"
        case .balanced: return "Already balanced"
        }
    }

    // MARK: - Cards and controls

    var closeButton: String { "Close" }
    var healingBrush: String { "Healing Brush" }
    var brushSize: String { "Size" }
    var brushShortcutHint: String { "Sets the heal brush diameter. [ and ] change it too." }
    var stamps: String { "Stamps" }
    var clearStamps: String { "Clear Stamps" }
    var cropTool: String { "Crop" }
    var cropToolSubtitle: String { "Drag the frame on the photo" }
    var cropAspectLabel: String { "ASPECT" }
    var cropSize: String { "Crop size" }
    var workingSize: String { "Working size" }
    var applyCrop: String { "Apply Crop" }
    var resetCrop: String { "Reset Crop" }
    var lookStrength: String { "Strength" }
    var grain: String { "Grain" }
    var lookNote: String {
        "A grade is applied to the whole photo after Color & Light, so it reshapes the balance you already set."
    }
    var resetSliderHelp: String { "Reset this slider" }
    var choosePhotoToRetouch: String { "Choose a photo to retouch" }
    var chooseExportLocation: String { "Choose where to save the retouched image" }
    var smartAlreadyZero: String { "Already at zero" }
    var smartAlreadyBalanced: String { "Already balanced" }
    /// Short names for the sliders in the report's summary line. The full
    /// slider names are too long to read as a list of values.
    var smartShortSmooth: String { "Smooth" }
    var smartShortBlemish: String { "Blemish" }
    var smartShortLines: String { "Lines" }
    var smartShortTone: String { "Tone" }
    var smartShortUnderEye: String { "Under-eye" }
    var smartShortShine: String { "Shine" }
    var smartShortBrighten: String { "Brighten" }
    var smartShortTeeth: String { "Teeth" }
    var smartShortEyes: String { "Eyes" }
    var smartShortExposure: String { "Exposure" }
    var smartShortContrast: String { "Contrast" }
    var smartShortBlacks: String { "Blacks" }
    var smartShortWhites: String { "Whites" }
    var smartShortSaturation: String { "Saturation" }
    var smartShortVibrance: String { "Vibrance" }
    var smartShortWarmth: String { "Warmth" }
    var smartShortClarity: String { "Clarity" }
    func smartFrameShare(_ percent: Int) -> String {
        "\(Digits.num(percent))% of the frame"
    }
    func smartFaceLabel(_ index: Int) -> String {
        "\(smartFaceSection) \(Digits.num(index + 1))"
    }

    // MARK: - AI

    var aiSection: String { "AI Edit" }
    var aiQuickEdit: String { "Quick Edit" }
    var aiRemoveObject: String { "Remove object" }
    var aiRemoveObjectHelp: String {
        "Click the object on the photo. The AI rebuilds only that area and leaves every other pixel as it was."
    }
    var aiSelectHint: String { "Click the object you want gone" }
    var aiMaskPoint: String { "Point" }
    var aiMaskBrush: String { "Brush" }
    var aiMaskBox: String { "Box" }
    var aiMaskClear: String { "Clear" }
    var aiMaskErase: String { "Erase" }
    var aiMaskBrushSize: String { "Brush size" }
    var aiMaskExpand: String { "Expand" }
    var aiMaskFeather: String { "Feather" }
    var aiMaskInvert: String { "Invert" }
    var aiMaskSnap: String { "Snap to edges" }
    var aiMaskSnapping: String { "Finding the edges…" }
    var aiMaskHint: String { "Paint over what should change" }
    var aiMaskBoxHint: String { "Drag around the area" }
    var aiHealArea: String { "Heal small area" }
    var aiHealAreaHelp: String {
        "Paint over a small spot. The local inpaint model fills it from the nearby texture in under a second."
    }
    var aiReimagine: String { "Reimagine" }
    var aiReimagineHelp: String {
        "Describe the change. The AI redraws the whole frame from your words — the subject stays recognisable, but every pixel is new."
    }
    var aiRunReimagine: String { "Reimagine photo" }
    var aiPromptLabel: String { "Describe the change" }
    var aiPromptPlaceholder: String { "e.g. golden hour light, soft film look" }
    var aiPromptNote: String {
        "The whole photo is regenerated. Brush, Point and Box do not apply here."
    }
    var aiMaskFailed: String { "Could not prepare the selection." }
    var aiMaskTooLarge: String {
        "That selection is too large for this tool. Use Remove object or a smaller area."
    }
    var aiModelMissing: String {
        "The local AI models are not installed. Open Settings → Manage Models… to download them."
    }
    var aiLicenseBlocked: String {
        "This AI model is not cleared for use on this Mac."
    }
    var aiRunEdit: String { "Run edit" }
    var aiCancelEdit: String { "Cancel" }
    var aiTryAgain: String { "Edit another area" }
    var aiEditCount: String { "AI edits" }
    var aiRemoveLastEdit: String { "Remove the last AI edit" }
    var aiLocalNote: String { "Runs on this Mac. Nothing is uploaded." }
    var aiHelperMissing: String {
        "The local AI helper is not installed. See the AI section of Settings for the setup steps."
    }
    var aiHelperStopped: String {
        "The local AI helper stopped responding. Run the edit again to restart it."
    }
    var aiHelperWriteFailed: String {
        "Could not reach the local AI helper. Run the edit again to restart it."
    }
    var aiTooLarge: String {
        "That area is too large for a local edit. Select a smaller object."
    }
    var aiBadReply: String { "The AI helper returned an unexpected result." }
    var aiMissingAssets: String {
        "An AI edit is missing its pixels, so it is not being shown. Reopen the edit or remove it."
    }
    func aiAssetsMissing(_ count: Int) -> String {
        count == 1
            ? aiMissingAssets
            : "\(Digits.num(count)) AI edits are missing their pixels, so they are not being shown."
    }
    var aiWorking: String { "Generating the edit on this Mac…" }
    var aiApplied: String { "AI edit applied" }
    var aiStageIdle: String { "Ready" }
    var aiStagePreparing: String { "Preparing the photo…" }
    var aiStageStarting: String { "Starting the AI helper…" }
    var aiStageWaiting: String {
        "Generating. This takes a few seconds to about a minute on this Mac."
    }
    func aiStageDenoising(_ step: Int, of total: Int) -> String {
        "Generating — step \(Digits.num(step)) of \(Digits.num(total))"
    }
    func aiStageFinished(_ seconds: Double) -> String {
        let value = String(format: "%.0f", seconds.rounded())
        return "Done in \(Digits.convert(value)) s"
    }
    func quickEditStatus(_ stage: QuickEditStage) -> String {
        switch stage {
        case .idle: return aiStageIdle
        case .preparing: return aiStagePreparing
        case .starting: return aiStageStarting
        case .denoising(let step): return aiStageDenoising(step, of: 4)
        case .finished(let seconds): return aiStageFinished(seconds)
        case .failed(let message): return message
        }
    }
}

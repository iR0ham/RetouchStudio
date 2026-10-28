import Foundation

/// Every user-facing string in the app, kept in one table so the copy stays
/// consistent and is easy to audit.
struct L10n {
    static let shared = L10n()

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
    var compareHelp: String { "Show the before/after comparison" }
    var faceBoxHelp: String { "Show the detected face box and regions" }

    // Sections
    var auto: String { "Auto" }
    var presets: String { "Presets" }
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
        "Sets exposure, contrast, color, warmth and clarity. Retouch sliders are left untouched. (⇧⌘L)"
    }
    var autoRetouchHelp: String {
        "Sets skin, blemish, teeth and eye tools. Color and light sliders are left untouched. (⇧⌘R)"
    }
    var autoNote: String {
        "The two Auto buttons are independent — each only changes its own sliders."
    }
    var autoRetouchScope: String {
        "Face only. Rest of photo untouched."
    }
    var autoStrength: String { "Strength" }
    var teethNotVisible: String {
        "Teeth aren't visible in this photo, so whitening has nothing to target."
    }
    var autoColorLightScope: String {
        "Whole photo, color and light only."
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
    var resetGroupHelp: String { "Reset this section" }
    /// Makeup is one group spread over three headings, so its glyph spells out
    /// what it actually clears.
    var resetMakeupHelp: String { "Reset lips, cheeks and brows" }
    var undoHelp: String { "Undo (⌘Z)" }
    var redoHelp: String { "Redo (⇧⌘Z)" }
    var undoMenu: String { "Undo" }
    var redoMenu: String { "Redo" }
    var doubleClickHint: String {
        "Double-click a slider to reset just that effect"
    }

    // Face status
    var noFaceDetected: String { "No face detected" }
    func facesDetected(_ n: Int) -> String {
        "\(n) face\(n == 1 ? "" : "s") detected"
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
    var autoColorFailed: String { "Could not analyze color and light." }
    var autoRetouchFailed: String { "Could not analyze the retouch settings." }
    var autoColorApplied: String { "Auto Color & Light applied." }
    var autoRetouchApplied: String { "Auto Retouch applied." }
    var autoRetouchNeedsFace: String {
        "No face detected, so Auto Retouch is unavailable. Try Auto Color & Light."
    }
    var renderingExport: String { "Rendering full-quality export…" }
    func saved(_ name: String) -> String { "Saved \(name)" }
    var exportFailed: String { "Could not save the export." }

    // Unsaved changes
    var unsavedTitle: String { "Discard unsaved adjustments?" }
    var unsavedMessage: String {
        "This photo has edits that haven't been saved to a project or exported. If you continue, they will be lost."
    }
    var discardChanges: String { "Discard Changes" }

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

    // Batch
    var batchExportMenu: String { "Batch Export…" }
    var batchChoosePhotos: String { "Choose photos to export" }
    var batchChooseFolder: String { "Choose a folder for the exported photos" }
    var batchStarting: String { "Starting batch export…" }
    func batchProgress(_ index: Int, _ total: Int) -> String {
        "Exporting \(index) of \(total)…"
    }
    func batchFinished(_ saved: Int, _ total: Int) -> String {
        saved == total
            ? "Batch export finished: \(saved) photos saved."
            : "Batch export finished: \(saved) of \(total) photos saved."
    }

    // Crop
    var applyingCrop: String { "Applying crop…" }
    var cropApplied: String { "Crop applied." }
    var cropReset: String { "Crop reset to the original framing." }

    // Healing brush
    var healCleared: String { "Healing stamps cleared." }
    func healStampAdded(_ count: Int) -> String {
        count == 1 ? "Healing stamp added — ⌘Z removes it." : "Healing stamps: \(count)."
    }
    var healStampRemoved: String { "Healing stamp removed." }

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
        "Drag to pan • pinch or ⌘-scroll to zoom • double-click for 100%"
    }
    var before: String { "Before" }
    var after: String { "After" }

    // Export sheet
    var format: String { "Format" }
    var quality: String { "Quality" }
    func originalSize(_ info: String) -> String { "Original size: \(info)" }
    func suggestedName(_ name: String) -> String { "Suggested name: \(name)" }
    var cancel: String { "Cancel" }
    var save: String { "Save…" }
    var saveExport: String { "Save Export…" }
    var exportFullQuality: String {
        "Exports are always written at the full quality and size of the original."
    }

    // Menus
    var retouchMenu: String { "Retouch" }
    var openMenu: String { "Open Image…" }
    var closeWindow: String { "Close Window" }
    var exportMenu: String { "Export…" }
    var autoColorMenu: String { "Auto Color & Light" }
    var autoRetouchMenu: String { "Auto Retouch" }
    var resetMenu: String { "Reset All Adjustments" }
    var showCompareMenu: String { "Show Compare" }
    var showFaceOverlayMenu: String { "Show Face Overlay" }
    var zoomInMenu: String { "Zoom In" }
    var zoomOutMenu: String { "Zoom Out" }
    var fitMenu: String { "Fit to Window" }

    // Preset titles
    func presetTitle(_ id: String) -> String {
        switch id {
        case "natural": return "Natural"
        case "glamour": return "Glamour"
        case "studio": return "Studio"
        case "editorial": return "Editorial"
        default: return id
        }
    }
}

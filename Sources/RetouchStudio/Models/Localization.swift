import Foundation

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
    var compareHelp: String { "Show the before/after comparison" }
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
    var lipGloss: String { "Lip Gloss" }
    var hairShine: String { "Hair Shine" }
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
        "Exporting \(Digits.num(index)) of \(Digits.num(total))…"
    }
    func batchFinished(_ saved: Int, _ total: Int) -> String {
        saved == total
            ? "Batch export finished: \(Digits.num(saved)) photos saved."
            : "Batch export finished: \(Digits.num(saved)) of \(Digits.num(total)) photos saved."
    }

    // Crop
    var applyingCrop: String { "Applying crop…" }
    var cropApplied: String { "Crop applied." }
    var cropReset: String { "Crop reset to the original framing." }

    // Healing brush
    var healCleared: String { "Healing stamps cleared." }
    var healSubtitle: String { "Click a blemish to heal it. Click a stamp to take it back." }
    func healStampAdded(_ count: Int) -> String {
        count == 1 ? "Healing stamp added — ⌘Z removes it." : "Healing stamps: \(Digits.num(count))."
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
    var settingsAuto: String { "AUTO" }
    var settingsAutoNote: String {
        "How much of each measured fix Smart Analyze applies."
    }
    var settingsExport: String { "EXPORT" }
    var settingsTools: String { "TOOLS" }
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
    var aboutTitle: String { "About Retouch Studio" }
    var aboutTagline: String { "Portrait retouching, measured." }
    var aboutVersion: String { "Version" }
    var aboutDeveloper: String { "Developer" }
    var aboutCopyright: String { "Copyright" }
    var aboutRights: String { "All rights reserved." }
    var aboutEngine: String { "Built with Core Image and Vision, entirely on this Mac." }
    var aboutDeveloperName: String { "Roham" }
    var aboutCopyrightLine: String { "© 2026 Roham" }
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
         ("⌘+ / ⌘− / ⌘0", "Zoom in / out / fit")]
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
        case .healCleared: return healCleared
        case .healStampRemoved: return healStampRemoved
        case .healStampAdded(let count): return healStampAdded(count)
        case .presetSaved(let name): return "\(presetSaved): \(name)"
        case .analyzingSmart: return analyzingSmart
        case .smartFailed: return smartFailed
        case .smartReady: return smartReady
        case .smartApplied: return smartApplied
        case .smartAppliedReport(let measures): return smartAppliedReport(measures)
        case .settingsReset: return settingsResetStatus
        case .recentMissing(let name): return recentMissing(name)
        case .renderingExport: return renderingExport
        case .saved(let name): return saved(name)
        case .exportFailed: return exportFailed
        case .projectSaved(let name): return projectSaved(name)
        case .projectSaveFailed: return projectSaveFailed
        case .projectPhotoMissing: return projectPhotoMissing
        case .projectOpenFailed: return projectOpenFailed
        case .batchStarting: return batchStarting
        case .batchProgress(let index, let total): return batchProgress(index, total)
        case .batchFinished(let saved, let total): return batchFinished(saved, total)
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
        }
    }

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
}

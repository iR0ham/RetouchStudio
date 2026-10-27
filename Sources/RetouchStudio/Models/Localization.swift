import Foundation
import SwiftUI

/// UI language. The app ships in both English and Persian; the user can switch
/// at runtime from the sidebar or the View menu, and the choice is remembered.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case persian = "fa"

    var id: String { rawValue }

    /// Name shown on the toggle button — always in the *other* language, which
    /// is how macOS apps usually present a language switch.
    var shortLabel: String {
        switch self {
        case .english: return "EN"
        case .persian: return "فا"
        }
    }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .persian: return "فارسی"
        }
    }

    var layoutDirection: LayoutDirection {
        switch self {
        case .english: return .leftToRight
        case .persian: return .rightToLeft
        }
    }
}

/// Every user-facing string in the app. Kept as one table so a missing
/// translation is obvious rather than silently falling back mid-screen.
struct L10n {
    let language: AppLanguage

    private func t(_ en: String, _ fa: String) -> String {
        language == .english ? en : fa
    }

    // App / general
    var appName: String { "Retouch Studio" }
    var noImageOpen: String { t("No image open", "عکسی باز نشده") }
    var noImageSelected: String { t("No image selected", "تصویری انتخاب نشده") }

    // Toolbar
    var open: String { t("Open", "باز کردن") }
    var export: String { t("Export", "خروجی") }
    var reset: String { t("Reset", "بازنشانی") }
    var compare: String { t("Compare", "مقایسه") }
    var faceBox: String { t("Face Box", "کادر چهره") }
    var openHelp: String { t("Open an image (⌘O)", "باز کردن تصویر (⌘O)") }
    var exportHelp: String { t("Save the retouched image (⌘E)", "ذخیره‌ی عکس رتوش‌شده (⌘E)") }
    var resetHelp: String { t("Reset all adjustments (⌘R)", "بازنشانی همه‌ی تنظیمات (⌘R)") }
    var compareHelp: String { t("Show the before/after comparison", "نمایش مقایسه‌ی قبل و بعد") }
    var faceBoxHelp: String { t("Show the detected face box and regions", "نمایش کادر و نواحی چهره") }
    var languageHelp: String { t("Switch language", "تغییر زبان") }

    // Sections
    var auto: String { t("Auto", "خودکار") }
    var presets: String { t("Presets", "پیش‌تنظیم‌ها") }
    var faceDetection: String { t("Face Detection", "تشخیص چهره") }
    var skin: String { t("Skin", "پوست") }
    var reshape: String { t("Reshape", "تغییر فرم") }
    var faceDetail: String { t("Face Detail", "جزئیات چهره") }
    var colorLight: String { t("Color & Light", "رنگ و نور") }
    var exportSection: String { t("Export", "خروجی") }

    // Auto
    var autoColorLight: String { t("Auto Color & Light", "خودکار رنگ و نور") }
    var autoRetouch: String { t("Auto Retouch", "خودکار رتوش") }
    var autoColorLightHelp: String {
        t("Sets exposure, contrast, color, warmth and clarity. Retouch sliders are left untouched. (⇧⌘L)",
          "نوردهی، کنتراست، رنگ، گرمی و شفافیت را تنظیم می‌کند. اسلایدرهای رتوش دست‌نخورده می‌مانند. (⇧⌘L)")
    }
    var autoRetouchHelp: String {
        t("Sets skin, blemish, teeth and eye tools. Color and light sliders are left untouched. (⇧⌘R)",
          "ابزارهای پوست، لک، دندان و چشم را تنظیم می‌کند. اسلایدرهای رنگ و نور دست‌نخورده می‌مانند. (⇧⌘R)")
    }
    var autoNote: String {
        t("The two Auto buttons are independent — each only changes its own sliders.",
          "دو دکمه‌ی خودکار مستقل‌اند — هر کدام فقط اسلایدرهای خودش را تغییر می‌دهد.")
    }
    var autoRetouchScope: String {
        t("Face only. Rest of photo untouched.",
          "فقط صورت. بقیه‌ی عکس دست نمی‌خورد.")
    }
    var autoColorLightScope: String {
        t("Whole photo, color and light only.",
          "کل عکس، فقط رنگ و نور.")
    }

    // Sliders
    var skinSmoothing: String { t("Skin Smoothing", "صافی پوست") }
    var skinBrightness: String { t("Skin Brightness", "روشنایی پوست") }
    var blemishRemoval: String { t("Blemish Removal", "رفع لک و جوش") }
    var teethWhitening: String { t("Teeth Whitening", "سفیدی دندان") }
    var eyeBrightness: String { t("Eye Brightness", "روشنایی چشم") }
    var eyeSharpen: String { t("Eye Sharpen", "وضوح چشم") }
    var exposure: String { t("Exposure", "نوردهی") }
    var contrast: String { t("Contrast", "کنتراست") }
    var saturation: String { t("Saturation", "اشباع رنگ") }
    var vibrance: String { t("Vibrance", "شادابی رنگ") }
    var warmth: String { t("Warmth", "گرمی رنگ") }
    var clarity: String { t("Clarity", "شفافیت") }
    var vignette: String { t("Vignette", "وینیت") }
    var texturePreserve: String { t("Texture Preserve", "حفظ بافت پوست") }
    var wrinkleReduction: String { t("Wrinkle Reduction", "کاهش چین و چروک") }
    var skinTone: String { t("Even Skin Tone", "یکدست‌سازی رنگ پوست") }
    var darkCircles: String { t("Dark Circles", "رفع تیرگی زیر چشم") }
    var eyeSize: String { t("Eye Size", "اندازه‌ی چشم") }
    var noseSize: String { t("Nose Width", "عرض بینی") }
    var noseTip: String { t("Nose Tip", "نوک بینی") }
    var lipSize: String { t("Lip Size", "اندازه‌ی لب") }
    var cheekSize: String { t("Cheeks", "گونه‌ها") }
    var jawWidth: String { t("Jawline", "خط فک") }
    var chinLength: String { t("Chin", "چانه") }
    var faceWidth: String { t("Face Width", "عرض صورت") }
    var faceLength: String { t("Face Length", "طول صورت") }
    var reshapeScope: String {
        t("Shapes features only. Reshaping runs before skin work, so masks stay aligned.",
          "فقط فرم اجزای صورت را تغییر می‌دهد. تغییر فرم قبل از رتوش اجرا می‌شود تا ماسک‌ها هم‌تراز بمانند.")
    }
    var resetGroupHelp: String { t("Reset this section", "صفر کردن این بخش") }
    var undoHelp: String { t("Undo (⌘Z)", "واگرد (⌘Z)") }
    var redoHelp: String { t("Redo (⇧⌘Z)", "دوباره (⇧⌘Z)") }
    var doubleClickHint: String {
        t("Double-click a slider to reset just that effect",
          "دو بار کلیک روی هر اسلایدر = صفر کردن فقط همان افکت")
    }

    // Face status
    var noFaceDetected: String { t("No face detected", "چهره‌ای شناسایی نشد") }
    func facesDetected(_ n: Int) -> String {
        language == .english
            ? "\(n) face\(n == 1 ? "" : "s") detected"
            : "\(n) چهره شناسایی شد"
    }
    var faceToolsNeedFace: String {
        t("Skin, teeth and eye tools have no effect until a face is detected.",
          "ابزارهای پوست، دندان و چشم بدون تشخیص چهره اثری ندارند.")
    }
    var showFaceOverlay: String { t("Show face box and regions", "نمایش کادر و نواحی چهره") }
    var compareToggle: String { t("Compare (before / after)", "حالت مقایسه (قبل / بعد)") }

    // Status messages
    var dropHint: String { t("Drop a photo here, or click Open.", "یک عکس را بکش و اینجا رها کن، یا «باز کردن» را بزن.") }
    var readingImage: String { t("Reading image…", "در حال خواندن تصویر…") }
    var couldNotRead: String {
        t("Could not read that file. Choose a valid image.",
          "این فایل خوانده نشد. یک فایل تصویری سالم انتخاب کن.")
    }
    var noFaceColorOnly: String {
        t("No face found — only the Color & Light tools apply.",
          "چهره‌ای پیدا نشد؛ فقط تنظیمات رنگ و نور کار می‌کنند.")
    }
    var analyzingColor: String { t("Analyzing color and light…", "در حال تحلیل رنگ و نور…") }
    var analyzingSkin: String { t("Analyzing skin and face…", "در حال تحلیل پوست و چهره…") }
    var autoColorFailed: String { t("Could not analyze color and light.", "تحلیل رنگ و نور ممکن نشد.") }
    var autoRetouchFailed: String { t("Could not analyze the retouch settings.", "تحلیل رتوش ممکن نشد.") }
    var autoColorApplied: String { t("Auto Color & Light applied.", "رنگ و نور خودکار تنظیم شد.") }
    var autoRetouchApplied: String { t("Auto Retouch applied.", "رتوش خودکار اعمال شد.") }
    var autoRetouchNeedsFace: String {
        t("No face detected, so Auto Retouch is unavailable. Try Auto Color & Light.",
          "چهره‌ای شناسایی نشده؛ رتوش خودکار ممکن نیست. از «خودکار رنگ و نور» استفاده کن.")
    }
    var renderingExport: String { t("Rendering full-quality export…", "در حال ساخت خروجی با کیفیت کامل…") }
    func saved(_ name: String) -> String { t("Saved \(name)", "خروجی ذخیره شد: \(name)") }
    var exportFailed: String { t("Could not save the export.", "ذخیره‌ی خروجی ناموفق بود.") }

    // Drop zone
    var dropTitle: String { t("Drop a portrait here", "عکس پرتره را اینجا رها کن") }
    var dropSubtitle: String {
        t("Or use the button below — JPEG, PNG, HEIC and TIFF are supported",
          "یا از دکمه‌ی زیر استفاده کن — JPEG، PNG، HEIC و TIFF پشتیبانی می‌شوند")
    }
    var openImage: String { t("Open Image", "باز کردن تصویر") }
    var featureSmooth: String { t("Smooth skin without blurring eyes or lips", "صاف‌کردن پوست بدون تار شدن چشم و لب") }
    var featureBlemish: String { t("Remove blemishes, brighten skin", "رفع لک و جوش، روشن کردن پوست") }
    var featureTeeth: String { t("Whiten teeth, brighten eyes", "سفید کردن دندان و روشن کردن چشم") }
    var featureColor: String { t("Full control of color, light, clarity and vignette", "کنترل کامل رنگ، نور، شفافیت و وینیت") }
    var featureZoom: String { t("Drag to move the photo, pinch or ⌘-scroll to zoom", "کشیدن عکس برای جابجایی، پینچ یا ⌘+اسکرول برای بزرگ‌نمایی") }

    // Canvas controls
    var fit: String { t("Fit", "جا‌شده") }
    var zoomOut: String { t("Zoom out (⌘−)", "کوچک‌نمایی (⌘−)") }
    var zoomIn: String { t("Zoom in (⌘+)", "بزرگ‌نمایی (⌘+)") }
    var fitToWindow: String { t("Fit to window (⌘0 or double-click)", "برگشت به حالت جا‌شده (⌘0)") }
    var canvasHelp: String {
        t("Drag to pan • pinch or ⌘-scroll to zoom • double-click for 100%",
          "کشیدن = جابجایی • پینچ یا ⌘+اسکرول = بزرگ‌نمایی • دو بار کلیک = ۱۰۰٪")
    }
    var before: String { t("Before", "قبل") }
    var after: String { t("After", "بعد") }

    // Export sheet
    var format: String { t("Format", "قالب فایل") }
    var quality: String { t("Quality", "کیفیت") }
    func originalSize(_ info: String) -> String { t("Original size: \(info)", "ابعاد اصلی: \(info)") }
    func suggestedName(_ name: String) -> String { t("Suggested name: \(name)", "نام پیشنهادی: \(name)") }
    var cancel: String { t("Cancel", "لغو") }
    var save: String { t("Save…", "ذخیره…") }
    var saveExport: String { t("Save Export…", "ذخیره‌ی خروجی…") }
    var exportFullQuality: String {
        t("Exports are always written at the full quality and size of the original.",
          "خروجی همیشه با کیفیت و ابعاد کامل عکس اصلی ساخته می‌شود.")
    }

    // Menus
    var retouchMenu: String { t("Retouch", "رتوش") }
    var openMenu: String { t("Open Image…", "باز کردن تصویر…") }
    var exportMenu: String { t("Export…", "ذخیره‌ی خروجی…") }
    var autoColorMenu: String { t("Auto Color & Light", "خودکار رنگ و نور") }
    var autoRetouchMenu: String { t("Auto Retouch", "خودکار رتوش") }
    var resetMenu: String { t("Reset All Adjustments", "بازنشانی تنظیمات") }
    var showCompareMenu: String { t("Show Compare", "نمایش مقایسه") }
    var showFaceOverlayMenu: String { t("Show Face Overlay", "نمایش کادر چهره") }
    var zoomInMenu: String { t("Zoom In", "بزرگ‌نمایی") }
    var zoomOutMenu: String { t("Zoom Out", "کوچک‌نمایی") }
    var fitMenu: String { t("Fit to Window", "اندازه‌ی پنجره") }
    var languageMenu: String { t("Language", "زبان") }

    // Preset titles
    func presetTitle(_ id: String) -> String {
        switch id {
        case "natural": return t("Natural", "طبیعی")
        case "glamour": return t("Glamour", "گلَمور")
        case "studio": return t("Studio", "استودیو")
        case "editorial": return t("Editorial", "ادیتوریال")
        default: return id
        }
    }
}

import Foundation
import StudioCore

/// The Persian table. Every line of `L10n` is overridden here, so the two
/// languages stay in step: a new string in one file fails to compile until the
/// other has it too.
///
/// Persian is written the way it is read — right to left, with the technical
/// terms the owner already uses from the English UI kept where translating
/// them would only make them harder to recognise.
final class PersianL10n: L10n {

    static let table = PersianL10n()

    // MARK: - App / general

    override var appName: String { "Retouch Studio" }
    override var edited: String { "ویرایش‌شده" }
    override var noImageOpen: String { "عکسی باز نشده" }
    override var noImageSelected: String { "عکسی انتخاب نشده" }

    // MARK: - Toolbar

    override var open: String { "باز کردن" }
    override var export: String { "خروجی" }
    override var reset: String { "بازنشانی" }
    override var compare: String { "مقایسه" }
    override var faceBox: String { "کادر چهره" }
    override var openHelp: String { "باز کردن یک عکس (⌘O)" }
    override var exportHelp: String { "ذخیرهٔ تصویر رتوش‌شده (⌘E)" }
    override var resetHelp: String { "بازنشانی همهٔ تنظیمات (⌘R)" }
    override var compareHelp: String { "نمایش مقایسهٔ قبل و بعد (Space را نگه دار تا اصل را ببینی)" }
    override var faceBoxHelp: String { "نمایش کادر و نواحی تشخیص‌داده‌شدهٔ چهره" }

    // MARK: - Sections

    override var auto: String { "خودکار" }
    override var presets: String { "پیش‌تنظیم‌ها" }
    override var myLooks: String { "ظاهرهای من" }
    override var lookNamePrompt: String { "برای این ظاهر نام بگذار" }
    override var saveLook: String { "ذخیره" }
    override var presetSaved: String { "ظاهر ذخیره شد" }
    override var deleteLookHelp: String { "حذف این ظاهر" }
    override var noLooksYet: String {
        "هنوز چیزی ذخیره نشده. اسلایدرها را تنظیم کن و اینجا برایش نام بگذار."
    }
    override var faceDetection: String { "تشخیص چهره" }
    override var skin: String { "پوست" }
    override var reshape: String { "تغییر شکل چهره" }
    override var faceDetail: String { "جزئیات چهره" }
    override var colorLight: String { "رنگ و نور" }
    override var exportSection: String { "خروجی" }

    // MARK: - Auto

    override var autoColorLight: String { "رنگ و نور خودکار" }
    override var autoRetouch: String { "رتوش خودکار" }
    override var autoColorLightHelp: String {
        "مشخص می‌کند چقدر از اصلاح اندازه‌گیری‌شدهٔ رنگ و نور اعمال شود: سطوح، نوردهی، کنتراست، رنگ، گرمی و شفافیت."
    }
    override var autoRetouchHelp: String {
        "مشخص می‌کند چقدر از اصلاح اندازه‌گیری‌شدهٔ پوست اعمال شود: هموارسازی، لک، چروک، لحن، دندان و چشم."
    }
    override var teethNotVisible: String {
        "دندان‌ها در این عکس دیده نمی‌شوند، پس سفید کردن چیزی برای هدف‌گیری ندارد."
    }

    // MARK: - Sliders

    override var skinSmoothing: String { "هموارسازی پوست" }
    override var skinBrightness: String { "روشنی پوست" }
    override var blemishRemoval: String { "حذف لک" }
    override var teethWhitening: String { "سفید کردن دندان" }
    override var eyeBrightness: String { "روشنی چشم" }
    override var eyeSharpen: String { "وضوح چشم" }
    override var exposure: String { "نوردهی" }
    override var contrast: String { "کنتراست" }
    override var blacks: String { "سیاهی‌ها" }
    override var whites: String { "سفیدی‌ها" }
    override var saturation: String { "اشباع رنگ" }
    override var vibrance: String { "شادابی رنگ" }
    override var warmth: String { "گرمی" }
    override var clarity: String { "شفافیت" }
    override var vignette: String { "وینیت" }
    override var texturePreserve: String { "حفظ بافت" }
    override var wrinkleReduction: String { "کاهش چروک" }
    override var skinTone: String { "یکدست‌سازی رنگ پوست" }
    override var darkCircles: String { "تیرگی زیر چشم" }
    override var eyeSize: String { "اندازهٔ چشم" }
    override var noseSize: String { "پهنای بینی" }
    override var noseTip: String { "نوک بینی" }
    override var lipSize: String { "اندازهٔ لب" }
    override var cheekSize: String { "گونه‌ها" }
    override var jawWidth: String { "خط فک" }
    override var chinLength: String { "چانه" }
    override var faceWidth: String { "پهنای چهره" }
    override var faceLength: String { "طول چهره" }
    override var reshapeScope: String {
        "فقط شکل اجزای چهره را تغییر می‌دهد."
    }
    override var skinFinish: String { "پرداخت پوست" }
    override var shine: String { "کنترل براقی" }
    override var irisEnhance: String { "جزئیات عنبیه" }
    override var lashDarken: String { "تیرگی مژه" }
    override var lensTint: String { "لنز رنگی" }
    override var lensColor: String { "رنگ لنز" }
    override var teethAlign: String { "هم‌ترازی دندان" }
    override var lipGloss: String { "براقی لب" }
    override var hairShine: String { "براقی مو" }
    override var hairVolume: String { "حجم مو" }
    override var splitTone: String { "تون دوگانه" }

    // MARK: - Curve and HSL

    override var toneCurve: String { "منحنی تُن" }
    override var curveShadows: String { "سایه‌ها" }
    override var curveMidtones: String { "میان‌تُن‌ها" }
    override var curveHighlights: String { "هایلایت‌ها" }
    override var curveNote: String {
        "یک نقطه را بکش تا آن بخش از محدودهٔ نور بالا یا پایین برود. منحنی فقط روی روشنایی کار می‌کند، پس رنگ‌ها سر جایشان می‌مانند."
    }
    override var hsl: String { "HSL" }
    override var luminance: String { "روشنایی" }
    override var hslNote: String {
        "در هر لحظه روی یک خانوادهٔ رنگی تمرکز می‌کند. باندها نرم روی هم می‌افتند، پس رنگی که بین دو باند است نصف نمی‌شود، مشترک می‌ماند."
    }

    // MARK: - Body and background

    override var bodySmoothing: String { "هموارسازی بدن" }
    override var bodyBrightness: String { "روشنی بدن" }
    override var bodySlim: String { "لاغرتر کردن بدن" }
    override var bodyWaist: String { "کمر" }
    override var bodyArms: String { "بازوها" }
    override var bodyLegs: String { "پاها" }
    override var poseScope: String {
        "کمر، بازو و پا از مفاصلی پیروی می‌کنند که Vision پیدا می‌کند، پس هر کدام فقط همان بخش بدن را باریک می‌کند، نه کل قاب."
    }
    override var poseMissing: String {
        "در این عکس شانه و لگن پیدا نشد، پس کمر، بازو و پا لنگری برای کار ندارند."
    }
    override var poseMissingWaist: String {
        "لگن و شانه هر دو پیدا نشدند، پس کمر لنگری برای کار ندارد."
    }
    override var poseMissingArms: String {
        "هیچ جفت شانه و آرنج پیدا نشد، پس بازو لنگری برای کار ندارد."
    }
    override var poseMissingLegs: String {
        "هیچ جفت لگن و زانو پیدا نشد، پس پا لنگری برای کار ندارد."
    }
    override var backgroundBlur: String { "محو پس‌زمینه" }
    override var backgroundTone: String { "تُن پس‌زمینه" }
    override var backgroundSaturation: String { "اشباع پس‌زمینه" }
    override var backgroundFill: String { "رنگ پُر پس‌زمینه" }
    override var backgroundFillColor: String { "رنگ پُرکننده" }
    override var backgroundRemove: String { "حذف پس‌زمینه" }
    override var backdropImageTitle: String { "تصویر پس‌زمینه" }
    override var chooseBackdrop: String { "انتخاب تصویر…" }
    override var chooseBackdropMessage: String { "یک تصویر برای پس‌زمینه انتخاب کنید" }
    override var backdropStrength: String { "شدت پس‌زمینه" }
    override var backdropClearHelp: String { "حذف تصویر پس‌زمینهٔ انتخابی" }
    override var backdropNote: String {
        "تصویر داخل برنامه کپی می‌شود، پس اگر فایل اصلی جابه‌جا شود پروژه باز هم کار می‌کند."
    }
    override var backdropFailed: String { "این تصویر به‌عنوان پس‌زمینه خوانده نشد." }
    override var backgroundRemoveNote: String {
        "حذف پس‌زمینه آن را شفاف می‌کند. PNG و TIFF شفافیت را نگه می‌دارند؛ JPEG آن را روی سفید می‌نویسد."
    }
    override var bodyScope: String {
        "سوژه‌ای را می‌خواند که Vision پیدا می‌کند، پس روی عکس‌های تمام‌قد هم کار می‌کند که چهره کوچک است."
    }
    override var backgroundScope: String {
        "هر چیزی پشت سوژه نرم و رنگ‌بندی می‌شود؛ لبهٔ سوژه محو می‌شود تا هالهٔ برشی دیده نشود."
    }
    override var subjectDetecting: String { "در حال پیدا کردن سوژه…" }
    override var subjectMissing: String {
        "در این عکس سوژه‌ای پیدا نشد، پس بدن و پس‌زمینه چیزی برای جدا کردن ندارند."
    }
    override var resetGroupHelp: String { "بازنشانی این بخش" }
    override var resetMakeupHelp: String { "بازنشانی لب، گونه، کانتور، چشم، ابرو و مو" }

    // MARK: - Makeup

    override var makeupColor: String { "رنگ" }
    override var makeupCustomColor: String { "دلخواه" }
    override var pickColorHelp: String { "هر رنگی انتخاب کن" }
    override var hue: String { "رنگ‌مایه" }
    override var opacity: String { "شفافیت" }
    override var makeupNote: String {
        "آرایش سایه‌روشن زیرش را نگه می‌دارد، پس لب، گونه، کانتور، چشم و مو سه‌بعدی می‌مانند."
    }
    override var makeupNoFace: String {
        "چهره‌ای تشخیص داده نشده، پس آرایش چیزی برای رنگ کردن ندارد."
    }
    override var undoHelp: String { "واگرد (⌘Z)" }
    override var redoHelp: String { "ازنو (⇧⌘Z)" }
    override var undoMenu: String { "واگرد" }
    override var redoMenu: String { "ازنو" }
    override var doubleClickHint: String {
        "برای بازنشانی فقط همان افکت، دوبار روی اسلایدر کلیک کن"
    }
    override func sliderHint(_ hint: SliderHint) -> String { hint.persian }

    // MARK: - Face status

    override var noFaceDetected: String { "چهره‌ای تشخیص داده نشد" }
    override func facesDetected(_ n: Int) -> String {
        "\(Digits.num(n)) چهره تشخیص داده شد"
    }
    override var faceToolsNeedFace: String {
        "ابزارهای پوست، دندان و چشم تا تشخیص چهره اثری ندارند."
    }
    override var showFaceOverlay: String { "نمایش کادر و نواحی چهره" }
    override var compareToggle: String { "مقایسه (قبل / بعد)" }

    // MARK: - Status messages

    override var dropHint: String { "یک عکس اینجا رها کن یا روی «باز کردن» بزن." }
    override var readingImage: String { "در حال خواندن تصویر…" }
    override var couldNotRead: String {
        "این فایل خوانده نشد. یک تصویر معتبر انتخاب کن."
    }
    override var noFaceColorOnly: String {
        "چهره‌ای پیدا نشد — فقط ابزارهای رنگ و نور اعمال می‌شوند."
    }
    override var analyzingColor: String { "در حال تحلیل رنگ و نور…" }
    override var analyzingSkin: String { "در حال تحلیل پوست و چهره…" }

    // MARK: - Auto Retouch readout

    override var autoSaidLightSmoothing: String { "هموارسازی ملایم" }
    override var autoSaidSmoothing: String { "بافت نرم‌تر شد" }
    override func autoSaidBlemishes(_ n: Int) -> String {
        n == 1 ? "۱ لک ترمیم شد" : "\(Digits.num(n)) لک ترمیم شد"
    }
    override var autoSaidLines: String { "چروک‌های ریز کم شد" }
    override var autoSaidDarkCircles: String { "زیر چشم روشن‌تر شد" }
    override var autoSaidTone: String { "رنگ پوست یکدست شد" }
    override var autoSaidBrighter: String { "پوست روشن‌تر شد" }
    override var autoSaidTeeth: String { "دندان سفیدتر شد" }
    override var autoSaidEyes: String { "چشم‌ها روشن‌تر شد" }
    override var autoSaidClean: String { "چیزی برای اصلاح نبود — این پوست از قبل تمیز است" }
    override func autoRetouchReport(_ measures: [String]) -> String {
        "رتوش خودکار: " + (measures.isEmpty ? [autoSaidClean] : measures).joined(separator: "، ") + "."
    }
    override var renderingExport: String { "در حال ساخت خروجی با کیفیت کامل…" }
    override func upscaling(_ done: Int, _ total: Int) -> String {
        "بزرگ‌نمایی کاشی \(Digits.num(done)) از \(Digits.num(total))…"
    }
    override func saved(_ name: String) -> String { "\(name) ذخیره شد" }
    override var exportFailed: String { "خروجی ذخیره نشد." }
    override var exportRefusedOriginal: String {
        "این همان عکسی است که ویرایش می‌کنی. نام یا پوشهٔ دیگری انتخاب کن."
    }
    override var exportCancelled: String { "خروجی لغو شد." }
    override var cancelExport: String { "لغو خروجی" }
    override var operationBusy: String {
        "یک عملیات دیگر در جریان است — بعد از پایانش دوباره امتحان کن."
    }

    // MARK: - Unsaved changes

    override var unsavedTitle: String { "تغییرات ذخیره‌نشده دور ریخته شود؟" }
    override var unsavedMessage: String {
        "این عکس ویرایش‌هایی دارد که در پروژه ذخیره یا خروجی گرفته نشده. اگر ادامه دهی، از دست می‌روند."
    }
    override var discardChanges: String { "دور ریختن تغییرات" }
    override var saveBeforeClosing: String { "ذخیرهٔ پروژه" }

    // MARK: - Projects

    override var saveProjectMenu: String { "ذخیرهٔ پروژه" }
    override var saveProjectAsMenu: String { "ذخیرهٔ پروژه با نام…" }
    override var openProjectMenu: String { "باز کردن پروژه…" }
    override var chooseProjectLocation: String { "جای ذخیرهٔ پروژه را انتخاب کن" }
    override var chooseProject: String { "یک پروژهٔ Retouch Studio انتخاب کن" }
    override func projectSaved(_ name: String) -> String { "پروژهٔ \(name) ذخیره شد" }
    override var projectSaveFailed: String { "پروژه ذخیره نشد." }
    override var projectOpened: String { "پروژه بازیابی شد." }
    override var projectOpenFailed: String { "این پروژه باز نشد." }
    override var projectPhotoMissing: String {
        "عکسی که این پروژه به آن اشاره می‌کند دیگر در آن مسیر نیست."
    }
    override var projectLocateTitle: String { "پیدا کردن عکس" }
    override func projectLocateMessage(_ name: String) -> String {
        "جای کنونی «\(name)» را انتخاب کن. پروژه جای تازه را به یاد می‌سپارد."
    }
    override func projectTooNew(_ version: Int) -> String {
        "این پروژه با نسخهٔ تازه‌تری از برنامه (نسخهٔ \(Digits.num(version))) نوشته شده است."
    }
    override var projectRelinked: String { "پروژه باز شد و جای تازهٔ عکس ذخیره شد." }
    override var recoveryStorageFailed: String {
        "نسخهٔ بازیابی به‌روز نشد؛ کار ذخیره‌نشده برای اجرای بعدی محافظت نشده است."
    }
    override func recoveryQuarantined(_ count: Int) -> String {
        count == 1
            ? "یک نسخهٔ بازیابی آسیب‌دیده کنار گذاشته شد و پاک نشد."
            : "\(Digits.num(count)) نسخهٔ بازیابی آسیب‌دیده کنار گذاشته شدند و پاک نشدند."
    }
    override var recoveryCandidateNotRemoved: String {
        "عکس بازیابی‌شده ذخیره شد، اما نسخهٔ بازیابی قدیمی‌اش حذف نشد."
    }
    override func recoveryNeedsNewerBuild(_ features: [String]) -> String {
        let list = features.joined(separator: "، ")
        return list.isEmpty
            ? "یک نسخهٔ بازیابی‌شده به نسخهٔ جدیدتری از برنامه نیاز دارد."
            : "یک نسخهٔ بازیابی‌شده به نسخهٔ جدیدتری از برنامه نیاز دارد (\(list))."
    }

    // MARK: - Batch

    override var batchExportMenu: String { "خروجی گروهی…" }
    override var batchChoosePhotos: String { "عکس‌هایی که می‌خواهی خروجی بگیری انتخاب کن" }
    override var batchChooseFolder: String { "پوشهٔ عکس‌های خروجی را انتخاب کن" }
    override var batchStarting: String { "خروجی گروهی شروع شد…" }
    override func batchProgress(_ index: Int, _ total: Int) -> String {
        "خروجی \(Digits.num(index)) از \(Digits.num(total))…"
    }
    override func batchFinished(_ saved: Int, _ total: Int, cropsSkipped: Int) -> String {
        let savedText = saved == total
            ? "\(Digits.num(saved)) عکس ذخیره شد"
            : "\(Digits.num(saved)) از \(Digits.num(total)) عکس ذخیره شد"
        let skippedText = cropsSkipped > 0
            ? " · \(Digits.num(cropsSkipped)) برش رد شد (شکل متفاوت)"
            : ""
        return "خروجی گروهی تمام شد: \(savedText)\(skippedText)."
    }
    override var batchCancelled: String { "خروجی گروهی لغو شد." }
    override var batchSheetTitle: String { "خروجی گروهی" }
    override func batchSelected(_ count: Int) -> String {
        count == 1 ? "۱ عکس انتخاب شده" : "\(Digits.num(count)) عکس انتخاب شده"
    }
    override var batchIncludeStamps: String { "مهرهای هیل و استیکرها" }
    override var batchIncludeStampsDetail: String {
        "فقط وقتی درست است که بقیهٔ عکس‌ها هم لکه‌های همین عکس را داشته باشند."
    }
    override var batchIncludeAnalysis: String { "اورلی تحلیل" }
    override var batchIncludeAnalysisDetail: String { "خطوط با چهرهٔ هر عکس خودش جابه‌جا می‌شوند." }
    override var batchStart: String { "شروع خروجی" }
    override var batchDone: String { "تمام" }

    // MARK: - Crop

    override var applyingCrop: String { "در حال اعمال برش…" }
    override var cropApplied: String { "برش اعمال شد." }
    override var cropReset: String { "برش به قاب اصلی برگشت." }
    override var rotated: String { "عکس چرخید." }
    override var flipped: String { "عکس آینه شد." }
    override var straightened: String { "تراز اعمال شد." }
    override var orientationLabel: String { "جهت" }
    override var rotateLeft: String { "چپ" }
    override var rotateRight: String { "راست" }
    override var flipHorizontal: String { "آینه" }
    override var straightenLabel: String { "تراز" }
    override var levelAction: String { "افقی" }

    // MARK: - Healing brush

    override var healCleared: String { "مهرهای ترمیم پاک شدند." }
    override var healSubtitle: String {
        "روی یک لک کلیک کن تا ترمیم شود. روی یک مهر کلیک کن تا برگردد."
    }
    override func healStampAdded(_ count: Int) -> String {
        count == 1 ? "مهر ترمیم اضافه شد — ⌘Z آن را برمی‌دارد." : "مهرهای ترمیم: \(Digits.num(count))."
    }
    override var healStampRemoved: String { "مهر ترمیم برداشته شد." }

    // MARK: - Stickers

    override var artTitle: String { "استیکرها" }
    override var artSubtitle: String { "استیکر و طرح روی عکس بگذار" }
    override var artShape: String { "شکل" }
    override var artSize: String { "اندازه" }
    override var artRotation: String { "چرخش" }
    override var artDelete: String { "حذف استیکر" }
    override var artDuplicate: String { "تکثیر" }
    override var artClear: String { "پاک کردن همهٔ استیکرها" }
    override var artDragResize: String { "برای تغییر اندازه بکش" }
    override var artDragRotate: String { "برای چرخاندن بکش" }
    override var artNote: String {
        "برای گذاشتن استیکر روی عکس کلیک کن. برای انتخاب، روی یک استیکر کلیک کن؛ بعد آن را بکش یا با دسته‌هایش اندازه و چرخشش را عوض کن."
    }
    override var stickerRemoved: String { "استیکر برداشته شد." }
    override var stickersCleared: String { "استیکرها پاک شدند." }
    override func stickerAdded(_ count: Int) -> String {
        count == 1 ? "استیکر گذاشته شد — ⌘Z آن را برمی‌دارد." : "استیکرها: \(Digits.num(count))."
    }
    override func stickerKindTitle(_ kind: StickerKind) -> String {
        switch kind {
        case .star: return "ستاره"
        case .heart: return "قلب"
        case .sparkle: return "درخشش"
        case .flower: return "گل"
        case .butterfly: return "پروانه"
        case .lightning: return "آذرخش"
        }
    }

    // MARK: - Face analysis

    override var analysisTitle: String { "آنالیز چهره" }
    override var analysisSubtitle: String { "نقاط، شکل‌ها و خط‌های راهنما — بدون متن" }
    override var analysisEnable: String { "نمایش لایهٔ آنالیز" }
    override var analysisStyle: String { "سبک" }
    override var analysisStyleOutline: String { "شکل‌های خط‌چین" }
    override var analysisStyleMesh: String { "مِش صورت" }
    override var analysisFaceOutline: String { "خط دور صورت" }
    override var analysisAreas: String { "نواحی" }
    override var analysisInk: String { "رنگ خط" }
    override var analysisWeight: String { "ضخامت خط" }
    override var analysisStrength: String { "شدت خط" }
    override var analysisGlow: String { "درخشش" }
    override var analysisResetEnds: String { "بازنشانی نقطه‌ها" }
    override var analysisDragEnd: String { "نقطه یا سرِ خط را بکش تا جایش را انتخاب کنی" }
    override var analysisNote: String {
        "عکس هیچ متنی ندارد. نقطهٔ روی صورت را بکش تا شروع خط جابه‌جا شود، و سرِ خط را بکش تا جای برچسب را انتخاب کنی."
    }
    override var analysisMeshNote: String {
        "در حالت مِش، نواحی فقط تعیین می‌کنند کدام خط‌های راهنما کشیده شوند."
    }
    override var analysisNoFace: String {
        "چهره‌ای پیدا نشد. آنالیز به یک چهرهٔ واضح و رو به دوربین نیاز دارد."
    }
    override var analysisNoLandmarks: String {
        "این چهره نقاط جزئیات ندارد. نقطه‌ها و خط‌ها از کادر صورت پیروی می‌کنند."
    }
    override var faceSelectionTitle: String { "سوژه" }
    override var faceSelectionAuto: String { "خودکار" }
    override func faceSelectionName(_ index: Int) -> String { "چهرهٔ \(Digits.num(index + 1))" }
    override var analysisExportSection: String { "آنالیز چهره" }
    override var analysisExportSectionHelp: String {
        "انتخاب می‌کند که لایهٔ آنالیز چهره روی خروجی کشیده شود و چگونه."
    }
    override var analysisExportMode: String { "خروجی" }
    override var analysisMargin: String { "حاشیه" }
    override var analysisNeedsFace: String {
        "چهره‌ای تشخیص داده نشد، پس لایهٔ آنالیز کشیده نمی‌شود. این نسخه به‌صورت عکس معمولی ذخیره می‌شود."
    }

    override func analysisRegionTitle(_ region: AnalysisRegion) -> String {
        switch region {
        case .forehead: return "پیشانی"
        case .eyeArea: return "دور چشم"
        case .underEye: return "زیر چشم"
        case .brows: return "ابرو"
        case .texture: return "بافت پوست"
        case .pigmentation: return "لک و تیرگی"
        case .jawline: return "خط فک"
        case .lips: return "لب"
        case .nose: return "بینی"
        case .chin: return "چانه"
        }
    }

    override func analysisExportTitle(_ mode: AnalysisExportMode) -> String {
        switch mode {
        case .onPhoto: return "روی عکس"
        case .poster: return "پوستر با حاشیه"
        case .overlayOnly: return "فقط خط‌ها (PNG)"
        }
    }

    override func analysisTintTitle(_ tint: AnalysisTint) -> String {
        switch tint {
        case .chalk: return "سفید"
        case .lime: return "لیمویی"
        case .sky: return "آبی آسمانی"
        case .ember: return "کهربایی"
        case .ink: return "مشکی"
        }
    }

    // MARK: - Drop zone

    override var dropTitle: String { "یک عکس پرتره اینجا رها کن" }
    override var dropSubtitle: String {
        "یا از دکمهٔ پایین استفاده کن — JPEG، PNG، HEIC و TIFF پشتیبانی می‌شوند"
    }
    override var openImage: String { "باز کردن عکس" }
    override var featureSmooth: String { "پوست را صاف کن بدون آنکه چشم و لب تار شود" }
    override var featureBlemish: String { "لک‌ها را حذف کن، پوست را روشن کن" }
    override var featureTeeth: String { "دندان را سفید کن، چشم را روشن کن" }
    override var featureColor: String { "کنترل کامل رنگ، نور، شفافیت و وینیت" }
    override var featureZoom: String { "برای جابه‌جایی عکس بکش، با دو انگشت یا ⌘-اسکرول زوم کن" }

    // MARK: - Canvas controls

    override var fit: String { "برازش" }
    override var zoomOut: String { "کوچک‌نمایی (⌘−)" }
    override var zoomIn: String { "بزرگ‌نمایی (⌘+)" }
    override var fitToWindow: String { "اندازهٔ متناسب با پنجره (⌘0 یا دوبار کلیک)" }
    override var canvasHelp: String {
        "برای جابه‌جایی بکش • با دو انگشت یا ⌘-اسکرول زوم کن • دوبار کلیک برای ۱۰۰٪ • Space را نگه دار تا اصل را ببینی"
    }
    override var before: String { "قبل" }
    override var after: String { "بعد" }

    // MARK: - Export sheet

    override var format: String { "قالب" }
    override var formatHelp: String { "قالب فایل خروجی را انتخاب می‌کند." }
    override var quality: String { "کیفیت" }
    override var exportLongEdge: String { "ضلع بلند" }
    override var exportLongEdgeHelp: String {
        "بلندترین ضلع را محدود می‌کند. گزینهٔ اصلی اندازهٔ خود عکس را نگه می‌دارد."
    }
    override var exportOriginal: String { "اصلی" }
    override func exportSize(_ info: String) -> String { "خروجی: \(info)" }
    override func originalSize(_ info: String) -> String { "اندازهٔ اصلی: \(info)" }
    override func suggestedName(_ name: String) -> String { "نام پیشنهادی: \(name)" }
    override var exportUpscale: String { "بزرگ‌نمایی هوشمند ۴×" }
    override var exportUpscaleDetail: String {
        "جزئیات را با مدل محلی Swin2SR اضافه می‌کند و سپس تا ضلع انتخابی کوچک می‌کند. هیچ چیزی از این مک خارج نمی‌شود."
    }
    override var exportUpscaleTooLarge: String {
        "این عکس برای بزرگ‌نمایی ۴× بزرگ است. سقف خروجی ۴۰ مگاپیکسل، یعنی حدود ۲٫۵ مگاپیکسل ورودی است."
    }
    override func exportUpscaleEstimate(_ seconds: Int) -> String {
        let minutes = max(1, Int((Double(seconds) / 60).rounded()))
        return "حدود \(Digits.num(minutes)) دقیقه روی این مک."
    }
    override var exportUpscaleUnavailable: String {
        "دستیار هوش مصنوعی محلی نصب نیست، بنابراین از بازنمونه‌برداری استاندارد استفاده می‌شود."
    }
    override var exportUpscaleFailed: String { "بزرگ‌نمایی کامل نشد." }
    override var cancel: String { "انصراف" }
    override var save: String { "ذخیره…" }
    override var saveExport: String { "ذخیرهٔ خروجی…" }
    override var exportFullQuality: String {
        "خروجی همیشه با کیفیت و اندازهٔ کامل اصلی نوشته می‌شود."
    }
    override var watermarkSection: String { "واترمارک" }
    override var watermarkText: String { "متن" }
    override var watermarkTextPlaceholder: String { "نام یا ©" }
    override var watermarkOpacity: String { "شفافیت" }
    override var watermarkSize: String { "اندازه" }
    override var watermarkNote: String {
        "فقط روی نسخهٔ ذخیره‌شده کشیده می‌شود؛ پیش‌نمایش دست‌نخورده می‌ماند."
    }
    override func watermarkPosition(_ position: WatermarkSettings.Position) -> String {
        switch position {
        case .topLeft: return "بالا چپ"
        case .topRight: return "بالا راست"
        case .bottomLeft: return "پایین چپ"
        case .bottomRight: return "پایین راست"
        case .center: return "وسط"
        }
    }
    override var histogramLabel: String { "هیستوگرام" }

    // MARK: - Menus

    override var retouchMenu: String { "رتوش" }
    override var languageMenu: String { "زبان" }
    override var openMenu: String { "باز کردن عکس…" }
    override var closeWindow: String { "بستن پنجره" }
    override var exportMenu: String { "خروجی…" }
    override var resetMenu: String { "بازنشانی همهٔ تنظیمات" }
    override var showCompareMenu: String { "نمایش مقایسه" }
    override var showFaceOverlayMenu: String { "نمایش پوشش چهره" }
    override var zoomInMenu: String { "بزرگ‌نمایی" }
    override var zoomOutMenu: String { "کوچک‌نمایی" }
    override var fitMenu: String { "اندازهٔ متناسب با پنجره" }

    // MARK: - Smart Analyze

    override var smartAnalyze: String { "تحلیل هوشمند" }
    override var smartSubtitle: String { "چهره را می‌خواند، بعد اصلاح‌ها را پیشنهاد می‌دهد." }
    override var smartAction: String { "تحلیل" }
    override var smartReview: String { "دیدن گزارش" }
    override var smartHelp: String {
        "بافت پوست، لک‌ها، چروک‌ها، سایهٔ زیر چشم، براقی، ناهماهنگی رنگ، دندان و چشم را اندازه می‌گیرد و پیش از هر تغییری یافته‌ها را نشان می‌دهد. (⇧⌘A)"
    }
    override var smartSheetTitle: String { "این عکس چه چیزی لازم دارد" }
    override var smartSheetSubtitle: String {
        "هنوز چیزی تغییر نکرده. هر چه نمی‌خواهی خاموش کن، بعد اعمال کن."
    }
    override var smartPhotoSection: String { "رنگ و نور" }
    override var smartFaceSection: String { "چهره" }
    override var smartFindings: String { "یافته‌ها" }
    override var smartNothingFound: String { "چیز خاصی دیده نشد — این عکس از قبل خوب است." }
    override var smartApplyRetouch: String { "اسلایدرهای رتوش" }
    override var smartApplyColor: String { "رنگ و نور" }
    override var smartApplyHeal: String { "ترمیم لک‌های پیدا‌شده" }
    override var smartNoSpots: String { "لک جداافتاده‌ای پیدا نشد" }
    override func smartSpotCount(_ n: Int) -> String {
        n == 1 ? "۱ لک ترمیم می‌شود" : "\(Digits.num(n)) لک ترمیم می‌شود"
    }
    override var smartApply: String { "اعمال پیشنهادها" }
    override var smartCancel: String { "انصراف" }
    override var analyzingSmart: String { "در حال خواندن چهره…" }
    override var smartFailed: String { "این عکس تحلیل نشد." }
    override var smartReady: String { "تحلیل آماده است — یافته‌ها را ببین." }
    override var smartApplied: String { "پیشنهادهای هوشمند اعمال شد." }
    override func smartAppliedReport(_ measures: [String]) -> String {
        "اعمال شد: " + measures.joined(separator: "، ") + "."
    }
    override func smartSummary(_ findings: Int, _ faces: Int) -> String {
        findings == 1
            ? "۱ یافته روی \(Digits.num(faces)) چهره"
            : "\(Digits.num(findings)) یافته روی \(Digits.num(faces)) چهره"
    }
    override var smartNoFace: String {
        "چهره‌ای تشخیص داده نشد. تحلیل هوشمند باز هم رنگ و نور را می‌خواند، ولی ابزارهای پوست به چهره نیاز دارند."
    }

    // MARK: - Settings, About, Help

    override var settingsTitle: String { "تنظیمات" }
    override var settingsWindowTitle: String { "\(settingsTitle) \(appName)" }
    override var settingsLanguage: String { "زبان" }
    override var settingsLanguageHelp: String { "زبان رابط برنامه را انتخاب کن." }
    override var settingsAuto: String { "خودکار" }
    override var settingsAutoNote: String {
        "اینکه از هر اصلاح اندازه‌گیری‌شده چقدر اعمال شود."
    }
    override var settingsExport: String { "خروجی" }
    override var settingsExportHelp: String {
        "قالب، کیفیت و مشخصات فایل برای نسخه‌های ذخیره‌شده."
    }
    override var settingsStripMetadata: String { "حذف مشخصات هویتی تصویر" }
    override var settingsStripMetadataNote: String {
        "GPS، سازنده و مدل دوربین، شمارهٔ سریال، نام پدیدآورنده، زمان ثبت و دیگر مشخصات هویتی از خروجی حذف می‌شوند. جهت، وضوح و پروفایل رنگ حفظ می‌شوند."
    }
    override var settingsTools: String { "ابزارها" }
    override var settingsToolsHelp: String { "اندازهٔ قلم ترمیم و نمایش کادر چهره." }
    override var settingsRecovery: String { "بازیابی" }
    override var settingsRecoveryToggle: String { "یک نسخهٔ بازیابی از کار ذخیره‌نشده نگه دار" }
    override var settingsRecoveryNote: String {
        "بعد از کرش یا خروج اجباری باقی می‌ماند. به‌محض ذخیره یا خروجی گرفتن پاک می‌شود."
    }
    override var settingsFaceOverlay: String { "نمایش کادر و نواحی چهره" }
    override var settingsBrush: String { "اندازهٔ قلم‌موی ترمیم" }
    override var settingsReset: String { "برگرداندن به حالت اولیه" }
    override var settingsResetNote: String {
        "مقادیر اولیه برمی‌گردند. عکسی که باز است همان اسلایدرهای فعلی را نگه می‌دارد."
    }
    override var settingsResetStatus: String { "ترجیحات به حالت اولیه برگشتند." }

    // AI models
    override var settingsModels: String { "مدل‌های هوش مصنوعی" }
    override var settingsModelsNote: String {
        "دانلود مدل یک‌بار به اینترنت نیاز دارد؛ بعد از آن همهٔ ابزارها آفلاین کار می‌کنند."
    }
    override var settingsModelsManage: String { "مدیریت مدل‌ها…" }
    override var modelsTitle: String { "مدل‌های هوش مصنوعی" }
    override var modelsOfflineNote: String {
        "مدل‌ها روی همین مک اجرا می‌شوند. چیزی آپلود نمی‌شود و هیچ مدلی بدون تأیید شما دانلود نمی‌شود."
    }
    override var modelsInstalled: String { "نصب‌شده" }
    override var modelsMissing: String { "نصب نشده" }
    override var modelsDownload: String { "دانلود…" }
    override var modelsDownloadAgain: String { "دانلود دوباره…" }
    override var modelsVerify: String { "بررسی" }
    override var modelsRemove: String { "حذف…" }
    override var modelsClose: String { "تمام" }
    override var modelsChecking: String { "در حال بررسی…" }
    override var modelsVerified: String { "چک‌سام مطابقت دارد." }
    override func modelsVerifyFailed(_ file: String) -> String {
        "چک‌سام مطابقت ندارد: \(file)"
    }
    override func modelsDownloadTitle(_ name: String) -> String { "دانلود \(name)؟" }
    override func modelsDownloadBody(files: Int, size: String, license: String) -> String {
        "\(files) فایل، \(size). مجوز: \(license). این تنها مرحله‌ای است که از اینترنت استفاده می‌کند."
    }
    override var modelsDownloadAction: String { "دانلود" }
    override var modelsCancel: String { "انصراف" }
    override func modelsDownloading(_ percent: Int) -> String {
        "در حال دانلود… \(Digits.num(percent))٪"
    }
    override var modelsDownloadingUnknown: String { "در حال دانلود…" }
    override func modelsDownloaded(_ name: String) -> String { "\(name) نصب شد." }
    override var modelsDownloadCancelled: String { "دانلود لغو شد. چیزی نصب نشد." }
    override var modelsDownloadFailed: String { "دانلود کامل نشد. چیزی نصب نشد." }
    override func modelsRemoveTitle(_ name: String) -> String { "حذف \(name)؟" }
    override var modelsRemoveBody: String {
        "فایل‌های مدل از این مک حذف می‌شوند. بعداً می‌توانید دوباره دانلودشان کنید."
    }
    override var modelsRemoveAction: String { "حذف" }
    override func modelsRemoved(_ name: String) -> String { "\(name) حذف شد." }
    override var modelsSizeUnknown: String { "اندازه نامعلوم" }
    override var aiRuntimeTitle: String { "دستیار هوش مصنوعی" }
    override var aiRuntimeInstalledChip: String { "نصب شده" }
    override var aiRuntimeMissingChip: String { "نصب نیست" }
    override var aiRuntimeBody: String {
        "ابزارهای هوش مصنوعی به یک دستیار محلی، حدود ۳۹۰ مگابایت، نیاز دارند. اپ آن را فقط بعد از نمایش فایل، حجم و SHA256 و تأیید شما دانلود می‌کند."
    }
    override var aiRuntimeInstall: String { "دانلود دستیار" }
    override var aiRuntimeDownloadTitle: String { "دستیار هوش مصنوعی دانلود شود؟" }
    override func aiRuntimeDownloadBody(file: String, size: String, hash: String) -> String {
        "فایل \(file) (\(size)) از github.com دانلود می‌شود و SHA256 آن (\(hash)) پیش از نصب بررسی می‌شود. وزن مدل‌ها همچنان جداگانه و با تأیید خودشان دانلود می‌شوند."
    }
    override var aiRuntimeDownloading: String { "در حال دانلود دستیار…" }
    override var aiRuntimeVerifying: String { "در حال بررسی دانلود…" }
    override var aiRuntimeInstalling: String { "در حال نصب دستیار…" }
    override var aiRuntimeDownloadFailed: String { "دستیار دانلود نشد. چیزی نصب نشد." }
    override var aiRuntimeChecksumFailed: String {
        "فایل دانلودشده با SHA256 مطابقت ندارد. چیزی نصب نشد."
    }
    override var aiRuntimeExtractFailed: String { "دستیار باز نشد. چیزی نصب نشد." }
    override var aiRuntimeInstallFailed: String {
        "دستیار نصب نشد. نسخهٔ قبلی حفظ شد."
    }
    override var aiRuntimeInstallFailedNothing: String {
        "دستیار نصب نشد. نسخهٔ قبلی‌ای وجود نداشت که جایگزین شود."
    }
    override var aiRuntimeInstallFailedRollback: String {
        "دستیار نصب نشد و نسخهٔ قبلی هم بازگردانده نشد. از تنظیمات دوباره دانلودش کن."
    }
    override var aiRuntimeInstallFailedPreserved: String {
        "دستیار نصب نشد. نسخهٔ قبلی برای بازیابی حفظ شد و دوباره تلاش می‌شود."
    }
    override var aiRuntimeRecoveryFailed: String {
        "دستیار هوش مصنوعی به‌طور ایمن بازیابی نشد. فایل‌های موجود حفظ شدند؛ اپ را دوباره باز کن یا از تنظیمات دستیار را دوباره دانلود کن."
    }
    override var aiRuntimeValidationFailed: String {
        "دستیار نصب‌شده آزمون راه‌اندازی را نگذراند. اپ را دوباره باز کن یا از تنظیمات دستیار را دوباره دانلود کن."
    }
    override var aiRuntimeBusy: String {
        "دستیار هوش مصنوعی همین حالا در پنجرهٔ دیگری از برنامه در حال استفاده است. آن پنجره را ببند و دوباره تلاش کن."
    }
    override var aiRuntimeInstalledNote: String { "نصب شد — حالا می‌توانی مدل‌ها را دانلود کنی." }
    override var aiRuntimeNotInstalled: String {
        "دستیار هوش مصنوعی نصب نیست. از تنظیمات → مدل‌های AI دانلودش کن و دوباره تلاش کن."
    }
    override var aiRuntimeIntelUnavailable: String {
        "دستیار هوش مصنوعی فقط روی Apple silicon اجرا می‌شود. این مک اینتل ویرایشگر کامل را بدون AI دارد."
    }
    override var aiRuntimeUnavailable: String {
        "دستیار هوش مصنوعی هنوز در این نسخه در دسترس نیست. بقیهٔ ویرایشگر بدون آن کار می‌کند."
    }
    override var aiHelperStarting: String {
        "دستیار هوش مصنوعی هنوز در حال راه‌اندازی است. لحظه‌ای بعد دوباره تلاش کن."
    }
    override var modelsHelperMissing: String {
        "دستیار هوش مصنوعی روی این مک در دسترس نیست."
    }
    override func modelsTaskName(_ task: String) -> String {
        switch task {
        case "segmentation": return "انتخاب"
        case "upscaling": return "بزرگ‌نمایی"
        case "inpainting": return "ترمیم"
        case "generative-edit": return "حذف شیء"
        default: return task
        }
    }
    override func modelsUsedFor(_ action: String) -> String { "کاربرد: \(action)" }
    override var modelsInUse: String { "در حال استفاده" }
    override var modelsNeverUsed: String { "هنوز استفاده نشده" }
    override func modelsLastUsed(_ when: String) -> String { "آخرین استفاده: \(when)" }
    override var modelsJustNow: String { "همین حالا" }
    override func modelsMinutesAgo(_ count: Int) -> String {
        "\(Digits.num(count)) دقیقه پیش"
    }
    override func modelsHoursAgo(_ count: Int) -> String {
        "\(Digits.num(count)) ساعت پیش"
    }
    override func modelsDaysAgo(_ count: Int) -> String {
        "\(Digits.num(count)) روز پیش"
    }

    override var aboutTitle: String { "دربارهٔ Retouch Studio" }
    override var aboutTagline: String { "رتوش پرتره، با اندازه‌گیری." }
    override var aboutDescription: String {
        "Retouch Studio یک برنامهٔ رتوش پرترهٔ محلی برای مک است. اول عکس را می‌سنجد — پوست، چشم‌ها، دندان‌ها، مو، نور و کادر — تا ویرایش خودکار فقط همان چیزی را تغییر دهد که اندازه‌گیری‌ها توجیه می‌کنند؛ بعد دوازده ابزار در اختیارتان می‌گذارد: پوست، درمان، اصلاح فرم، چشم و دندان، آرایش، رنگ و نور، ظاهرها، برش، بدن، پس‌زمینه، برچسب‌ها و تحلیل. هر تغییری غیرمخرب است: می‌توانید آن را برگردانید، نشست را به‌صورت پروژهٔ .retouch ذخیره کنید یا با کیفیت کامل خروجی بگیرید."
    }
    override var aboutVersion: String { "نسخه" }
    override var aboutDeveloper: String { "توسعه‌دهنده" }
    override var aboutDeveloperRole: String { "نقش" }
    override var aboutDeveloperRoleValue: String { "طراحی و توسعه" }
    override var aboutContact: String { "تماس" }
    override var aboutWebsite: String { "وب‌سایت" }
    override var aboutCopyright: String { "کپی‌رایت" }
    override var aboutRights: String { "تمامی حقوق محفوظ است." }
    override var aboutEngine: String {
        "همه‌چیز روی همین مک اجرا می‌شود — بدون حساب، بدون آپلود و بدون جمع‌آوری آمار. ساخته‌شده با SwiftUI، Core Image و Vision؛ دستیار اختیاری هوش مصنوعی روی Apple silicon کار می‌کند."
    }
    override var settingsDeveloper: String { "توسعه‌دهنده" }
    override var settingsDeveloperHelp: String { "سازندهٔ برنامه و نسخهٔ در حال اجرا." }
    override var helpTitle: String { "راهنمای Retouch Studio" }
    override var helpIntro: String {
        "یک پرتره باز کن، با تحلیل هوشمند بخوانش و بعد با دست خودت تنظیم کن. همه چیز روی همین مک انجام می‌شود — هیچ عکسی آپلود نمی‌شود."
    }
    override var helpWorkflow: String { "مسیر کار" }
    override var helpShortcuts: String { "کلیدها" }
    override var helpWorkflowSteps: [String] {
        ["یک عکس باز کن یا رها کن.",
         "با تحلیل هوشمند ببین چهره چه لازم دارد.",
         "پیشنهادها را اعمال کن و بعد با اسلایدرها تنظیم کن.",
         "پروژه را ذخیره کن یا خروجی بگیر."]
    }
    override var helpShortcutRows: [(String, String)] {
        [("⌘O", "باز کردن عکس"),
         ("⇧⌘O", "باز کردن پروژه"),
         ("⌘S / ⇧⌘S", "ذخیرهٔ پروژه / ذخیره با نام"),
         ("⌘E / ⇧⌘E", "خروجی / خروجی گروهی"),
         ("⇧⌘A", "تحلیل هوشمند"),
         ("⌘R", "بازنشانی همهٔ تنظیمات"),
         ("⌘Z / ⇧⌘Z", "واگرد / ازنو"),
         ("⌘,", "تنظیمات"),
         ("⌘+ / ⌘− / ⌘0", "بزرگ‌نمایی / کوچک‌نمایی / برازش"),
         ("۱–۰", "انتخاب ابزار"),
         ("[ / ]", "اندازهٔ قلم‌موی ترمیم"),
         ("Space", "نگه داشتن برای دیدن اصل")]
    }

    // MARK: - Recent files and recovery

    override var openRecentMenu: String { "باز کردن اخیر" }
    override var openRecentEmpty: String { "فایل اخیری نیست" }
    override var clearRecentMenu: String { "پاک کردن فهرست" }
    override func recentMissing(_ name: String) -> String { "\(name) دیگر در آن مسیر نیست." }
    override var recoveryTitle: String { "کار ذخیره‌نشده باز شود؟" }
    override func recoveryMessage(_ name: String) -> String {
        "Retouch Studio ویرایش‌های ذخیره‌نشدهٔ \(name) را پیدا کرد؛ وقتی اپ غیرمنتظره بسته شد از باقی مانده بود."
    }
    override func recoveryChangedMessage(_ name: String) -> String {
        "\(name) پس از ذخیرهٔ این ویرایش‌ها روی دیسک تغییر کرده است. بازیابی، ویرایش‌ها را روی عکس کنونی اعمال می‌کند."
    }
    override var recoveryRestore: String { "بازیابی ویرایش‌ها" }
    override var recoveryDiscard: String { "دور ریختن" }

    // MARK: - Named things

    override func toolTitle(_ tool: ToolMode) -> String {
        switch tool {
        case .skin: return "پوست"
        case .heal: return "ترمیم"
        case .reshape: return "تغییر شکل"
        case .detail: return "چشم و دندان"
        case .makeup: return "آرایش"
        case .color: return "رنگ و نور"
        case .look: return "ظاهرها"
        case .crop: return "برش"
        case .body: return "بدن"
        case .background: return "پس‌زمینه"
        case .art: return artTitle
        case .analysis: return analysisTitle
        }
    }

    override func toolSubtitle(_ tool: ToolMode) -> String {
        switch tool {
        case .skin: return "بافت، رنگ و لک"
        case .heal: return "ترمیم دستی لک‌ها"
        case .reshape: return "تغییر شکل اجزای چهره"
        case .detail: return "سفید کردن دندان و روشن کردن چشم"
        case .makeup: return "لب، گونه و ابرو"
        case .color: return "نوردهی، رنگ و نور"
        case .look: return "تُن فیلمی و دانه‌بندی"
        case .crop: return "قاب‌بندی دوبارهٔ عکس"
        case .body: return "هموارسازی، رنگ و لاغرتر کردن"
        case .background: return "محو و رنگ‌بندی آنچه پشت سوژه است"
        case .art: return artSubtitle
        case .analysis: return analysisSubtitle
        }
    }

    override var presetsHint: String { "نقطهٔ شروع برای پوست، فرم و رنگ" }

    override func panelTitle(_ panel: Panel) -> String {
        switch panel {
        case .presets: return "پیش‌تنظیم‌ها"
        case .skin: return "پوست"
        case .shape: return "شکل"
        case .eyes: return "چشم و دندان"
        case .makeup: return "آرایش"
        case .color: return "رنگ و نور"
        case .looks: return "ظاهرها"
        case .body: return "بدن"
        case .background: return "پس‌زمینه"
        case .art: return artTitle
        case .analysis: return analysisTitle
        }
    }

    override func lookTitle(_ look: FilmLook) -> String {
        switch look {
        case .none: return "بدون"
        case .warmGold: return "طلایی گرم"
        case .portraitFilm: return "پرتره"
        case .nightStock: return "شب"
        case .crossProcess: return "کراس‌پروسس"
        case .fadedMatte: return "مات کم‌رنگ"
        }
    }

    override func makeupFamilyTitle(_ family: MakeupFamily) -> String {
        switch family {
        case .fair: return "روشن"
        case .light: return "باز"
        case .medium: return "متوسط"
        case .tan: return "گندمی"
        case .deep: return "تیره"
        }
    }

    override func makeupRegionTitle(_ region: MakeupRegion) -> String {
        switch region {
        case .lips: return "لب"
        case .cheeks: return "گونه"
        case .contour: return "کانتور"
        case .shadow: return "سایه"
        case .liner: return "خط چشم"
        case .brows: return "ابرو"
        case .hair: return "مو"
        }
    }

    override func cropAspectTitle(_ aspect: CropAspect) -> String {
        switch aspect {
        case .free: return "آزاد"
        case .original: return "اصلی"
        case .square: return "۱:۱"
        case .portrait: return "۴:۵"
        case .wide: return "۱۶:۹"
        }
    }

    override func hueBandTitle(_ band: HSLBand) -> String {
        switch band {
        case .red: return "قرمز"
        case .orange: return "نارنجی"
        case .yellow: return "زرد"
        case .green: return "سبز"
        case .cyan: return "فیروزه‌ای"
        case .blue: return "آبی"
        case .purple: return "بنفش"
        case .magenta: return "سرخابی"
        }
    }

    override func presetGroupTitle(_ group: PresetGroup) -> String {
        switch group {
        case .everyday: return "هر روزه"
        case .skin: return "پوست"
        case .beauty: return "زیبایی"
        case .color: return "رنگ"
        case .film: return "فیلم"
        case .makeup: return "آرایش"
        }
    }

    override func presetTitle(_ id: PresetID) -> String {
        switch id {
        case .natural: return "طبیعی"
        case .clean: return "تمیز"
        case .fresh: return "تازه"
        case .minimal: return "تقریباً هیچ"
        case .softlight: return "نور ملایم"
        case .airbrush: return "ایرپراش"
        case .texture: return "بافت حفظ‌شده"
        case .matte: return "مات"
        case .glow: return "درخشش شبنمی"
        case .eventone: return "رنگ یکدست"
        case .bronze: return "برنزی"
        case .porcelain: return "چینی"
        case .glamour: return "گلامور"
        case .studio: return "استودیویی"
        case .editorial: return "ادیتوریال"
        case .beauty: return "زیبایی"
        case .bridal: return "عروس"
        case .sculpt: return "اسکالپت"
        case .male: return "مردانه"
        case .warmsun: return "آفتاب گرم"
        case .cool: return "تُن سرد"
        case .vibrant: return "پرمایه"
        case .muted: return "کم‌رنگ"
        case .pastel: return "پاستلی"
        case .punchy: return "تند"
        case .fade: return "محو"
        case .noir: return "نوآر"
        case .monosoft: return "تک‌رنگ نرم"
        case .golden: return "ساعت طلایی"
        case .portra: return "فیلم پرتره"
        case .cinema: return "سینمایی"
        case .faded: return "چاپ محو"
        case .cross: return "کراس‌پروسس"
        case .kodachrome: return "اسلاید کهنه"
        case .rose: return "رز"
        case .coral: return "مرجانی"
        case .berry: return "توتی"
        case .redcarpet: return "فرش قرمز"
        case .nude: return "بدون آرایش"
        case .brows: return "ابروهای تعریف‌شده"
        }
    }

    // MARK: - Smart Analyze findings

    override func findingTitle(_ kind: SmartAnalyzer.Finding.Kind) -> String {
        switch kind {
        case .texture: return "بافت پوست"
        case .blemish: return "لک‌ها"
        case .wrinkles: return "چروک‌های ریز"
        case .darkCircles: return "سایهٔ زیر چشم"
        case .shine: return "براقی"
        case .unevenTone: return "ناهمگونی رنگ"
        case .teeth: return "دندان"
        case .eyes: return "چشم"
        case .exposure: return "نوردهی"
        case .contrast: return "کنتراست"
        case .levels: return "سطوح"
        case .whiteBalance: return "تعادل رنگ سفید"
        case .color: return "رنگ"
        case .detail: return "جزئیات"
        case .balanced: return "رنگ و نور"
        }
    }

    override func findingDetail(_ detail: SmartAnalyzer.Finding.Detail) -> String {
        switch detail {
        case .texturePronounced: return "منافذ و بافت پوست پررنگ است"
        case .textureVisible: return "بافت کمی پیداست"
        case .textureFine: return "بافت پوست خوب است — هموارسازی کم نگه داشته شد"
        case .spots(let count):
            return count == 1 ? "۱ لک پیدا شد" : "\(Digits.num(count)) لک پیدا شد"
        case .linesHeavy: return "چروک روی پیشانی و دور چشم"
        case .linesLight: return "چند چروک ریز"
        case .underEyeStrong: return "به‌وضوح تیره‌تر از گونه"
        case .underEyeMild: return "کمی تیره‌تر از گونه"
        case .underEyeFaint: return "به‌سختی دیده می‌شود"
        case .shineHeavy: return "ناحیهٔ T نور را بازتاب می‌دهد"
        case .shineLight: return "کمی براقی در ناحیهٔ T"
        case .tonePatchy: return "ناهمگونی رنگ روی پوست دیده می‌شود"
        case .toneSlight: return "کمی تفاوت در رنگ پوست"
        case .teethWarm: return "دندان‌ها گرم به نظر می‌رسند — سفید کردن کمک می‌کند"
        case .teethSlight: return "گرمای ملایمی در دندان‌ها هست"
        case .eyesDim: return "سفیدی چشم می‌تواند روشن‌تر شود"
        case .eyesCatchlight: return "جزئیات بازتاب چشم می‌تواند واضح‌تر شود"
        case .exposureDark: return "عکس کمی تاریک است"
        case .exposureBright: return "عکس کمی روشن است"
        case .contrastFlat: return "میان‌تُن‌ها تخت‌اند"
        case .levelsFaded: return "دو سر محدودهٔ روشنایی محو شده"
        case .castBlue: return "ته‌رنگ آبی"
        case .castWarm: return "ته‌رنگ گرم"
        case .colorDull: return "رنگ‌ها کمی کم‌جان‌اند"
        case .detailSoft: return "قاب کمی نرم است"
        case .balanced: return "از قبل متعادل است"
        }
    }

    // MARK: - Cards and controls

    override var closeButton: String { "بستن" }
    override var healingBrush: String { "قلم‌موی ترمیم" }
    override var brushSize: String { "اندازه" }
    override var brushShortcutHint: String { "قطر قلم ترمیم را تعیین می‌کند. با [ و ] هم تغییر می‌کند." }
    override var stamps: String { "مهرها" }
    override var clearStamps: String { "پاک کردن مهرها" }
    override var cropTool: String { "برش" }
    override var cropToolSubtitle: String { "قاب را روی عکس بکش" }
    override var cropAspectLabel: String { "نسبت" }
    override var cropSize: String { "اندازهٔ برش" }
    override var workingSize: String { "اندازهٔ کاری" }
    override var applyCrop: String { "اعمال برش" }
    override var resetCrop: String { "بازنشانی برش" }
    override var lookStrength: String { "شدت" }
    override var grain: String { "دانه‌بندی" }
    override var lookNote: String {
        "این تُن بعد از رنگ و نور روی کل عکس اعمال می‌شود، پس تعادلی را که خودت ساخته‌ای دوباره شکل می‌دهد."
    }
    override var resetSliderHelp: String { "بازنشانی همین اسلایدر" }
    override var choosePhotoToRetouch: String { "یک عکس برای رتوش انتخاب کن" }
    override var chooseExportLocation: String { "جای ذخیرهٔ تصویر رتوش‌شده را انتخاب کن" }
    override var smartAlreadyZero: String { "همه صفر هستند" }
    override var smartAlreadyBalanced: String { "از قبل متعادل است" }
    override var smartShortSmooth: String { "هموارسازی" }
    override var smartShortBlemish: String { "لک" }
    override var smartShortLines: String { "چروک" }
    override var smartShortTone: String { "لحن" }
    override var smartShortUnderEye: String { "زیر چشم" }
    override var smartShortShine: String { "براقی" }
    override var smartShortBrighten: String { "روشنایی" }
    override var smartShortTeeth: String { "دندان" }
    override var smartShortEyes: String { "چشم" }
    override var smartShortExposure: String { "نوردهی" }
    override var smartShortContrast: String { "کنتراست" }
    override var smartShortBlacks: String { "سیاهی" }
    override var smartShortWhites: String { "سفیدی" }
    override var smartShortSaturation: String { "اشباع" }
    override var smartShortVibrance: String { "شادابی" }
    override var smartShortWarmth: String { "گرمی" }
    override var smartShortClarity: String { "شفافیت" }
    override func smartFrameShare(_ percent: Int) -> String {
        "\(Digits.num(percent))٪ از قاب"
    }
    override func smartFaceLabel(_ index: Int) -> String {
        "\(smartFaceSection) \(Digits.num(index + 1))"
    }

    // MARK: - AI

    override var aiSection: String { "ویرایش هوش مصنوعی" }
    override var aiQuickEdit: String { "ویرایش سریع" }
    override var aiRemoveObject: String { "حذف شیء" }
    override var aiRemoveObjectHelp: String {
        "روی شیء در عکس کلیک کن. هوش مصنوعی فقط همان ناحیه را بازسازی می‌کند و بقیهٔ پیکسل‌ها دست‌نخورده می‌مانند."
    }
    override var aiSelectHint: String { "روی شیئی که باید حذف شود کلیک کن" }
    override var aiMaskPoint: String { "نقطه" }
    override var aiMaskBrush: String { "قلم‌مو" }
    override var aiMaskBox: String { "کادر" }
    override var aiMaskClear: String { "پاک کردن" }
    override var aiMaskErase: String { "پاک‌کن" }
    override var aiMaskBrushSize: String { "اندازهٔ قلم‌مو" }
    override var aiMaskExpand: String { "گسترش" }
    override var aiMaskFeather: String { "نرمی لبه" }
    override var aiMaskInvert: String { "معکوس" }
    override var aiMaskSnap: String { "چسبیدن به لبه‌ها" }
    override var aiMaskSnapping: String { "در حال یافتن لبه‌ها…" }
    override var aiMaskHint: String { "روی چیزی که باید تغییر کند بکش" }
    override var aiMaskBoxHint: String { "دور ناحیه را بکش" }
    override var aiHealArea: String { "ترمیم ناحیهٔ کوچک" }
    override var aiHealAreaHelp: String {
        "روی یک لکهٔ کوچک بکش. مدل ترمیم محلی آن را در کمتر از یک ثانیه از بافت اطراف پر می‌کند."
    }
    override var aiReimagine: String { "بازآفرینی" }
    override var aiReimagineHelp: String {
        "تغییر را توصیف کن. هوش مصنوعی کل کادر را از روی حرف تو از نو می‌کشد — سوژه شناخته‌شدنی می‌ماند، اما همهٔ پیکسل‌ها تازه‌اند."
    }
    override var aiRunReimagine: String { "بازآفرینی عکس" }
    override var aiPromptLabel: String { "تغییر را توصیف کن" }
    override var aiPromptPlaceholder: String { "مثلاً نور ساعت طلایی، حال‌وهوای فیلمی نرم" }
    override var aiPromptNote: String {
        "کل عکس از نو ساخته می‌شود. قلم‌مو، نقطه و کادر اینجا کاربردی ندارند."
    }
    override var aiMaskFailed: String { "آماده‌سازی انتخاب ممکن نشد." }
    override var aiMaskTooLarge: String {
        "این انتخاب برای این ابزار بزرگ است. «حذف شیء» یا ناحیهٔ کوچک‌تری را انتخاب کن."
    }
    override var aiModelMissing: String {
        "مدل‌های محلی هوش مصنوعی نصب نیستند. از تنظیمات → مدیریت مدل‌ها… دانلودشان کن."
    }
    override var aiLicenseBlocked: String {
        "این مدل هوش مصنوعی برای استفاده روی این مک مجاز اعلام نشده."
    }
    override var aiRunEdit: String { "اجرای ویرایش" }
    override var aiCancelEdit: String { "لغو" }
    override var aiTryAgain: String { "ویرایش ناحیهٔ دیگر" }
    override var aiEditCount: String { "ویرایش‌های هوش مصنوعی" }
    override var aiRemoveLastEdit: String { "حذف آخرین ویرایش هوش مصنوعی" }
    override var aiLocalNote: String { "روی همین مک اجرا می‌شود. چیزی آپلود نمی‌شود." }
    override var aiHelperMissing: String {
        "دستیار محلی هوش مصنوعی نصب نیست. مراحل نصب را در بخش هوش مصنوعی تنظیمات ببین."
    }
    override var aiHelperStopped: String {
        "دستیار محلی هوش مصنوعی پاسخ نمی‌دهد. برای راه‌اندازی دوباره، ویرایش را از نو اجرا کن."
    }
    override var aiHelperWriteFailed: String {
        "ارتباط با دستیار محلی هوش مصنوعی برقرار نشد. برای راه‌اندازی دوباره، ویرایش را از نو اجرا کن."
    }
    override var aiTooLarge: String {
        "این ناحیه برای یک ویرایش محلی بزرگ است. شیء کوچک‌تری انتخاب کن."
    }
    override var aiBadReply: String { "دستیار هوش مصنوعی نتیجهٔ غیرمنتظره‌ای برگرداند." }
    override var aiMissingAssets: String {
        "پیکسل‌های یکی از ویرایش‌های هوش مصنوعی پیدا نشد و نمایش داده نمی‌شود. ویرایش را دوباره انجام بده یا حذفش کن."
    }
    override func aiAssetsMissing(_ count: Int) -> String {
        count == 1
            ? aiMissingAssets
            : "پیکسل‌های \(Digits.num(count)) ویرایش هوش مصنوعی پیدا نشد و نمایش داده نمی‌شوند."
    }
    override var aiWorking: String { "در حال ساخت ویرایش روی این مک…" }
    override var aiApplied: String { "ویرایش هوش مصنوعی اعمال شد" }
    override var aiStageIdle: String { "آماده" }
    override var aiStagePreparing: String { "آماده‌سازی عکس…" }
    override var aiStageStarting: String { "راه‌اندازی دستیار هوش مصنوعی…" }
    override var aiStageWaiting: String {
        "در حال ساخت. روی این مک چند ثانیه تا حدود یک دقیقه طول می‌کشد."
    }
    override func aiStageDenoising(_ step: Int, of total: Int) -> String {
        "در حال ساخت — گام \(Digits.num(step)) از \(Digits.num(total))"
    }
    override func aiStageFinished(_ seconds: Double) -> String {
        let value = String(format: "%.0f", seconds.rounded())
        return "در \(Digits.convert(value)) ثانیه انجام شد"
    }
}

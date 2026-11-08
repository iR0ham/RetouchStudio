import Foundation

/// One step inside a tutorial section: a short imperative heading and the
/// sentence that explains it.
struct TutorialStep: Identifiable {
    let title: String
    let body: String

    var id: String { title }
}

/// A chapter of the in-app tutorial. The four AI paths are separate sections
/// on purpose: each one has its own model, its own limits and its own place in
/// the workflow.
struct TutorialSection: Identifiable {
    let id: String
    let group: String
    let title: String
    let icon: String
    /// "AI 1" … "AI 4" on the four model-backed paths, nil everywhere else.
    let badge: String?
    let lead: String
    let steps: [TutorialStep]
    let note: String?

    init(id: String, group: String, title: String, icon: String,
         badge: String? = nil, lead: String, steps: [TutorialStep], note: String? = nil) {
        self.id = id
        self.group = group
        self.title = title
        self.icon = icon
        self.badge = badge
        self.lead = lead
        self.steps = steps
        self.note = note
    }
}

private func step(_ title: String, _ body: String) -> TutorialStep {
    TutorialStep(title: title, body: body)
}

/// The whole guide, written twice. Keeping the long-form copy out of `L10n`
/// means the string table stays the place for short interface labels, while the
/// tutorial can grow without turning that file into a book.
struct TutorialCopy {
    let windowTitle: String
    let menuTitle: String
    let buttonHelp: String
    let intro: String
    let localNote: String
    let searchPlaceholder: String
    let noResults: String
    let previous: String
    let next: String
    let shortcutTitle: String
    let shortcuts: [(String, String)]
    let sections: [TutorialSection]

    static var current: TutorialCopy {
        AppLanguage.current == .persian ? .persian : .english
    }

    // MARK: - English

    static let english = TutorialCopy(
        windowTitle: "Retouch Studio Tutorial",
        menuTitle: "Tutorial",
        buttonHelp: "Open the full tutorial",
        intro: "A complete walkthrough of every part of the app, including each of the four AI paths. Read it once, then keep it open beside your first portrait.",
        localNote: "Everything here happens on this Mac. Nothing is uploaded.",
        searchPlaceholder: "Search the tutorial",
        noResults: "No section matches that search.",
        previous: "Previous",
        next: "Next",
        shortcutTitle: "Keyboard shortcuts",
        shortcuts: [
            ("⌘O", "Open image"),
            ("⇧⌘O", "Open project"),
            ("⌘S / ⇧⌘S", "Save project / Save As"),
            ("⌘E / ⇧⌘E", "Export / Batch export"),
            ("⇧⌘A", "Smart Analyze"),
            ("⌘Z / ⇧⌘Z", "Undo / Redo"),
            ("⌘R", "Reset all adjustments"),
            ("⌘+ / ⌘− / ⌘0", "Zoom in / out / fit"),
            ("Space", "Hold to see the original"),
            ("1 – 0", "Pick a tool"),
            ("⌘W", "Close window"),
            ("⌘,", "Settings"),
        ],
        sections: [
            TutorialSection(
                id: "start", group: "Basics", title: "Start here", icon: "sparkles",
                lead: "Every change is a plan laid over the original. You can undo it, compare it, save it as a project or throw it away — the file on disk stays as it was.",
                steps: [
                    step("Open a photo",
                         "Press ⌘O, choose Open, or drop an image on the canvas. The app reads any format macOS can open, at full resolution."),
                    step("Pick a tool",
                         "The top bar holds twelve tools. Number keys 1–0 jump to the first ten; click the pills for the rest."),
                    step("Adjust on the right",
                         "The inspector follows the active tool. The left column keeps Smart Analyze, presets and AI Edit within reach."),
                    step("Undo freely",
                         "⌘Z steps back, ⇧⌘Z steps forward, and Reset All Adjustments (⌘R) clears the plan without closing the photo."),
                    step("Finish",
                         "⌘S saves an editable project; ⌘E writes a new image file. The original is never overwritten."),
                ],
                note: "This tutorial lives in Help → Tutorial and behind the ? in the top bar."),

            TutorialSection(
                id: "smart", group: "Basics", title: "Smart Analyze & Auto Retouch", icon: "wand.and.stars",
                lead: "Smart Analyze measures the photo first: face landmarks, skin texture, tone, light, teeth and eyes. It proposes amounts; you stay in control.",
                steps: [
                    step("Run it",
                         "Press ⇧⌘A or click Smart Analyze in the left column. A face gives the most to work with; without one, colour and light are still measured."),
                    step("Read the report",
                         "Each finding shows the measured amount and what it will change. Turn off anything you do not want."),
                    step("Apply the proposal",
                         "Apply Suggestions sets the sliders to the measured fix. Nothing is locked; every value stays editable."),
                    step("Scale it",
                         "The Auto Retouch and Auto Color & Light sliders decide how much of the measured fix is used, from none to full."),
                    step("Stay gentle",
                         "A clean photo produces almost no edit. The automatic tools measure, stay near a gentle floor and never darken skin."),
                ],
                note: "Analysis is guidance, not a filter. Use it as a starting point, then tune with the sliders."),

            TutorialSection(
                id: "workspace", group: "Basics", title: "The workspace", icon: "rectangle.3.group",
                lead: "The window is four regions: the tool bar, the left cards, the canvas and the inspector.",
                steps: [
                    step("Top bar",
                         "Tools at the leading edge, the document name and undo/redo in the middle, Export at the trailing edge. The ? opens this guide."),
                    step("Left column",
                         "Smart Analyze and Auto Retouch, the Presets strip and the AI Edit card. Scroll to reach all of it."),
                    step("Canvas",
                         "Drag to pan, pinch or ⌘-scroll to zoom, double-click for 100%. Hold Space to see the original."),
                    step("Inspector",
                         "The right panel follows the active tool. Click a group header to fold it away."),
                    step("Compare",
                         "The compare control shows a before/after split. Drag the handle; Space still shows the untouched original."),
                ]),

            TutorialSection(
                id: "ai-remove", group: "AI edits", title: "AI way 1 — Remove object", icon: "eraser", badge: "AI 1",
                lead: "Remove object runs the local FLUX.2 klein 4B model to erase something and rebuild the background behind it.",
                steps: [
                    step("Choose the preset",
                         "In the AI Edit card, select Remove object."),
                    step("Mark the object",
                         "Click it directly, or switch to Box and drag around it. Brush is there for awkward shapes."),
                    step("Tighten the edges",
                         "Press Snap to edges to let SAM turn a rough mark into an edge-following mask. Refine with Brush or Erase if needed."),
                    step("Run the edit",
                         "The helper renders a 512-pixel patch with surrounding context in four steps, then composites only inside the mask. Pixels outside stay identical."),
                    step("Review",
                         "The result joins the history as one step. AI edits lists every edit; Remove the last AI edit takes it back."),
                ],
                note: "Keep the area under about 6% of the frame — larger selections are refused instead of quietly replacing the whole picture. Expect roughly 24–47 seconds on this Mac; the first run also loads the model."),

            TutorialSection(
                id: "ai-heal", group: "AI edits", title: "AI way 2 — Heal small area", icon: "bandage", badge: "AI 2",
                lead: "Heal small area runs the local MI-GAN inpaint model for spots, dust and small blemishes. It continues nearby texture instead of inventing a scene.",
                steps: [
                    step("Choose Heal small area",
                         "It is the second preset in AI Edit."),
                    step("Brush the spot",
                         "Paint over the blemish with a small brush. Point works for a single click."),
                    step("Tune the mask",
                         "Expand grows the area; Feather softens the seam. Small is the point: keep the stroke close to the flaw."),
                    step("Run",
                         "The inpaint pass usually finishes in under a second. Expand and Feather are applied to the mask before the model sees it."),
                ],
                note: "For a large or meaningful object use Remove object instead; the inpaint model is built for holes, not for rebuilding a scene."),

            TutorialSection(
                id: "ai-snap", group: "AI edits", title: "AI way 3 — Smart selection", icon: "viewfinder", badge: "AI 3",
                lead: "Snap to edges runs the SAM 2.1 tiny segmentation model. You give it a rough box or stroke; it returns a mask that follows the real boundary.",
                steps: [
                    step("Make a rough selection",
                         "Choose Box and drag loosely around the subject or object, or paint a rough stroke with Brush."),
                    step("Snap",
                         "Press Snap to edges. The worker runs SAM on the current working image and replaces the rough area with the edge-following mask."),
                    step("Refine",
                         "Add with Brush, cut with Erase, then use Expand, Feather or Invert to finish the boundary."),
                    step("Use it",
                         "The refined mask feeds either AI preset. It is also what keeps the edit from touching the rest of the photo."),
                ],
                note: "Segmentation runs locally and takes a moment on a large image. A box that fully contains the subject gives the cleanest result."),

            TutorialSection(
                id: "ai-mask", group: "AI edits", title: "Masks & precision", icon: "circle.dashed",
                lead: "Masks decide exactly where an AI edit may write. Everything outside the mask is preserved pixel for pixel.",
                steps: [
                    step("Three ways to mark",
                         "Point for a single spot, Brush to paint, Box to drag a region."),
                    step("Correct it",
                         "Brush adds, Erase removes, Clear starts over. Expand and Feather shape the edge."),
                    step("Invert",
                         "Invert flips inside and outside — useful when the subject is easier to select than the background."),
                    step("Watch the overlay",
                         "The red overlay is the live mask. What you see is what the worker receives."),
                    step("History",
                         "Each AI edit is one undo step. AI edits in the card shows how many are present."),
                ],
                note: "A selection that is too large for a local patch is refused with a message; select a smaller area instead."),

            TutorialSection(
                id: "ai-upscale", group: "AI edits", title: "AI way 4 — AI upscale 4×", icon: "arrow.up.left.and.arrow.down.right", badge: "AI 4",
                lead: "AI upscale 4× runs the local Swin2SR model during export. It adds detail, then trims to the output size you chose.",
                steps: [
                    step("Open Export",
                         "Press ⌘E. Choose format, quality and output long edge as usual."),
                    step("Turn on AI upscale 4×",
                         "The switch sits in the export sheet. It is a one-shot 4× pass, not a replacement for a sharper original."),
                    step("Check the limits",
                         "Input is capped at about 2.5 MP so the output stays under 40 MP. The sheet shows an estimate in minutes on this Mac."),
                    step("Save",
                         "The upscaled image is written to a new file. If the local helper is not installed, export falls back to the standard resampler and says so."),
                ],
                note: "Upscaling cannot recover detail the photo never had. Judge the result at 100%, not on the fit-to-window view."),

            TutorialSection(
                id: "skin", group: "Tools", title: "Skin & Healing", icon: "sparkles",
                lead: "Skin is the main event: smoothing, brightness, blemishes, tone, shine, texture and wrinkles, all protected by face detection.",
                steps: [
                    step("Start with a preset",
                         "The Presets strip above the sliders sets a coherent starting point; refine the individual values afterwards."),
                    step("Keep texture",
                         "Texture Preserve holds on to pores while smoothing. Raise it when skin starts to look plastic."),
                    step("Even the tone",
                         "Skin Tone and Blemish Removal work together; small amounts are usually enough on a good photo."),
                    step("Heal by hand",
                         "The Healing tool stamps out a spot under the brush. Brush size lives in Settings → Tools and in the healing panel."),
                ],
                note: "If no face is detected, the skin sliders have nothing to target; Smart Analyze tells you when that happens."),

            TutorialSection(
                id: "reshape", group: "Tools", title: "Reshape", icon: "face.smiling",
                lead: "Reshape moves facial features geometrically — eyes, nose, lips, cheeks, jaw, chin, face width and length — without touching the background.",
                steps: [
                    step("Open Reshape",
                         "Every control has a centre detent; double-click a slider to return it to zero."),
                    step("Small moves win",
                         "A few percent reads as a better angle. Large values read as a different person."),
                    step("Guard the rest of the frame",
                         "The tool shapes facial features only; the background is not warped."),
                ],
                note: "Reshape is geometry, not AI. It applies immediately and is fully undoable."),

            TutorialSection(
                id: "eyes", group: "Tools", title: "Eyes & Teeth", icon: "eye",
                lead: "Eyes & Teeth brightens and sharpens eyes and whitens teeth, with alignment limited to the mouth.",
                steps: [
                    step("Teeth",
                         "Whitening and Alignment only act when teeth are visible. If they are not, the app says so instead of guessing."),
                    step("Eyes",
                         "Brightness, Sharpen and Iris Detail are separate: lift the catchlight without making the whole eye glow."),
                    step("The subtle controls",
                         "Lash Depth and Contact Lens live here too; both are designed to stay quiet."),
                ],
                note: "Whitening is masked to the mouth opening, so lips and gums keep their colour."),

            TutorialSection(
                id: "makeup", group: "Tools", title: "Makeup", icon: "paintpalette",
                lead: "Makeup paints colour into the lips, cheeks, contour, shadow, liner, brows and hair, with a skin-family choice so the pigment sits believably.",
                steps: [
                    step("Pick a family",
                         "Fair, Light, Medium, Tan and Deep tune the palette to the portrait."),
                    step("One region at a time",
                         "Choose Lips, Cheeks, Contour, Shadow, Liner, Brows or Hair, then set colour and amount."),
                    step("Blend down",
                         "Amount is the difference between makeup and paint; start low and build."),
                ],
                note: "Makeup is applied as colour, not texture, so it follows the underlying shading."),

            TutorialSection(
                id: "color", group: "Tools", title: "Color & Light", icon: "camera.filters",
                lead: "A full tonal and colour workspace: exposure, contrast, blacks, whites, saturation, vibrance, warmth, clarity and vignette, plus a tone curve and HSL.",
                steps: [
                    step("Start with the basics",
                         "Auto Color & Light measures a starting point; the sliders then let you take over."),
                    step("Tone Curve",
                         "Drag a point to lift or lower shadows, midtones or highlights. The curve works on brightness only, so colours stay put."),
                    step("HSL",
                         "Pick one colour band and change its hue, saturation or luminance. Bands overlap smoothly, so a colour between two is shared, not cut."),
                    step("Vignette",
                         "Darken the corners to pull the eye inward; small amounts suit portraits."),
                ],
                note: "Clarity adds local contrast. On skin, a little goes a long way."),

            TutorialSection(
                id: "looks", group: "Tools", title: "Presets & Looks", icon: "film",
                lead: "Presets are complete starting points; Looks are film grades with grain; My Looks stores your own recipe.",
                steps: [
                    step("Presets",
                         "Everyday, Skin, Beauty, Color, Film and Makeup groups. Clicking one sets skin, shape and colour together."),
                    step("Film looks",
                         "Warm Gold, Portrait, Night Stock, Cross Process and Faded Matte add a grade and grain."),
                    step("Save your own",
                         "Set the sliders, then name the look in My Looks and press Save. Delete a saved look from the same list."),
                ],
                note: "A preset is a starting point, not a lock — every value it sets stays editable."),

            TutorialSection(
                id: "crop", group: "Tools", title: "Crop", icon: "crop",
                lead: "Crop reframes the photo without resampling it. AI edits and healing strokes are stored against the whole photo, so they stay in place when you crop.",
                steps: [
                    step("Drag the frame",
                         "Move the crop rectangle on the canvas; the handles resize it."),
                    step("Pick an aspect",
                         "Free, Original, 1:1, 4:5 or 16:9."),
                    step("Apply or reset",
                         "Apply commits the crop; Reset returns to the original framing."),
                ],
                note: "Crop is non-destructive. Export applies it; a saved project keeps it editable."),

            TutorialSection(
                id: "body", group: "Tools", title: "Body & Background", icon: "figure.stand",
                lead: "Body and Background use subject separation. Smooth and slim the figure, then blur or grade what is behind it.",
                steps: [
                    step("Find the subject",
                         "Both tools need a subject the app can separate. If none is found, they say so instead of guessing."),
                    step("Body",
                         "Smoothing, Brightness, Slim, Waist, Arms and Legs. Slim is geometric and stays inside the subject."),
                    step("Background",
                         "Blur, Tone, Saturation and Fill. Remove Background replaces it with the chosen fill colour."),
                ],
                note: "Separation is computed locally. Check the edge at 100% before export."),

            TutorialSection(
                id: "stickers", group: "Tools", title: "Stickers", icon: "star.circle",
                lead: "Stickers are drawn over the photo as vector shapes: stars, hearts, sparkles, flowers, butterflies and lightning.",
                steps: [
                    step("Place one",
                         "Pick a shape and click the canvas. Drag it to move."),
                    step("Select and delete",
                         "Click a sticker to select it; Delete Sticker removes it, Clear All starts over."),
                ],
                note: "Stickers are part of the edit plan and are flattened into the export."),

            TutorialSection(
                id: "analysis", group: "Tools", title: "Face Analysis", icon: "viewfinder",
                lead: "Face Analysis draws landmarks, shapes and leader lines on the portrait for reference — no text, no labels, just geometry.",
                steps: [
                    step("Turn it on",
                         "Enable the overlay in the Face Analysis tool."),
                    step("Choose a style",
                         "Dashed shapes or the full face mesh. Toggle the face outline and individual areas."),
                    step("Style the lines",
                         "Ink colour, weight, strength and glow; reset the dots and ends when a drag goes wrong."),
                    step("Place the leaders",
                         "Drag a dot or an end to point at a feature."),
                    step("Export",
                         "The Face analysis section in the export sheet controls its margin and whether it is burned in."),
                ],
                note: "Analysis is a reference layer; it does not change skin or colour."),

            TutorialSection(
                id: "export", group: "Finish", title: "Export, projects & batch", icon: "square.and.arrow.down",
                lead: "Export writes a new image at full quality. Projects keep the plan editable; batch export repeats the current plan across photos.",
                steps: [
                    step("Export",
                         "⌘E opens the sheet: format, quality, long edge, AI upscale, face-analysis options and metadata."),
                    step("Full quality",
                         "Exports are written at the full quality and size of the original unless you choose a smaller long edge."),
                    step("Projects",
                         "⌘S saves an editable project (⌘⇧S for Save As). Open one with ⇧⌘O; it restores every slider and AI edit."),
                    step("Batch",
                         "⇧⌘E applies the current settings to several photos at once."),
                ],
                note: "Location and camera identity are removed from exports by default (Settings → Export)."),

            TutorialSection(
                id: "models", group: "Finish", title: "AI models, offline & privacy", icon: "lock.shield",
                lead: "The AI models run on this Mac. The manager in Settings lists each model, its task, its license and its size.",
                steps: [
                    step("Open the manager",
                         "Settings → AI Models → Manage Models…"),
                    step("Approve a download",
                         "Nothing downloads without your consent. The sheet shows files, size and license; the manifest hash is the one you approve."),
                    step("Verify",
                         "After install, Verify checks the checksums. Remove deletes the model files; you can download them again later."),
                    step("Go offline",
                         "Once installed, every AI tool works with no network. Downloads are the only time the app uses the internet."),
                    step("Know the licenses",
                         "FLUX.2 klein, SAM 2.1 and Swin2SR are Apache-2.0; MI-GAN is MIT. The manager shows the exact entry for each model."),
                ],
                note: "No cloud inference, no image uploads, no hidden requests. Docs/PRIVACY_AUDIT.md records how this was measured."),

            TutorialSection(
                id: "settings", group: "Finish", title: "Settings & recovery", icon: "gearshape",
                lead: "Settings holds language, automatic behaviour, export metadata, tool defaults and recovery.",
                steps: [
                    step("Language",
                         "English or فارسی; the whole interface, including this tutorial, switches immediately."),
                    step("Auto",
                         "How much of each measured automatic fix is applied."),
                    step("Export",
                         "Remove location and camera info is on by default; orientation, colour profile and dimensions are kept."),
                    step("Tools",
                         "Show face box and regions, and the healing brush size."),
                    step("Recovery",
                         "Keep a recovery copy of unsaved work. After a crash the next launch offers it back; saving or exporting clears it."),
                    step("Restore Defaults",
                         "Resets the preferences, not the photo currently open."),
                ],
                note: "The AI helper restarts itself when an edit fails because it stopped responding."),

            TutorialSection(
                id: "shortcuts", group: "Finish", title: "Keyboard shortcuts", icon: "keyboard",
                lead: "The shortcuts that matter while editing. The same list is in Help → Help.",
                steps: []),

            TutorialSection(
                id: "trouble", group: "Finish", title: "Troubleshooting", icon: "lifepreserver",
                lead: "Most failures have a specific, local cause. These are the ones the app reports.",
                steps: [
                    step("Models not installed",
                         "Open Settings → Manage Models and install what the edit needs. The message in AI Edit names the missing piece."),
                    step("Helper stopped",
                         "Run the edit again. The app restarts the local helper on demand; a stopped helper is not a lost photo."),
                    step("Edit too large",
                         "Select a smaller area. A local patch is bounded on purpose; a large selection is refused instead of quietly replacing the frame."),
                    step("Upscale unavailable",
                         "The helper is missing, so export used the standard resampler. Install the models to enable Swin2SR."),
                    step("No face or no subject",
                         "Skin tools need a face; Body and Background need a subject. Color & Light still works."),
                    step("Export failed",
                         "Check the destination and free space, then try again. The original is untouched."),
                ],
                note: "The app never overwrites the original photo, so a bad result is always recoverable by reopening the file."),
        ])

    // MARK: - Persian

    static let persian = TutorialCopy(
        windowTitle: "آموزش Retouch Studio",
        menuTitle: "آموزش",
        buttonHelp: "باز کردن آموزش کامل",
        intro: "راهنمای کامل همهٔ بخش‌های برنامه، از جمله هر چهار مسیر هوش مصنوعی. یک‌بار بخوانید و بعد کنار اولین پرتره باز نگه دارید.",
        localNote: "همهٔ این‌ها روی همین مک انجام می‌شود. چیزی آپلود نمی‌شود.",
        searchPlaceholder: "جستجو در آموزش",
        noResults: "هیچ بخشی با این جستجو پیدا نشد.",
        previous: "قبلی",
        next: "بعدی",
        shortcutTitle: "کلیدهای میان‌بر",
        shortcuts: [
            ("⌘O", "باز کردن عکس"),
            ("⇧⌘O", "باز کردن پروژه"),
            ("⌘S / ⇧⌘S", "ذخیرهٔ پروژه / ذخیره با نام"),
            ("⌘E / ⇧⌘E", "خروجی / خروجی گروهی"),
            ("⇧⌘A", "تحلیل هوشمند"),
            ("⌘Z / ⇧⌘Z", "واگرد / ازنو"),
            ("⌘R", "بازنشانی همهٔ تنظیمات"),
            ("⌘+ / ⌘− / ⌘0", "بزرگ‌نمایی / کوچک‌نمایی / اندازهٔ پنجره"),
            ("Space", "نگه دارید تا عکس اصلی دیده شود"),
            ("۱ – ۰", "انتخاب ابزار"),
            ("⌘W", "بستن پنجره"),
            ("⌘,", "تنظیمات"),
        ],
        sections: [
            TutorialSection(
                id: "start", group: "شروع", title: "شروع سریع", icon: "sparkles",
                lead: "هر تغییر یک نقشه روی عکس اصلی است. می‌توانید واگردش کنید، مقایسه‌اش کنید، به‌صورت پروژه ذخیره‌اش کنید یا دورش بیندازید — فایل روی دیسک همان‌طور که بود می‌ماند.",
                steps: [
                    step("یک عکس باز کنید",
                         "⌘O را بزنید، Open را انتخاب کنید یا عکس را روی بوم رها کنید. برنامه هر قالبی را که مک می‌خواند، با کیفیت کامل باز می‌کند."),
                    step("یک ابزار انتخاب کنید",
                         "نوار بالا دوازده ابزار دارد. کلیدهای ۱ تا ۰ ده ابزار اول را باز می‌کنند؛ بقیه را با کلیک انتخاب کنید."),
                    step("سمت راست تنظیم کنید",
                         "پنل راست از ابزار فعال پیروی می‌کند. ستون چپ تحلیل هوشمند، پیش‌تنظیم‌ها و ویرایش هوش مصنوعی را در دسترس نگه می‌دارد."),
                    step("آزادانه واگرد کنید",
                         "⌘Z یک قدم عقب، ⇧⌘Z یک قدم جلو، و بازنشانی همهٔ تنظیمات (⌘R) نقشه را بدون بستن عکس پاک می‌کند."),
                    step("کار را تمام کنید",
                         "⌘S یک پروژهٔ قابل ویرایش ذخیره می‌کند؛ ⌘E یک فایل تصویر تازه می‌نویسد. عکس اصلی هرگز بازنویسی نمی‌شود."),
                ],
                note: "این آموزش در منوی Help → آموزش و پشت دکمهٔ ؟ در نوار بالا هست."),

            TutorialSection(
                id: "smart", group: "شروع", title: "تحلیل هوشمند و رتوش خودکار", icon: "wand.and.stars",
                lead: "تحلیل هوشمند اول عکس را اندازه می‌گیرد: نقاط چهره، بافت پوست، تُن، نور، دندان و چشم. مقدار پیشنهاد می‌دهد و کنترل دست شما می‌ماند.",
                steps: [
                    step("اجرا کنید",
                         "⇧⌘A را بزنید یا در ستون چپ روی تحلیل هوشمند کلیک کنید. چهره بیشترین داده را می‌دهد؛ اگر چهره نباشد، رنگ و نور باز هم اندازه‌گیری می‌شوند."),
                    step("گزارش را بخوانید",
                         "هر یافته مقدار اندازه‌گیری‌شده و تغییری که ایجاد می‌کند را نشان می‌دهد. هر موردی را که نمی‌خواهید خاموش کنید."),
                    step("پیشنهاد را اعمال کنید",
                         "اعمال پیشنهادها اسلایدرها را روی اصلاح اندازه‌گیری‌شده می‌گذارد. هیچ چیزی قفل نمی‌شود؛ همهٔ مقادیر قابل ویرایش می‌مانند."),
                    step("مقدارش را کم و زیاد کنید",
                         "اسلایدرهای رتوش خودکار و رنگ و نور خودکار تعیین می‌کنند چقدر از اصلاح اندازه‌گیری‌شده اعمال شود، از هیچ تا کامل."),
                    step("ملایم بمانید",
                         "عکس تمیز تقریباً هیچ تغییری نمی‌گیرد. ابزارهای خودکار اندازه می‌گیرند، نزدیک کف ملایم می‌مانند و پوست را تیره نمی‌کنند."),
                ],
                note: "تحلیل راهنمایی است، نه فیلتر. از آن به‌عنوان نقطهٔ شروع استفاده کنید و بعد با اسلایدرها تنظیم کنید."),

            TutorialSection(
                id: "workspace", group: "شروع", title: "میز کار", icon: "rectangle.3.group",
                lead: "پنجره چهار ناحیه دارد: نوار ابزار، کارت‌های چپ، بوم و بازرس.",
                steps: [
                    step("نوار بالا",
                         "ابزارها در لبهٔ شروع، نام سند و واگرد/ازنو در میانه، و خروجی در لبهٔ پایان. علامت ؟ همین آموزش را باز می‌کند."),
                    step("ستون چپ",
                         "تحلیل هوشمند و رتوش خودکار، نوار پیش‌تنظیم‌ها و کارت ویرایش هوش مصنوعی. برای دیدن همه اسکرول کنید."),
                    step("بوم",
                         "برای جابه‌جایی بکشید، برای بزرگ‌نمایی دو انگشت یا ⌘-اسکرول کنید، و برای ۱۰۰٪ دوبار کلیک کنید. Space را نگه دارید تا عکس اصلی دیده شود."),
                    step("بازرس",
                         "پنل راست از ابزار فعال پیروی می‌کند. برای بستن هر گروه روی عنوانش کلیک کنید."),
                    step("مقایسه",
                         "کنترل مقایسه نمای قبل/بعد را نشان می‌دهد. دسته را بکشید؛ Space همچنان عکس دست‌نخوردهٔ اصلی را نشان می‌دهد."),
                ]),

            TutorialSection(
                id: "ai-remove", group: "ویرایش هوشمند", title: "راه اول — حذف شیء", icon: "eraser", badge: "هوش ۱",
                lead: "حذف شیء مدل محلی FLUX.2 klein 4B را اجرا می‌کند تا چیزی را پاک کند و پس‌زمینهٔ پشتش را بازسازی کند.",
                steps: [
                    step("پیش‌تنظیم را انتخاب کنید",
                         "در کارت ویرایش هوش مصنوعی، حذف شیء را انتخاب کنید."),
                    step("شیء را علامت بزنید",
                         "مستقیم روی آن کلیک کنید، یا به «کادر» بروید و دورش کادر بکشید. برای شکل‌های سخت، «قلم‌مو» هم هست."),
                    step("لبه‌ها را دقیق کنید",
                         "چسبیدن به لبه‌ها را بزنید تا SAM علامت خام شما را به ماسکی تبدیل کند که از لبهٔ واقعی پیروی می‌کند. اگر لازم بود با «قلم‌مو» یا «پاک‌کن» اصلاح کنید."),
                    step("ویرایش را اجرا کنید",
                         "دستیار یک تکهٔ ۵۱۲ پیکسلی با زمینهٔ اطراف را در چهار قدم می‌سازد و بعد فقط داخل ماسک ترکیب می‌کند. پیکسل‌های بیرون دقیقاً همان می‌مانند."),
                    step("بازبینی کنید",
                         "نتیجه به‌عنوان یک قدم در تاریخچه ثبت می‌شود. «ویرایش‌های هوش مصنوعی» همه را فهرست می‌کند و «حذف آخرین ویرایش» آن را برمی‌گرداند."),
                ],
                note: "ناحیه را زیر حدود ۶٪ کادر نگه دارید — انتخاب بزرگ‌تر رد می‌شود تا کل عکس بی‌صدا جایگزین نشود. روی این مک حدود ۲۴ تا ۴۷ ثانیه انتظار داشته باشید؛ اجرای اول مدل را هم بارگذاری می‌کند."),

            TutorialSection(
                id: "ai-heal", group: "ویرایش هوشمند", title: "راه دوم — ترمیم ناحیهٔ کوچک", icon: "bandage", badge: "هوش ۲",
                lead: "ترمیم ناحیهٔ کوچک مدل محلی MI-GAN را برای لک، گرد و غبار و نقص‌های کوچک اجرا می‌کند. بافت اطراف را ادامه می‌دهد، نه اینکه صحنه‌ای تازه بسازد.",
                steps: [
                    step("ترمیم ناحیهٔ کوچک را انتخاب کنید",
                         "دومین پیش‌تنظیم در ویرایش هوش مصنوعی است."),
                    step("روی لک بکشید",
                         "با قلم‌موی کوچک روی لک بکشید. برای یک کلیک ساده، «نقطه» هم کار می‌کند."),
                    step("ماسک را تنظیم کنید",
                         "«گسترش» ناحیه را بزرگ می‌کند و «نرمی لبه» درز را نرم می‌کند. اصل کار کوچک بودن است: ضربه را نزدیک خود نقص نگه دارید."),
                    step("اجرا کنید",
                         "ترمیم معمولاً زیر یک ثانیه تمام می‌شود. «گسترش» و «نرمی لبه» پیش از دیدن مدل روی ماسک اعمال می‌شوند."),
                ],
                note: "برای شیء بزرگ یا مهم از حذف شیء استفاده کنید؛ مدل ترمیم برای حفره ساخته شده، نه برای بازسازی یک صحنه."),

            TutorialSection(
                id: "ai-snap", group: "ویرایش هوشمند", title: "راه سوم — انتخاب هوشمند", icon: "viewfinder", badge: "هوش ۳",
                lead: "چسبیدن به لبه‌ها مدل تقسیم‌بندی SAM 2.1 tiny را اجرا می‌کند. شما یک کادر یا ضربهٔ خام می‌دهید؛ ماسکی برمی‌گردد که از مرز واقعی پیروی می‌کند.",
                steps: [
                    step("یک انتخاب خام بسازید",
                         "«کادر» را انتخاب کنید و دور سوژه یا شیء آزادانه کادر بکشید، یا با «قلم‌مو» یک ضربهٔ خام بزنید."),
                    step("به لبه بچسبید",
                         "چسبیدن به لبه‌ها را بزنید. ورکر SAM را روی تصویر کاری فعلی اجرا می‌کند و ناحیهٔ خام را با ماسک لبه‌دار جایگزین می‌کند."),
                    step("اصلاح کنید",
                         "با «قلم‌مو» اضافه کنید، با «پاک‌کن» ببرید، و بعد با «گسترش»، «نرمی لبه» یا «معکوس» مرز را تمام کنید."),
                    step("استفاده کنید",
                         "ماسک اصلاح‌شده به هر کدام از پیش‌تنظیم‌های هوش مصنوعی داده می‌شود. همین است که مانع می‌شود ویرایش به بقیهٔ عکس دست بزند."),
                ],
                note: "تقسیم‌بندی محلی اجرا می‌شود و روی عکس بزرگ کمی طول می‌کشد. کادری که سوژه را کامل در بر بگیرد، تمیزترین نتیجه را می‌دهد."),

            TutorialSection(
                id: "ai-mask", group: "ویرایش هوشمند", title: "ماسک و دقت انتخاب", icon: "circle.dashed",
                lead: "ماسک تعیین می‌کند ویرایش هوش مصنوعی دقیقاً کجا اجازهٔ نوشتن دارد. هر چیزی بیرون ماسک، پیکسل‌به‌پیکسل حفظ می‌شود.",
                steps: [
                    step("سه راه علامت‌گذاری",
                         "«نقطه» برای یک نقطه، «قلم‌مو» برای رنگ کردن، «کادر» برای کشیدن یک ناحیه."),
                    step("اصلاحش کنید",
                         "«قلم‌مو» اضافه می‌کند، «پاک‌کن» برمی‌دارد و «پاک کردن» از نو شروع می‌کند. «گسترش» و «نرمی لبه» لبه را شکل می‌دهند."),
                    step("معکوس کنید",
                         "«معکوس» داخل و بیرون را جابه‌جا می‌کند — وقتی انتخاب سوژه از پس‌زمینه آسان‌تر است به کار می‌آید."),
                    step("پوشش را ببینید",
                         "پوشش قرمز همان ماسک زنده است. آنچه می‌بینید همان چیزی است که ورکر دریافت می‌کند."),
                    step("تاریخچه",
                         "هر ویرایش هوش مصنوعی یک قدم واگرد است. «ویرایش‌های هوش مصنوعی» در کارت تعدادشان را نشان می‌دهد."),
                ],
                note: "انتخابی که برای یک تکهٔ محلی بزرگ باشد با پیام رد می‌شود؛ ناحیهٔ کوچک‌تری انتخاب کنید."),

            TutorialSection(
                id: "ai-upscale", group: "ویرایش هوشمند", title: "راه چهارم — بزرگ‌نمایی هوشمند ۴×", icon: "arrow.up.left.and.arrow.down.right", badge: "هوش ۴",
                lead: "بزرگ‌نمایی هوشمند ۴× مدل محلی Swin2SR را هنگام خروجی اجرا می‌کند. جزئیات اضافه می‌کند و بعد به اندازهٔ خروجی انتخابی شما می‌برد.",
                steps: [
                    step("خروجی را باز کنید",
                         "⌘E را بزنید. مثل همیشه قالب، کیفیت و ضلع بزرگ خروجی را انتخاب کنید."),
                    step("بزرگ‌نمایی هوشمند ۴× را روشن کنید",
                         "کلیدش در برگهٔ خروجی است. یک پاس ۴× یک‌باره است، نه جایگزین عکس اصلی واضح‌تر."),
                    step("محدودیت‌ها را ببینید",
                         "ورودی حدود ۲.۵ مگاپیکسل سقف دارد تا خروجی زیر ۴۰ مگاپیکسل بماند. برگه تخمین زمان را به دقیقه روی این مک نشان می‌دهد."),
                    step("ذخیره کنید",
                         "تصویر بزرگ‌شده در فایل تازه نوشته می‌شود. اگر دستیار محلی نصب نباشد، خروجی به نمونه‌گیر استاندارد برمی‌گردد و همین را می‌گوید."),
                ],
                note: "بزرگ‌نمایی جزئیاتی را که عکس هرگز نداشته برنمی‌گرداند. نتیجه را در ۱۰۰٪ ببینید، نه در نمای اندازهٔ پنجره."),

            TutorialSection(
                id: "skin", group: "ابزارها", title: "پوست و ترمیم", icon: "sparkles",
                lead: "پوست بخش اصلی است: هموارسازی، روشنایی، لک، تُن، درخشش، بافت و چین‌ها، همه با حفاظت تشخیص چهره.",
                steps: [
                    step("با پیش‌تنظیم شروع کنید",
                         "نوار پیش‌تنظیم‌های بالای اسلایدرها یک نقطهٔ شروع منسجم می‌سازد؛ بعد مقادیر را جداگانه دقیق کنید."),
                    step("بافت را نگه دارید",
                         "حفظ بافت هنگام هموارسازی منافذ را نگه می‌دارد. وقتی پوست پلاستیکی شد، بالایش ببرید."),
                    step("تُن را یکدست کنید",
                         "یکدست‌سازی تُن و حذف لک با هم کار می‌کنند؛ روی عکس خوب مقدار کم معمولاً کافی است."),
                    step("دستی ترمیم کنید",
                         "ابزار ترمیم لک زیر قلم‌مو را برمی‌دارد. اندازهٔ قلم‌مو در تنظیمات → ابزارها و در پنل ترمیم است."),
                ],
                note: "اگر چهره‌ای تشخیص داده نشود، اسلایدرهای پوست هدفی ندارند؛ تحلیل هوشمند این را به شما می‌گوید."),

            TutorialSection(
                id: "reshape", group: "ابزارها", title: "تغییر شکل", icon: "face.smiling",
                lead: "تغییر شکل اجزای چهره را هندسی جابه‌جا می‌کند — چشم، بینی، لب، گونه، فک، چانه، عرض و طول صورت — بدون دست زدن به پس‌زمینه.",
                steps: [
                    step("تغییر شکل را باز کنید",
                         "هر کنترل یک نقطهٔ میانی دارد؛ دوبار کلیک روی اسلایدر آن را به صفر برمی‌گرداند."),
                    step("حرکت کوچک برنده است",
                         "چند درصد بهتر به نظر می‌رسد. مقدار زیاد، آدم دیگری می‌سازد."),
                    step("بقیهٔ قاب را حفظ کنید",
                         "ابزار فقط اجزای چهره را شکل می‌دهد؛ پس‌زمینه کج نمی‌شود."),
                ],
                note: "تغییر شکل هندسه است، نه هوش مصنوعی. بی‌درنگ اعمال می‌شود و کاملاً قابل واگرد است."),

            TutorialSection(
                id: "eyes", group: "ابزارها", title: "چشم و دندان", icon: "eye",
                lead: "چشم و دندان چشم را روشن و واضح می‌کند و دندان را سفید می‌کند، با هم‌ترازی محدود به دهان.",
                steps: [
                    step("دندان",
                         "سفیدکردن و هم‌ترازی فقط وقتی دندان دیده شود اثر می‌کنند. اگر دیده نشود، برنامه همین را می‌گوید و حدس نمی‌زند."),
                    step("چشم",
                         "روشنایی، وضوح و جزئیات عنبیه جدا هستند: برق چشم را بالا ببرید بدون اینکه کل چشم بدرخشد."),
                    step("کنترل‌های ظریف",
                         "عمق مژه و لنز هم اینجا هستند؛ هر دو عمداً آرام طراحی شده‌اند."),
                ],
                note: "سفیدکردن به دهانهٔ دهان محدود می‌شود، پس لب و لثه رنگ خود را نگه می‌دارند."),

            TutorialSection(
                id: "makeup", group: "ابزارها", title: "آرایش", icon: "paintpalette",
                lead: "آرایش رنگ را روی لب، گونه، کانتور، سایه، خط چشم، ابرو و مو می‌نشاند، با انتخاب خانوادهٔ پوست تا رنگ باورپذیر بنشیند.",
                steps: [
                    step("خانواده را انتخاب کنید",
                         "روشن، باز، متوسط، گندمی و تیره پالت را با پرتره هماهنگ می‌کنند."),
                    step("هر بار یک ناحیه",
                         "لب، گونه، کانتور، سایه، خط چشم، ابرو یا مو را انتخاب کنید و بعد رنگ و مقدار را بگذارید."),
                    step("کم بزنید و بسازید",
                         "مقدار مرز آرایش و رنگ است؛ کم شروع کنید و بالا ببرید."),
                ],
                note: "آرایش به‌عنوان رنگ اعمال می‌شود، نه بافت، پس از سایه‌زنی زیرین پیروی می‌کند."),

            TutorialSection(
                id: "color", group: "ابزارها", title: "رنگ و نور", icon: "camera.filters",
                lead: "یک فضای کامل تُن و رنگ: نوردهی، کنتراست، سیاه‌ها، سفیدها، اشباع، ویبرانس، گرمی، وضوح و وینیت، به‌همراه منحنی تُن و HSL.",
                steps: [
                    step("با پایه‌ها شروع کنید",
                         "رنگ و نور خودکار نقطهٔ شروع را اندازه می‌گیرد؛ بعد اسلایدرها کنترل را به شما می‌دهند."),
                    step("منحنی تُن",
                         "نقطه‌ای را بکشید تا سایه‌ها، نیمه‌سایه‌ها یا نورها را بالا یا پایین ببرید. منحنی فقط روی روشنایی کار می‌کند، پس رنگ‌ها سر جایشان می‌مانند."),
                    step("HSL",
                         "یک باند رنگ را انتخاب کنید و رنگ، اشباع یا روشنایی‌اش را عوض کنید. باندها نرم هم‌پوشانی دارند، پس رنگی که بین دو باند است مشترک می‌ماند، نه نصف."),
                    step("وینیت",
                         "گوشه‌ها را تیره کنید تا چشم به وسط کشیده شود؛ روی پرتره مقدار کم مناسب است."),
                ],
                note: "وضوح کنتراست محلی اضافه می‌کند. روی پوست، کمی زیاد است."),

            TutorialSection(
                id: "looks", group: "ابزارها", title: "پیش‌تنظیم‌ها و ظاهرها", icon: "film",
                lead: "پیش‌تنظیم‌ها نقطهٔ شروع کامل هستند؛ ظاهرها تُن فیلمی با دانه‌بندی‌اند؛ ظاهرهای من دستور خودتان را نگه می‌دارد.",
                steps: [
                    step("پیش‌تنظیم‌ها",
                         "گروه‌های هر روزه، پوست، زیبایی، رنگ، فیلم و آرایش. کلیک روی هر کدام پوست، شکل و رنگ را با هم تنظیم می‌کند."),
                    step("ظاهرهای فیلمی",
                         "طلایی گرم، پرتره، شب، کراس‌پروسس و مات کم‌رنگ یک تُن و دانه‌بندی اضافه می‌کنند."),
                    step("مال خودتان را ذخیره کنید",
                         "اسلایدرها را تنظیم کنید، در ظاهرهای من نام بگذارید و «ذخیره» را بزنید. ظاهر ذخیره‌شده را از همان فهرست حذف کنید."),
                ],
                note: "پیش‌تنظیم نقطهٔ شروع است، نه قفل — هر مقداری که می‌گذارد قابل ویرایش می‌ماند."),

            TutorialSection(
                id: "crop", group: "ابزارها", title: "برش", icon: "crop",
                lead: "برش قاب عکس را عوض می‌کند بدون نمونه‌برداری دوباره. ویرایش‌های هوش مصنوعی و ضربه‌های ترمیم نسبت به کل عکس ذخیره می‌شوند، پس هنگام برش سر جایشان می‌مانند.",
                steps: [
                    step("قاب را بکشید",
                         "مستطیل برش را روی بوم جابه‌جا کنید؛ دسته‌ها اندازه‌اش را عوض می‌کنند."),
                    step("نسبت را انتخاب کنید",
                         "آزاد، اصلی، ۱:۱، ۴:۵ یا ۱۶:۹."),
                    step("اعمال یا بازنشانی",
                         "اعمال برش را قطعی می‌کند؛ بازنشانی به قاب اصلی برمی‌گردد."),
                ],
                note: "برش غیرتخریبی است. خروجی آن را اعمال می‌کند؛ پروژهٔ ذخیره‌شده آن را قابل ویرایش نگه می‌دارد."),

            TutorialSection(
                id: "body", group: "ابزارها", title: "بدن و پس‌زمینه", icon: "figure.stand",
                lead: "بدن و پس‌زمینه از جدا کردن سوژه استفاده می‌کنند. اندام را هموار و لاغرتر کنید، بعد آنچه پشتش است را محو یا رنگ‌بندی کنید.",
                steps: [
                    step("سوژه را پیدا کنید",
                         "هر دو ابزار سوژه‌ای می‌خواهند که برنامه بتواند جدا کند. اگر پیدا نشود، همین را می‌گویند و حدس نمی‌زنند."),
                    step("بدن",
                         "هموارسازی، روشنایی، لاغری، کمر، بازو و پا. لاغری هندسی است و داخل سوژه می‌ماند."),
                    step("پس‌زمینه",
                         "محو، تُن، اشباع و پُرکردن. حذف پس‌زمینه آن را با رنگ پُرکردن انتخابی جایگزین می‌کند."),
                ],
                note: "جدا کردن محلی محاسبه می‌شود. پیش از خروجی، لبه را در ۱۰۰٪ ببینید."),

            TutorialSection(
                id: "stickers", group: "ابزارها", title: "استیکرها", icon: "star.circle",
                lead: "استیکرها به‌صورت شکل برداری روی عکس کشیده می‌شوند: ستاره، قلب، درخشش، گل، پروانه و آذرخش.",
                steps: [
                    step("یکی بگذارید",
                         "یک شکل انتخاب کنید و روی بوم کلیک کنید. برای جابه‌جایی بکشید."),
                    step("انتخاب و حذف",
                         "برای انتخاب روی استیکر کلیک کنید؛ حذف استیکر آن را برمی‌دارد و پاک کردن همه از نو شروع می‌کند."),
                ],
                note: "استیکرها بخشی از نقشهٔ ویرایش‌اند و در خروجی تخت می‌شوند."),

            TutorialSection(
                id: "analysis", group: "ابزارها", title: "تحلیل چهره", icon: "viewfinder",
                lead: "تحلیل چهره نقاط، شکل‌ها و خطوط راهنما را برای مرجع روی پرتره می‌کشد — بدون متن و برچسب، فقط هندسه.",
                steps: [
                    step("روشنش کنید",
                         "پوشش را در ابزار تحلیل چهره فعال کنید."),
                    step("سبک را انتخاب کنید",
                         "شکل‌های خط‌چین یا مش کامل صورت. خط دور صورت و ناحیه‌های جداگانه را روشن و خاموش کنید."),
                    step("خطوط را تنظیم کنید",
                         "رنگ خط، ضخامت، قدرت و درخشش؛ وقتی کشیدن اشتباه شد، نقطه‌ها و انتهاها را بازنشانی کنید."),
                    step("راهنماها را بگذارید",
                         "یک نقطه یا انتها را بکشید تا به یک ویژگی اشاره کند."),
                    step("خروجی",
                         "بخش تحلیل چهره در برگهٔ خروجی حاشیه و اینکه در تصویر بسوزد یا نه را کنترل می‌کند."),
                ],
                note: "تحلیل یک لایهٔ مرجع است؛ پوست یا رنگ را تغییر نمی‌دهد."),

            TutorialSection(
                id: "export", group: "پایان کار", title: "خروجی، پروژه و خروجی گروهی", icon: "square.and.arrow.down",
                lead: "خروجی یک تصویر تازه با کیفیت کامل می‌نویسد. پروژه‌ها نقشه را قابل ویرایش نگه می‌دارند؛ خروجی گروهی همان نقشه را روی چند عکس تکرار می‌کند.",
                steps: [
                    step("خروجی",
                         "⌘E برگه را باز می‌کند: قالب، کیفیت، ضلع بزرگ، بزرگ‌نمایی هوشمند، گزینه‌های تحلیل چهره و فراداده."),
                    step("کیفیت کامل",
                         "خروجی‌ها با کیفیت و اندازهٔ کامل عکس اصلی نوشته می‌شوند، مگر ضلع بزرگ کوچک‌تری انتخاب کنید."),
                    step("پروژه‌ها",
                         "⌘S یک پروژهٔ قابل ویرایش ذخیره می‌کند (⌘⇧S برای ذخیره با نام). با ⇧⌘O بازش کنید؛ همهٔ اسلایدرها و ویرایش‌های هوش مصنوعی برمی‌گردند."),
                    step("گروهی",
                         "⇧⌘E تنظیمات فعلی را روی چند عکس هم‌زمان اعمال می‌کند."),
                ],
                note: "موقعیت مکانی و مشخصات دوربین به‌صورت پیش‌فرض از خروجی حذف می‌شوند (تنظیمات → خروجی)."),

            TutorialSection(
                id: "models", group: "پایان کار", title: "مدل‌ها، آفلاین و حریم خصوصی", icon: "lock.shield",
                lead: "مدل‌های هوش مصنوعی روی همین مک اجرا می‌شوند. مدیر مدل‌ها در تنظیمات هر مدل، وظیفه، مجوز و اندازه‌اش را فهرست می‌کند.",
                steps: [
                    step("مدیر را باز کنید",
                         "تنظیمات → مدل‌های هوش مصنوعی → مدیریت مدل‌ها…"),
                    step("دانلود را تأیید کنید",
                         "هیچ چیزی بدون رضایت شما دانلود نمی‌شود. برگه فایل‌ها، اندازه و مجوز را نشان می‌دهد؛ هش مانیفست همان چیزی است که تأیید می‌کنید."),
                    step("بررسی کنید",
                         "بعد از نصب، بررسی چک‌سام‌ها را کنترل می‌کند. حذف فایل‌های مدل را پاک می‌کند؛ بعداً می‌توانید دوباره دانلودشان کنید."),
                    step("آفلاین شوید",
                         "پس از نصب، هر ابزار هوش مصنوعی بدون شبکه کار می‌کند. دانلود تنها زمانی است که برنامه از اینترنت استفاده می‌کند."),
                    step("مجوزها را بدانید",
                         "FLUX.2 klein، SAM 2.1 و Swin2SR مجوز Apache-2.0 دارند؛ MI-GAN مجوز MIT. مدیر مدل‌ها مدخل دقیق هر کدام را نشان می‌دهد."),
                ],
                note: "هیچ استنتاج ابری، هیچ آپلود عکس و هیچ درخواست پنهانی نیست. سند Docs/PRIVACY_AUDIT.md روش اندازه‌گیری را ثبت کرده است."),

            TutorialSection(
                id: "settings", group: "پایان کار", title: "تنظیمات و بازیابی", icon: "gearshape",
                lead: "تنظیمات شامل زبان، رفتار خودکار، فرادادهٔ خروجی، پیش‌فرض ابزارها و بازیابی است.",
                steps: [
                    step("زبان",
                         "English یا فارسی؛ کل رابط، از جمله همین آموزش، بی‌درنگ عوض می‌شود."),
                    step("خودکار",
                         "اینکه از هر اصلاح خودکار اندازه‌گیری‌شده چقدر اعمال شود."),
                    step("خروجی",
                         "حذف موقعیت مکانی و مشخصات دوربین پیش‌فرض روشن است؛ جهت، پروفایل رنگ و ابعاد حفظ می‌شوند."),
                    step("ابزارها",
                         "نمایش کادر و نواحی چهره، و اندازهٔ قلم‌موی ترمیم."),
                    step("بازیابی",
                         "یک نسخهٔ بازیابی از کار ذخیره‌نشده نگه می‌دارد. بعد از کرش، اجرای بعدی آن را پیشنهاد می‌دهد؛ ذخیره یا خروجی پاکش می‌کند."),
                    step("برگرداندن به حالت اولیه",
                         "ترجیحات را بازنشانی می‌کند، نه عکسی که باز است."),
                ],
                note: "دستیار هوش مصنوعی وقتی ویرایشی به‌خاطر پاسخ ندادنش شکست بخورد، خودش دوباره راه می‌افتد."),

            TutorialSection(
                id: "shortcuts", group: "پایان کار", title: "کلیدهای میان‌بر", icon: "keyboard",
                lead: "کلیدهایی که هنگام ویرایش به کار می‌آیند. همین فهرست در Help → راهنما هم هست.",
                steps: []),

            TutorialSection(
                id: "trouble", group: "پایان کار", title: "رفع اشکال", icon: "lifepreserver",
                lead: "بیشتر خطاها دلیل مشخص و محلی دارند. این‌ها همان‌هایی هستند که برنامه گزارش می‌کند.",
                steps: [
                    step("مدل‌ها نصب نیستند",
                         "تنظیمات → مدیریت مدل‌ها را باز کنید و آنچه ویرایش لازم دارد نصب کنید. پیام در ویرایش هوش مصنوعی قطعهٔ گم‌شده را نام می‌برد."),
                    step("دستیار متوقف شده",
                         "ویرایش را دوباره اجرا کنید. برنامه دستیار محلی را در صورت نیاز از نو راه می‌اندازد؛ توقف دستیار یعنی از دست رفتن عکس نیست."),
                    step("ویرایش خیلی بزرگ است",
                         "ناحیهٔ کوچک‌تری انتخاب کنید. تکهٔ محلی عمداً محدود است؛ انتخاب بزرگ رد می‌شود تا کل قاب بی‌صدا جایگزین نشود."),
                    step("بزرگ‌نمایی در دسترس نیست",
                         "دستیار نصب نیست، پس خروجی از نمونه‌گیر استاندارد استفاده کرد. برای فعال کردن Swin2SR مدل‌ها را نصب کنید."),
                    step("چهره یا سوژه پیدا نشد",
                         "ابزارهای پوست چهره می‌خواهند؛ بدن و پس‌زمینه سوژه می‌خواهند. رنگ و نور همچنان کار می‌کند."),
                    step("خروجی شکست خورد",
                         "مقصد و فضای آزاد را بررسی کنید و دوباره امتحان کنید. عکس اصلی دست‌نخورده است."),
                ],
                note: "برنامه هرگز عکس اصلی را بازنویسی نمی‌کند، پس نتیجهٔ بد همیشه با باز کردن دوبارهٔ فایل قابل بازگشت است."),
        ])
}

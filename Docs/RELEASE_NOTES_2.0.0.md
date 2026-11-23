# Retouch Studio 2.0.0 · نسخهٔ ۲٫۰٫۰

**English** · **فارسی** — every section below is written in both languages, English first.

*Retouch Studio is a local-first portrait retouching studio for macOS. Analysis, editing,
masking, upscaling and export all run on your own Mac: there is no account, no subscription, no
cloud service and no automatic upload.*

---

## What this release is

### English

2.0.0 is the first release of the rewritten product. The editor measures the photo before it
changes it — skin, eyes, teeth, hair, light and framing — so an automatic edit only moves what the
measurements justify, and twelve tools sit in one inspector: Skin, Healing, Reshape, Eyes & Teeth,
Makeup, Color & Light, Looks, Crop, Body, Background, Stickers and Face Analysis.

Every change stays a value inside the project, so nothing is baked in. Undo and redo go back up to
100 steps, work can be saved as a `.retouch` project and reopened later, presets are editable, and
an unsaved session keeps a recovery copy. Export writes JPEG, PNG, TIFF or HEIC with a long-edge
cap, a quality control, an optional watermark and an optional face overlay; GPS and camera identity
are stripped from the saved copy. Colour output follows one documented rule: saves are sRGB, and a
wide-gamut source is converted rather than carried through with its original profile.

The whole interface is available in English and Persian, including Persian digits, right-to-left
layout and help text on every tool, section and slider.

Windows is now a second platform with a real application. **Retouch Studio for Windows 2.0.0 is a
light editor**: image opening and saving, crop, orientation, nine global colour and light sliders,
zoom and pan, before/after compare, a live histogram, batch export, `Project` files shared with the
macOS app, history, and a prompt to recover unsaved work. It ships as a zip archive and an unsigned
MSI installer. Two things are deliberately absent, and the app says so instead of failing quietly:
there is **no AI on Windows**, because every model we offer runs only on Apple silicon, and there is
no published Windows artifact yet — the installer becomes downloadable when the 2.0.0 release is
published, and until then it does not exist. Linux is not a product target.

### فارسی

نسخهٔ ۲٫۰٫۰ نخستین نسخهٔ محصولِ بازنویسی‌شده است. ویرایشگر پیش از آنکه چیزی را تغییر دهد، عکس را
می‌سنجد — پوست، چشم‌ها، دندان‌ها، مو، نور و کادر — تا ویرایش خودکار فقط همان چیزی را تغییر دهد که
اندازه‌گیری‌ها توجیه می‌کنند؛ دوازده ابزار هم در یک پنل کنار هم نشسته‌اند: پوست، ترمیم، تغییر شکل،
چشم و دندان، آرایش، رنگ و نور، ظاهرها، برش، بدن، پس‌زمینه، استیکرها و آنالیز چهره.

هر تغییر به‌صورت یک مقدار داخل پروژه می‌ماند و چیزی در عکس پخته نمی‌شود. بازگشت و بازگردانی تا
۱۰۰ مرحله ادامه دارد، کار را می‌توانید به‌صورت پروژهٔ `.retouch` ذخیره کنید و بعداً دوباره باز کنید،
پیش‌تنظیم‌ها قابل ویرایش‌اند و تا وقتی کاری ذخیره نشده باشد یک نسخهٔ بازیابی نگه داشته می‌شود. خروجی
با قالب‌های JPEG‏، PNG‏، TIFF یا HEIC نوشته می‌شود و محدودیت ضلع بلند، کنترل کیفیت، واترمارک اختیاری
و نمایش اختیاری شبکهٔ چهره را دارد؛ موقعیت GPS و مشخصات دوربین از فایل ذخیره‌شده حذف می‌شود. رنگ
خروجی از یک قانون روشن پیروی می‌کند: خروجی sRGB است و منبع با فضای رنگ گسترده تبدیل می‌شود و پروفایل
اصلی همراه آن نمی‌رود.

تمام رابط کاربری به دو زبان انگلیسی و فارسی در دسترس است، از جمله اعداد فارسی، چیدمان راست‌به‌چپ و
متن راهنما روی هر ابزار، بخش و اسلایدر.

ویندوز اکنون سکوی دوم با یک برنامهٔ واقعی است. **Retouch Studio برای ویندوز در نسخهٔ ۲٫۰٫۰ یک
ویرایشگر سبک است**: باز کردن و ذخیرهٔ تصویر، برش، چرخش، نه اسلایدر سراسری رنگ و نور، بزرگ‌نمایی و
جابه‌جایی، مقایسهٔ قبل و بعد، هیستوگرام زنده، خروجی گروهی، فایل‌های پروژهٔ مشترک با اپ مک، تاریخچهٔ
ویرایش و پرسش برای بازیابی کارِ ذخیره‌نشده. این نسخه به‌صورت یک آرشیو zip و یک نصب‌کنندهٔ MSI بدون
امضا منتشر می‌شود. دو چیز عمداً وجود ندارد و برنامه خودش هم همین را می‌گوید به‌جای آنکه بی‌صدا خطا
بدهد: **روی ویندوز هوش مصنوعی نیست**، چون همهٔ مدل‌هایی که ارائه می‌کنیم فقط روی Apple silicon اجرا
می‌شوند، و هنوز هیچ بستهٔ ویندوزی منتشر نشده است — فایل نصب هنگام انتشار نسخهٔ ۲٫۰٫۰ قابل دانلود
می‌شود و تا پیش از آن وجود ندارد. لینوکس هدف محصول نیست.

---

## Local AI helper and models / کمک‌یار و مدل‌های محلی

### English

The AI tools — **Remove object**, **Heal small area**, **Reimagine** and **4× upscale** — run in a
local helper on your Mac. They are optional, and the rest of the editor works normally without them.

Two things need to be true before any AI edit can run, and 2.0.0 is honest about both:

1. **A helper runtime has to be installed.** Release builds do not carry it, and in this version the
   automatic runtime download is switched off: no official runtime package has been approved yet, so
   Settings offers no runtime download and the AI tools report that the helper is unavailable. A
   build made from source can bundle the helper, and that is the path that lets you try the AI tools
   today. The helper needs Apple silicon; on Intel and on Windows the AI tools report that they are
   unavailable and nothing else changes.
2. **Model weights are downloaded only after you approve them.** Nothing is fetched silently. Before
   a download the app shows how many files it is, the total size, the source host, the licence of the
   code and of the trained weights, and the first characters of the checksum; the download is the
   only action in the app that uses the internet, and each file is checked against its recorded size
   and SHA-256 afterwards. If anything does not match, nothing is installed. An entry whose licence
   or integrity cannot be verified is refused, and the app names the reason instead of offering it.

The four models the catalogue can offer, and why each is there:

| Model | Used for | Size | Licence basis |
|---|---|---|---|
| Swin2SR x4 (real-world) | 4× upscale | 48.5 MB | Apache-2.0 for the code and for the weights, published by the lab that wrote the model. |
| MI-GAN (512, Places2) | Heal small area | 28.1 MB | MIT for the code and MIT for the weights, under a separate weight licence the authors ship themselves. |
| SAM 2.1 tiny | Selection from a click or a box | 156 MB | Apache-2.0, stated by the maker of the model for the checkpoints as well as the code. Downloading is refused today because the runtime package that would load it is not part of this helper; if the weights are already on disk they are verified and used. |
| FLUX.2 klein 4B (q4) | Generative reimagining | 4.6 GB | Apache-2.0 for the weights. This one is listed but **not a 2.0.0 feature**: it was measured at 16.7 GB of memory at peak on the 16 GB reference Mac, so it is out of reach on that machine, and its download record is still being re-established against the author-published source. |

Reimagine redraws the whole frame from your words. The subject stays recognisable, but every pixel
is new — it is a generative edit, not a retouch, and its result is not deterministic.

Whatever the helper produces appears as another step in your history, so an AI edit can be undone
like any other change.

### فارسی

ابزارهای هوش مصنوعی — **حذف شیء**، **ترمیم ناحیهٔ کوچک**، **بازآفرینی** و **بزرگ‌نمایی ۴×** — در یک
کمک‌یار محلی روی مک شما اجرا می‌شوند. این ابزارها اختیاری‌اند و بقیهٔ ویرایشگر بدون آن‌ها کاملاً کار
می‌کند.

پیش از اجرای هر ویرایش هوش مصنوعی دو شرط لازم است و نسخهٔ ۲٫۰٫۰ دربارهٔ هر دو صادق است:

۱. **ابتدا باید زمان اجرای کمک‌یار نصب شود.** نسخه‌های منتشرشده آن را همراه ندارند و در این نسخه
دانلود خودکار زمان اجرا خاموش است: هیچ بستهٔ رسمی تأیید نشده، بنابراین تنظیمات هیچ پیشنهاد دانلود
زمان اجرا نشان نمی‌دهد و ابزارهای هوش مصنوعی اعلام می‌کنند که کمک‌یار در دسترس نیست. نسخه‌ای که از
روی سورس ساخته شود می‌تواند کمک‌یار را در خودش داشته باشد و همین راهی است که امروز می‌توانید ابزارهای
هوش مصنوعی را امتحان کنید. کمک‌یار به Apple silicon نیاز دارد؛ روی Intel و روی ویندوز ابزارهای هوش
مصنوعی اعلام می‌کنند که در دسترس نیستند و بقیهٔ برنامه فرقی نمی‌کند.

۲. **وزن مدل‌ها فقط پس از تأیید شما دانلود می‌شود.** هیچ چیز بی‌صدا دریافت نمی‌شود. پیش از دانلود،
برنامه تعداد فایل‌ها، حجم کل، میزبان دانلود، مجوز کد و مجوز وزن‌های آموزش‌دیده و چند نویسهٔ نخست
چک‌سام را نشان می‌دهد؛ همین دانلود تنها مرحله‌ای است که از اینترنت استفاده می‌کند و پس از آن اندازه و
چک‌سام هر فایل با مقدار ثبت‌شده مقایسه می‌شود. اگر حتی یک مورد مطابقت نکند، چیزی نصب نمی‌شود. مدلی که
مجوز یا صحت آن قابل راستی‌آزمایی نباشد رد می‌شود و برنامه دلیلش را می‌گوید، نه اینکه آن را پیشنهاد
کند.

چهار مدلی که فهرست برنامه می‌تواند ارائه دهد و دلیل حضور هر کدام:

| مدل | کاربرد | حجم | پایهٔ مجوز |
|---|---|---|---|
| Swin2SR ×۴ (واقع‌گرایانه) | بزرگ‌نمایی ۴× | <bdi dir="ltr">48.5 MB</bdi> | Apache-2.0 برای کد و برای وزن‌ها، منتشرشده توسط همان آزمایشگاهی که مدل را نوشته است. |
| MI-GAN (۵۱۲، Places2) | ترمیم ناحیهٔ کوچک | <bdi dir="ltr">28.1 MB</bdi> | MIT برای کد و MIT برای وزن‌ها، زیر یک مجوز جداگانهٔ وزن که خودِ نویسندگان منتشر کرده‌اند. |
| SAM 2.1 tiny | انتخاب با یک کلیک یا کادر | <bdi dir="ltr">156 MB</bdi> | Apache-2.0، اعلام‌شده توسط سازندهٔ مدل برای وزن‌ها به‌اندازهٔ کد. دانلود آن در حال حاضر رد می‌شود، چون بستهٔ زمان‌اجرای لازم برای بارگذاری آن بخشی از این کمک‌یار نیست؛ اگر وزن‌ها از پیش روی دیسک باشند، بررسی و استفاده می‌شوند. |
| FLUX.2 klein 4B (قفل‌شده q4) | بازآفرینی مولد | <bdi dir="ltr">4.6 GB</bdi> | Apache-2.0 برای وزن‌ها. این مورد در فهرست است ولی **ویژگی نسخهٔ ۲٫۰٫۰ نیست**: روی مک مرجع ۱۶ گیگابایتی، مصرف حافظهٔ آن تا ۱۶٫۷ گیگابایت اندازه‌گیری شده، پس روی آن ماشین امکان‌پذیر نیست و سابقهٔ دانلودش هنوز باید از منبع منتشرشده توسط صاحب اثر بازثبت شود. |

بازآفرینی کل کادر را از روی توصیف شما از نو می‌کشد. سوژه شناخته‌شدنی می‌ماند، اما همهٔ پیکسل‌ها تازه‌اند
— این یک ویرایش مولد است، نه رتوش، و نتیجهٔ آن تکرارپذیر نیست.

خروجی کمک‌یار هوش مصنوعی مثل هر تغییر دیگری یک مرحله در تاریخچهٔ ویرایش است و می‌توان برگردانده شود.

---

## Installing 2.0.0 on a Mac / نصب نسخهٔ ۲٫۰٫۰ روی مک

### English

1. Check that this Mac runs **macOS 14 Sonoma or later**. Apple silicon gets the full editor plus the
   optional AI tools; an Intel Mac gets the same editor without AI.
2. Download the disk image for your Mac — `RetouchStudio-2.0.0-arm64.dmg` on Apple silicon,
   `RetouchStudio-2.0.0-x86_64.dmg` on Intel — together with the `.sha256` file beside it, and check
   the archive before opening it:
   ```bash
   shasum -a 256 -c RetouchStudio-2.0.0-arm64.dmg.sha256
   ```
3. Mount the image and drag **Retouch Studio.app** to **Applications**. The app is self-contained: it
   needs no other software.
4. Open it the way you would open any app. Because this build is signed ad-hoc and is not
   notarized — see the note below — macOS may say it cannot verify the app. In that case right-click
   (or Control-click) **Retouch Studio** in Applications, choose **Open**, and confirm once. If you
   dismissed that dialog already, open **System Settings → Privacy & Security**, find the message
   about Retouch Studio being blocked and press **Open Anyway** there, then start the app again. You
   only do this once; the second launch is normal.

**Why that prompt can appear, said plainly.** Retouch Studio is free, open-source software published
without an Apple Developer Program membership. Ad-hoc signing is therefore permanent for this project
and the app will never be notarized, which means Gatekeeper cannot clear it automatically the way it
clears a commercial download. This is a property of how the app is published, not a warning about
your copy of it: the checksum above is the way to satisfy yourself that the file you downloaded is
exactly the file we built. **This release has not been run through a first-launch test on a fresh
download on another Mac**, so treat step 4 as the expected path rather than a confirmed one, and tell
us if your macOS words something different.

**Updates are manual.** There is no automatic update in 2.0.0 and none is scheduled to arrive:
pressing **Check for Updates** in the About window answers
`The update check failed: This build has no update feed configured.` — in Persian, «بررسی به‌روزرسانی
انجام نشد: برای این نسخه هیچ منبع به‌روزرسانی تنظیم نشده است.» — and downloads nothing. To move
to a newer version, download its disk image and drag the app into Applications again; your projects,
presets and settings are kept.

### فارسی

۱. مطمئن شوید مک شما **macOS 14 Sonoma یا جدیدتر** را اجرا می‌کند. روی Apple silicon ویرایشگر کامل
به‌همراه ابزارهای اختیاری هوش مصنوعی نصب می‌شود؛ روی Intel همان ویرایشگر بدون هوش مصنوعی را دارید.

۲. دیسک‌ایمیج مناسب مک خود را دانلود کنید — `RetouchStudio-2.0.0-arm64.dmg` برای Apple silicon یا
`RetouchStudio-2.0.0-x86_64.dmg` برای Intel — به‌همراه فایل `.sha256` کنارش، و پیش از باز کردن از
درست بودن آن مطمئن شوید:
```bash
shasum -a 256 -c RetouchStudio-2.0.0-arm64.dmg.sha256
```

۳. دیسک‌ایمیج را باز کنید و **Retouch Studio.app** را به پوشهٔ **Applications** بکشید. اپ خودکفاست و
به هیچ نرم‌افزار دیگری نیاز ندارد.

۴. آن را مثل هر برنامهٔ دیگری باز کنید. چون این نسخه با امضای ad-hoc منتشر می‌شود و notarize نشده
است (توضیح پایین را ببینید)، ممکن است مک بگوید صحت این برنامه قابل بررسی نیست. در این حالت روی
**Retouch Studio** در پوشهٔ Applications راست‌کلیک کنید (یا کلید Control را نگه دارید و کلیک کنید)،
**Open** را انتخاب کنید و یک بار تأیید کنید. اگر آن پیام را بسته‌اید، به **System Settings → Privacy
& Security** بروید، پیام مسدود شدن Retouch Studio را پیدا کنید و همان‌جا **Open Anyway** را بزنید؛
سپس دوباره برنامه را باز کنید. این کار فقط یک بار لازم است و اجرای دوم عادی است.

**این پیام چرا ممکن است ظاهر شود، صریح بگوییم.** Retouch Studio یک نرم‌افزار آزاد و متن‌باز است که
بدون عضویت در برنامهٔ توسعه‌دهندگان اپل منتشر می‌شود. بنابراین امضای ad-hoc برای این پروژه دائمی است و
این برنامه هرگز notarize نخواهد شد؛ در نتیجه Gatekeeper نمی‌تواند آن را آن‌طور که یک دانلود تجاری را
خودکار مجاز می‌کند، مجاز بشناسد. این ویژگی روش انتشار ماست، نه هشداری دربارهٔ فایل شما: بهترین راه
اطمینان از اینکه دقیقاً همان فایلی را دانلود کرده‌اید که ما ساخته‌ایم، همان بررسی چک‌سام بالا است.
**این نسخه روی یک مک دیگر، با یک دانلود واقعی و اولین اجرای واقعی آزمایش نشده است**، پس مرحلهٔ ۴ را
مسیر انتظار بدانید نه مسیر تأییدشده، و اگر متن پیام مک شما چیزی متفاوت بود به ما بگویید.

**به‌روزرسانی دستی است.** در نسخهٔ ۲٫۰٫۰ به‌روزرسانی خودکار وجود ندارد و برای آینده هم برنامه‌ریزی
نشده است: اگر در پنجرهٔ About دکمهٔ **Check for Updates** را بزنید، این پاسخ را می‌گیرید: «بررسی
به‌روزرسانی انجام نشد: برای این نسخه هیچ منبع به‌روزرسانی تنظیم نشده است.» و چیزی دانلود نمی‌شود. برای
رفتن به نسخهٔ جدیدتر، دیسک‌ایمیج آن را دانلود کنید و دوباره اپ را داخل Applications
بکشید؛ پروژه‌ها، پیش‌تنظیم‌ها و تنظیمات شما حفظ می‌شوند.

---

## Privacy / حریم خصوصی

### English

Analysis, editing, masking, upscaling and export run entirely on your Mac. There is no telemetry, no
analytics, no crash-reporting service and no background request: the app has no server address built
into it, and the update check reads its feed from the app's own configuration, where this release
declares none. The only network use anywhere in the product is an approved download — a helper
runtime, when one is offered, or model weights — and each one happens only after you have seen its
size and licence. GPS and camera identity are removed from exported copies. Your photos are never
uploaded, in either language, in either direction.

### فارسی

تحلیل، ویرایش، ماسک‌گذاری، بزرگ‌نمایی و خروجی تماماً روی مک شما انجام می‌شود. هیچ تلمتری، هیچ
ابزار تحلیلی، هیچ سرویس گزارش خطا و هیچ درخواست پس‌زمینه‌ای وجود ندارد: هیچ آدرس سروری درون فایل
اجرایی برنامه ساخته نشده و بررسی به‌روزرسانی هم منبع خود را از پیکربندی خودِ برنامه می‌خواند که در این
نسخه خالی است. تنها استفاده از اینترنت در کل محصول، یک دانلودِ تأییدشده است — زمان اجرای کمک‌یار، اگر
پیشنهاد شود، یا وزن مدل‌ها — و هر کدام فقط پس از آنکه حجم و مجوزش را دیدید انجام می‌شود. موقعیت GPS و
مشخصات دوربین از فایل‌های خروجی حذف می‌شوند. عکس‌های شما هرگز آپلود نمی‌شوند.

---

## Requirements / نیازمندی‌ها

### English

| | macOS | Windows |
|---|---|---|
| System | macOS 14 Sonoma or later, Apple silicon or Intel | 64-bit Windows on a current release (the build targets the Windows 10 2004 SDK baseline or newer) |
| Editor | full: twelve tools, analysis, projects, presets, recovery, batch export | light editor: open/save, crop, orientation, nine global sliders, zoom and pan, compare, histogram, batch export, shared projects, history, recovery prompt |
| AI | optional, Apple silicon only, helper must be present | not available; the app states this |
| Language | English and Persian | English interface |
| Signatures | ad-hoc signed, not notarized | unsigned zip and MSI |

### فارسی

| | مک | ویندوز |
|---|---|---|
| سیستم | macOS 14 Sonoma یا جدیدتر، Apple silicon یا Intel | ویندوز شصت‌وچار بیتی روی یک نسخهٔ به‌روز (پایهٔ ساخت، SDK ویندوز ۱۰ نسخهٔ 2004 یا جدیدتر است) |
| ویرایشگر | کامل: دوازده ابزار، آنالیز، پروژه، پیش‌تنظیم، بازیابی، خروجی گروهی | ویرایشگر سبک: باز و ذخیره کردن، برش، چرخش، نه اسلایدر سراسری، بزرگ‌نمایی و جابه‌جایی، مقایسه، هیستوگرام، خروجی گروهی، پروژهٔ مشترک، تاریخچه، پرسش بازیابی |
| هوش مصنوعی | اختیاری، فقط Apple silicon، و کمک‌یار باید نصب باشد | موجود نیست؛ خودِ برنامه همین را اعلام می‌کند |
| زبان | فارسی و انگلیسی | رابط انگلیسی |
| امضا | امضای ad-hoc، بدون notarization | آرشیو zip و فایل MSI بدون امضا |

---

## Known limitations / محدودیت‌های شناخته‌شده

### English

- Signed ad-hoc and not notarized, so the first-launch override in step 4 is part of using the app.
- No automatic updates, by design.
- The AI helper is not carried by release builds and its automatic download is switched off in this
  version, so the AI tools report that the helper is unavailable unless you install a build that
  bundles it.
- AI needs Apple silicon. Intel Macs and every Windows machine get no AI, and the app refuses those
  edits with a stated reason instead of silently doing something else.
- Generative reimagining is not a working feature on the 16 GB reference Mac; its memory use was
  measured above what that machine has.
- One catalogued model, SAM 2.1 tiny, is listed but not downloadable today because the runtime
  package that loads it is missing; weights already on disk are verified and used.
- The consent sheet names the licences; it does not link to the licence evidence behind them.
- On Windows the installer is unsigned, so Windows warns about it before the first run, and the
  package carries fewer third-party notices than the macOS app does. The Windows interface is English
  only today; the Persian interface belongs to the Mac app.
- Output is sRGB by policy: a wide-gamut photo is converted and colours outside sRGB are clipped, and
  JPEG and PNG exports declare sRGB without embedding a colour profile.
- The very first export after starting the Mac can differ from later ones by one level in a channel,
  because of a cold graphics shader cache. It is cosmetic and already known.
- Large upscales are limited by memory and take time; the ceiling is 40 MP of output and the app
  tells you when a photo is over it.
- First launch of a downloaded build on a second Mac has not been exercised, so the Gatekeeper wording
  above is the intended path rather than an observed one.

### فارسی

- امضا از نوع ad-hoc است و notarization انجام نشده، پس همان اجازهٔ مرحلهٔ ۴ بخشی از استفاده از برنامه
  است.
- به‌روزرسانی خودکار وجود ندارد، و این یک تصمیم است.
- نسخه‌های منتشرشده کمک‌یار هوش مصنوعی را همراه ندارند و دانلود خودکار آن در این نسخه خاموش است؛ تا
  وقتی نسخه‌ای که کمک‌یار در آن بسته شده نصب نکرده‌اید، ابزارهای هوش مصنوعی اعلام می‌کنند که در دسترس
  نیستند.
- هوش مصنوعی به Apple silicon نیاز دارد. روی Intel و روی همهٔ ماشین‌های ویندوزی هوش مصنوعی نداریم و
  برنامه این ویرایش‌ها را با ذکر دلیل رد می‌کند، نه اینکه بی‌صدا کار دیگری بکند.
- بازآفرینی مولد روی مک مرجع ۱۶ گیگابایتی کار نمی‌کند؛ مصرف حافظهٔ آن بیشتر از ظرفیت این ماشین
  اندازه‌گیری شده است.
- یک مدل در فهرست — SAM 2.1 tiny — امروز قابل دانلود نیست، چون بستهٔ زمان‌اجرای بارگذاری آن موجود
  نیست؛ اگر وزن‌هایش از پیش روی دیسک باشند، بررسی و استفاده می‌شوند.
- برگهٔ رضایت نام مجوزها را می‌نویسد، ولی به مدرک پشت آن مجوز پیوند نمی‌دهد.
- روی ویندوز فایل نصب امضا ندارد، پس ویندوز پیش از نخستین اجرا دربارهٔ آن هشدار می‌دهد، و بستهٔ ویندوز
  کمتر از اپ مک یادداشت‌های اشخاص ثالث را همراه دارد. رابط ویندوز امروز انگلیسی است و رابط فارسی مخصوص
  اپ مک است.
- خروجی بر پایهٔ sRGB تولید می‌شود: عکس با فضای رنگ گسترده تبدیل می‌شود و رنگ‌های بیرون از sRGB بریده
  می‌شوند؛ در JPEG و PNG هم sRGB اعلام می‌شود بی‌آنکه پروفایل رنگ به فایل چسبانده شود.
- نخستین خروجی پس از روشن شدن مک ممکن است در یک کانال رنگ تا یک سطح با خروجی‌های بعدی فرق کند، چون
  حافظهٔ نهان شیدر گرافیک سرد است. ظاهری است و از قبل می‌دانیمش.
- بزرگ‌نمایی‌های بزرگ محدود به حافظه‌اند و زمان می‌برند؛ سقف خروجی ۴۰ مگاپیکسل است و اگر عکسی از آن
  عبور کند برنامه می‌گوید.
- اولین اجرای یک نسخهٔ دانلودشده روی یک مک دیگر آزمایش نشده است، پس متنی که بالا دربارهٔ Gatekeeper
  آمده مسیرِ درستِ انتظار است، نه چیزی که دیده باشیم.

---

## Licence / مجوز

### English

Retouch Studio is released under the MIT licence; the app also carries the notice text for the
third-party components it ships, including the bundled Vazir typeface, which is under the SIL Open
Font License. Model weights are never bundled — you download them yourself, and each set carries its
own licence, shown in the table above and repeated in the app before you approve a download.

### فارسی

Retouch Studio تحت مجوز MIT منتشر می‌شود؛ برنامه متن اطلاع‌رسانی اجزای اشخاص ثالثی را که همراه می‌آورد
هم دارد، از جمله قلم Vazir که زیر مجوز SIL Open Font License است. وزن مدل‌ها هرگز در بستهٔ برنامه
نیستند؛ خودتان دانلودشان می‌کنید و هر مجموعه مجوز خودش را دارد که در جدول بالا آمده و پیش از تأیید
دانلود درون برنامه هم نشان داده می‌شود.

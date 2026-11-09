import Foundation

/// One-line explanations shown when a slider is hovered.
///
/// The lines live together rather than beside each title because the same
/// title can mean different things in different sections: Saturation in Makeup
/// edits one cosmetic, Saturation in Color edits the whole frame, and HSL owns
/// a third one. Both languages stay in one file so an added case fails to
/// compile until the Persian line exists too.
enum SliderHint {
    // Skin
    case skinSmoothing
    case texturePreserve
    case blemishRemoval
    case wrinkleReduction
    case skinTone
    case darkCircles
    case skinBrightness
    case skinFinish
    case shine

    // Reshape
    case eyeSize
    case noseSize
    case noseTip
    case lipSize
    case cheekSize
    case jawWidth
    case chinLength
    case faceWidth
    case faceLength

    // Face detail
    case teethWhitening
    case eyeBrightness
    case eyeSharpen
    case irisEnhance
    case lashDarken
    case teethAlign
    case lensTint

    // Makeup
    case makeupHue
    case makeupSaturation
    case makeupOpacity
    case lipGloss
    case hairShine
    case hairVolume

    // Color and light
    case exposure
    case contrast
    case blacks
    case whites
    case colorSaturation
    case vibrance
    case warmth
    case clarity
    case splitTone
    case vignette

    // HSL
    case hslHue
    case hslSaturation
    case hslLuminance

    // Look
    case lookStrength
    case grain

    // Body
    case bodySmoothing
    case bodyBrightness
    case bodySlim
    case bodyWaist
    case bodyArms
    case bodyLegs

    // Background
    case backgroundBlur
    case backgroundTone
    case backgroundSaturation
    case backgroundFill
    case backdropStrength

    // Art
    case artSize
    case artRotation
    case artOpacity

    // Face analysis
    case analysisWeight
    case analysisStrength
    case analysisMargin

    // Export
    case exportQuality
    case watermarkOpacity
    case watermarkSize

    // Crop
    case straighten

    // AI mask
    case aiBrushSize
    case aiMaskExpand
    case aiMaskFeather

    var english: String {
        switch self {
        case .skinSmoothing:
            return "Softens uneven texture while keeping the skin's natural grain."
        case .texturePreserve:
            return "Keeps more pores and detail as smoothing increases."
        case .blemishRemoval:
            return "Heals spots by borrowing the skin around them."
        case .wrinkleReduction:
            return "Softens fine lines without flattening the face."
        case .skinTone:
            return "Evens out redness and patchy colour."
        case .darkCircles:
            return "Lifts the shadow under the eyes."
        case .skinBrightness:
            return "Lights or deepens the skin on its own."
        case .skinFinish:
            return "Moves the skin from matte toward glow."
        case .shine:
            return "Calms oily highlights on the skin."

        case .eyeSize:
            return "Makes the eyes larger or smaller."
        case .noseSize:
            return "Narrows or widens the nose."
        case .noseTip:
            return "Raises or lowers the tip of the nose."
        case .lipSize:
            return "Makes the lips fuller or thinner."
        case .cheekSize:
            return "Lifts or fills the cheeks."
        case .jawWidth:
            return "Narrows or widens the jawline."
        case .chinLength:
            return "Shortens or lengthens the chin."
        case .faceWidth:
            return "Narrows or widens the whole face."
        case .faceLength:
            return "Shortens or lengthens the whole face."

        case .teethWhitening:
            return "Takes yellow out of the teeth."
        case .eyeBrightness:
            return "Lifts the whites and the whole eye."
        case .eyeSharpen:
            return "Adds local contrast for clearer eyes."
        case .irisEnhance:
            return "Brings out the structure inside the iris."
        case .lashDarken:
            return "Deepens the lash line."
        case .teethAlign:
            return "Closes small gaps between teeth."
        case .lensTint:
            return "Lays a contact-lens colour over the iris."

        case .makeupHue:
            return "Shifts this cosmetic around the colour wheel."
        case .makeupSaturation:
            return "Makes this cosmetic more vivid or muted."
        case .makeupOpacity:
            return "Sets how strongly this cosmetic is laid on."
        case .lipGloss:
            return "Adds shine to the lips."
        case .hairShine:
            return "Adds sheen to the hair."
        case .hairVolume:
            return "Adds fullness to the hair."

        case .exposure:
            return "Brightens or darkens the whole frame."
        case .contrast:
            return "Pushes lights and darks apart."
        case .blacks:
            return "Lifts or deepens the darkest tones."
        case .whites:
            return "Lifts or holds back the brightest tones."
        case .colorSaturation:
            return "Changes colour intensity across the frame."
        case .vibrance:
            return "Boosts muted colours while sparing skin."
        case .warmth:
            return "Tilts the frame toward warm or cool."
        case .clarity:
            return "Adds mid-tone contrast for local punch."
        case .splitTone:
            return "Cools the shadows and warms the highlights."
        case .vignette:
            return "Darkens the frame toward the edges."

        case .hslHue:
            return "Rotates this colour band toward its neighbours."
        case .hslSaturation:
            return "Changes how vivid this colour band is."
        case .hslLuminance:
            return "Brightens or darkens this colour band."

        case .lookStrength:
            return "Blends the chosen film grade in."
        case .grain:
            return "Adds film grain over the frame."

        case .bodySmoothing:
            return "Softens skin on the body."
        case .bodyBrightness:
            return "Lights or deepens the body."
        case .bodySlim:
            return "Narrows the whole silhouette."
        case .bodyWaist:
            return "Narrows the waist between the hips and shoulders."
        case .bodyArms:
            return "Slims the arms from shoulder to elbow."
        case .bodyLegs:
            return "Slims the legs from hip to knee."

        case .backgroundBlur:
            return "Softens everything behind the subject."
        case .backgroundTone:
            return "Lights or deepens the background."
        case .backgroundSaturation:
            return "Changes background colour intensity."
        case .backgroundFill:
            return "Fills behind the subject with the chosen colour."
        case .backdropStrength:
            return "Sets how much of the backdrop image shows."

        case .artSize:
            return "Sets the size of the sticker."
        case .artRotation:
            return "Rotates the sticker."
        case .artOpacity:
            return "Sets how solid the sticker is."

        case .analysisWeight:
            return "Sets the thickness of the drawn lines."
        case .analysisStrength:
            return "Sets how strongly the lines show over the photo."
        case .analysisMargin:
            return "Sets the space between the face and the poster edge."

        case .exportQuality:
            return "Higher keeps more detail; lower makes a smaller file."
        case .watermarkOpacity:
            return "Sets how solid the signature is on saved copies."
        case .watermarkSize:
            return "Sets the size of the signature."

        case .straighten:
            return "Tilts the frame to level a slanted horizon."

        case .aiBrushSize:
            return "Sets the width of the mask brush."
        case .aiMaskExpand:
            return "Grows the selection slightly past its edge."
        case .aiMaskFeather:
            return "Softens the selection edge."
        }
    }

    var persian: String {
        switch self {
        case .skinSmoothing:
            return "بافت ناهموار پوست را نرم می‌کند و دانهٔ طبیعی آن را نگه می‌دارد."
        case .texturePreserve:
            return "هر چه بالاتر، با افزایش هموارسازی منافذ و جزئیات بیشتری می‌مانند."
        case .blemishRemoval:
            return "لک‌ها را با کمک پوست اطرافشان ترمیم می‌کند."
        case .wrinkleReduction:
            return "چروک‌های ریز را نرم می‌کند بدون اینکه چهره تخت شود."
        case .skinTone:
            return "سرخی و ناهمگونی رنگ پوست را یکدست می‌کند."
        case .darkCircles:
            return "سایهٔ زیر چشم را روشن می‌کند."
        case .skinBrightness:
            return "روشنی پوست را جدا از کل عکس بالا یا پایین می‌برد."
        case .skinFinish:
            return "پوست را از مات به سمت درخشش می‌برد."
        case .shine:
            return "براقی چربی پوست را کم می‌کند."

        case .eyeSize:
            return "چشم‌ها را بزرگ‌تر یا کوچک‌تر می‌کند."
        case .noseSize:
            return "بینی را باریک‌تر یا پهن‌تر می‌کند."
        case .noseTip:
            return "نوک بینی را بالا یا پایین می‌برد."
        case .lipSize:
            return "لب‌ها را پرتر یا نازک‌تر می‌کند."
        case .cheekSize:
            return "گونه‌ها را بالا می‌برد یا پر می‌کند."
        case .jawWidth:
            return "خط فک را باریک‌تر یا پهن‌تر می‌کند."
        case .chinLength:
            return "چانه را کوتاه‌تر یا بلندتر می‌کند."
        case .faceWidth:
            return "پهنای کل چهره را کم یا زیاد می‌کند."
        case .faceLength:
            return "طول کل چهره را کم یا زیاد می‌کند."

        case .teethWhitening:
            return "زردی دندان‌ها را می‌گیرد."
        case .eyeBrightness:
            return "سفیدی و کل چشم را روشن‌تر می‌کند."
        case .eyeSharpen:
            return "کنتراست موضعی چشم را زیاد می‌کند."
        case .irisEnhance:
            return "ساختار داخل عنبیه را بیرون می‌کشد."
        case .lashDarken:
            return "خط مژه را تیره‌تر می‌کند."
        case .teethAlign:
            return "فاصله‌های کوچک بین دندان‌ها را می‌بندد."
        case .lensTint:
            return "یک رنگ لنز تماسی روی عنبیه می‌گذارد."

        case .makeupHue:
            return "رنگ این آرایش را روی چرخ رنگ جابه‌جا می‌کند."
        case .makeupSaturation:
            return "این آرایش را پررنگ‌تر یا کم‌رنگ‌تر می‌کند."
        case .makeupOpacity:
            return "میزان نشستن این آرایش روی پوست را تعیین می‌کند."
        case .lipGloss:
            return "براقی به لب‌ها اضافه می‌کند."
        case .hairShine:
            return "درخشش به مو اضافه می‌کند."
        case .hairVolume:
            return "به حجم مو اضافه می‌کند."

        case .exposure:
            return "کل کادر را روشن‌تر یا تیره‌تر می‌کند."
        case .contrast:
            return "روشن‌ها و تیره‌ها را از هم دور می‌کند."
        case .blacks:
            return "تیره‌ترین تُن‌ها را بالا می‌کشد یا عمیق‌تر می‌کند."
        case .whites:
            return "روشن‌ترین تُن‌ها را بالا می‌برد یا عقب نگه می‌دارد."
        case .colorSaturation:
            return "شدت رنگ را در کل کادر تغییر می‌دهد."
        case .vibrance:
            return "رنگ‌های کم‌رنگ را تقویت می‌کند و پوست را دست‌نخورده نگه می‌دارد."
        case .warmth:
            return "کادر را گرم‌تر یا سردتر می‌کند."
        case .clarity:
            return "کنتراست میان‌تُن برای ضربهٔ موضعی اضافه می‌کند."
        case .splitTone:
            return "سایه‌ها را سرد و هایلایت‌ها را گرم می‌کند."
        case .vignette:
            return "گوشه‌های کادر را تیره‌تر می‌کند."

        case .hslHue:
            return "این باند رنگی را به سمت باندهای همسایه می‌چرخاند."
        case .hslSaturation:
            return "شدت این باند رنگی را تغییر می‌دهد."
        case .hslLuminance:
            return "این باند رنگی را روشن‌تر یا تیره‌تر می‌کند."

        case .lookStrength:
            return "میزان آمیختن گرید فیلم انتخابی را تعیین می‌کند."
        case .grain:
            return "دانهٔ فیلم روی کادر می‌پاشد."

        case .bodySmoothing:
            return "پوست بدن را نرم می‌کند."
        case .bodyBrightness:
            return "بدن را روشن‌تر یا تیره‌تر می‌کند."
        case .bodySlim:
            return "کل اندام را باریک‌تر می‌کند."
        case .bodyWaist:
            return "کمر را بین لگن و شانه‌ها باریک‌تر می‌کند."
        case .bodyArms:
            return "بازوها را از شانه تا آرنج باریک می‌کند."
        case .bodyLegs:
            return "پاها را از لگن تا زانو باریک می‌کند."

        case .backgroundBlur:
            return "هر چیزی پشت سوژه را نرم می‌کند."
        case .backgroundTone:
            return "پس‌زمینه را روشن‌تر یا تیره‌تر می‌کند."
        case .backgroundSaturation:
            return "شدت رنگ پس‌زمینه را تغییر می‌دهد."
        case .backgroundFill:
            return "پشت سوژه را با رنگ انتخابی پر می‌کند."
        case .backdropStrength:
            return "میزان دیده‌شدن تصویر پس‌زمینه را تعیین می‌کند."

        case .artSize:
            return "اندازهٔ برچسب را تعیین می‌کند."
        case .artRotation:
            return "برچسب را می‌چرخاند."
        case .artOpacity:
            return "میزان توپُر بودن برچسب را تعیین می‌کند."

        case .analysisWeight:
            return "ضخامت خطوط کشیده‌شده را تعیین می‌کند."
        case .analysisStrength:
            return "میزان دیده‌شدن خطوط روی عکس را تعیین می‌کند."
        case .analysisMargin:
            return "فاصلهٔ چهره تا لبهٔ پوستر را تعیین می‌کند."

        case .exportQuality:
            return "بالاتر جزئیات بیشتری نگه می‌دارد؛ پایین‌تر فایل کوچک‌تر می‌سازد."
        case .watermarkOpacity:
            return "میزان توپُر بودن امضا در نسخه‌های ذخیره‌شده را تعیین می‌کند."
        case .watermarkSize:
            return "اندازهٔ متن امضا را تعیین می‌کند."

        case .straighten:
            return "کادر را می‌چرخاند تا افق کج تراز شود."

        case .aiBrushSize:
            return "پهنای قلم ماسک را تعیین می‌کند."
        case .aiMaskExpand:
            return "انتخاب را کمی از لبه‌اش فراتر می‌برد."
        case .aiMaskFeather:
            return "لبهٔ انتخاب را نرم می‌کند."
        }
    }
}

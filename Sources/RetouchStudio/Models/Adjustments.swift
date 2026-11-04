import Foundation

/// Every retouch setting, in clearly separated groups so the two Auto actions
/// stay independent and each effect can be individually reset:
///
///   * skin (retouch) — texture and tone of the face
///   * reshape        — geometry of facial features
///   * makeup         — colour cosmetics on lips, cheeks and brows
///   * color/light    — global tonality
///   * look           — film grade and grain
///
/// All amounts are -100...100 or 0...100 with 0 meaning "no change", so a fresh
/// `Adjustments()` is a genuine no-op.
struct Adjustments: Equatable, Codable {

    // MARK: - Skin (retouch)
    var smooth: Double = 0            // overall smoothing amount
    var blemish: Double = 0           // acne / spots
    var wrinkle: Double = 0           // fine lines
    var skinToneEvens: Double = 0     // skin tone correction / evening
    var darkCircles: Double = 0       // under-eye correction
    var skinBrighten: Double = 0      // brightness
    var texturePreserve: Double = 0   // 0 = plain blur, 100 = keep maximum texture
    var teethWhiten: Double = 0
    var eyeBrighten: Double = 0
    var eyeSharpen: Double = 0

    // MARK: - Reshape (geometry)
    var eyeSize: Double = 0
    var noseSize: Double = 0
    var noseTip: Double = 0
    var lipSize: Double = 0
    var cheekSize: Double = 0
    var jawWidth: Double = 0
    var chinLength: Double = 0
    var faceWidth: Double = 0
    var faceLength: Double = 0

    // MARK: - Color and light (global)
    var exposure: Double = 0
    var contrast: Double = 0
    /// Input level mapped to black. Positive digs the shadows out — the cure
    /// for a faded frame — and negative lets them glow.
    var blacks: Double = 0
    /// Input level mapped to white. Positive lifts the highlights.
    var whites: Double = 0
    var saturation: Double = 0
    var vibrance: Double = 0
    var warmth: Double = 0
    var clarity: Double = 0
    var vignette: Double = 0

    // MARK: - Look (film grade and grain)
    //
    // `lookID` is the raw value of a `FilmLook`; an empty string means no look
    // is applied, so a fresh `Adjustments()` is still a genuine no-op.
    var lookID: String = ""
    var lookStrength: Double = 0    // 0...100, how far the grade is blended in
    var grain: Double = 0           // 0...100

    /// The look as an enum; an unknown identifier reads as no look.
    var look: FilmLook {
        get { FilmLook.named(lookID) }
        set { lookID = newValue.rawValue }
    }

    // MARK: Levels

    /// The input values the Blacks/Whites sliders map to black and white, in
    /// display-referred light. ±100 moves an endpoint by 0.30 — far enough to
    /// pull a genuinely faded frame back to the ends of the range, and safe to
    /// ask for because `LookEngine.applyLevels` spends that move on the shadows
    /// and highlights only, never on the mid-tones in between.
    ///
    /// A black level above zero digs the shadows out; below zero it lets them
    /// glow, which is how a matte fade is made. A white level below one lifts the
    /// highlights, above one compresses them.
    var blackLevel: Double { 0.30 * blacks / 100 }
    var whiteLevel: Double { 1 - 0.30 * whites / 100 }

    // MARK: - Makeup (colour cosmetics)
    //
    // Every region owns its colour and its amount, so a lip and a cheek can be
    // different colours and the two eye tools get their own. The colours are
    // full HSV values rather than palette identifiers: the picker and the hue /
    // saturation sliders edit them directly, and a project saved by the older,
    // palette-only build is migrated from its shade identifier on decode.
    var lipTint: Double = 0
    var lipColor: MakeupColor = MakeupShade.rose.color
    var blush: Double = 0
    var blushColor: MakeupColor = MakeupShade.cheekPeach.color
    var browDefine: Double = 0
    var browColor: MakeupColor = MakeupShade.taupeBrow.color
    var eyeshadow: Double = 0
    var shadowColor: MakeupColor = MakeupShade.taupeShadow.color
    var eyeliner: Double = 0
    var linerColor: MakeupColor = MakeupShade.inkLiner.color

    // MARK: - Skin finish and detail
    //
    // Kept apart from the smoothing group: these decide how the finished skin
    // *reads* — matte or dewy, shiny or calm — and how much structure the eye
    // and lash keep. All are appended after the original fields so a project
    // written before they existed decodes to "no change".
    var skinFinish: Double = 0      // -100 matte ... +100 glow
    var shine: Double = 0           // 0...100, calms specular on the skin
    var irisEnhance: Double = 0     // 0...100, local contrast inside the iris
    var lashDarken: Double = 0      // 0...100
    var lipGloss: Double = 0        // 0...100
    var splitTone: Double = 0       // 0...100, cool shadows / warm highlights

    // MARK: - Body and background
    //
    // These run from the on-device person mask rather than from face landmarks,
    // so they work on a full-length portrait where the face is only a small
    // part of the frame.
    var bodySmooth: Double = 0          // 0...100
    var bodyTone: Double = 0            // -100...100
    var bodySlim: Double = 0            // -100...100, positive narrows
    var backgroundBlur: Double = 0      // 0...100
    var backgroundTone: Double = 0      // -100...100
    var backgroundSaturation: Double = 0 // -100...100

    // MARK: - Pose-driven body shaping
    //
    // Appended after the silhouette controls so a project written before the
    // pose joints existed still decodes to "no change". Positive narrows, the
    // same direction as Body Slim.
    var bodyWaist: Double = 0           // -100...100
    var bodyArms: Double = 0            // -100...100
    var bodyLegs: Double = 0            // -100...100

    // MARK: - Hair
    //
    // Hair is makeup in the cosmetic sense — a pigment over its own shading —
    // but it is driven by the head band rather than a face landmark.
    var hairColor: Double = 0           // 0...100
    var hairTint: MakeupColor = MakeupShade.hairEspresso.color
    var hairShine: Double = 0           // 0...100

    // MARK: - Contour
    //
    // Sculpting shade under the cheekbone and along the jaw. It lives with the
    // cosmetics because it is the same operation: a colour laid over shading.
    var contour: Double = 0             // 0...100
    var contourColor: MakeupColor = MakeupShade.contourSoft.color

    // MARK: - Tone curve
    //
    // Three anchors rather than an editable spline. A curve is judged at the
    // shadows, the mid-tones and the highlights; the engine interpolates
    // smoothly between them on luminance, so colour is untouched.
    var curveShadows: Double = 0        // -100...100
    var curveMidtones: Double = 0       // -100...100
    var curveHighlights: Double = 0     // -100...100

    // MARK: - HSL
    //
    // Per-hue-band adjustment, indexed by `HSLBand`. Arrays rather than 24
    // stored properties: the bands are a fixed list, and the sliders edit one
    // component of one band at a time.
    var hslHue: [Double] = Array(repeating: 0, count: HSLBand.allCases.count)
    var hslSaturation: [Double] = Array(repeating: 0, count: HSLBand.allCases.count)
    var hslLuminance: [Double] = Array(repeating: 0, count: HSLBand.allCases.count)

    // MARK: - Iris colour and teeth alignment
    //
    // A contact lens is a pigment on the iris that keeps its striations, which
    // is the same operation as lipstick on a lip — so it rides the same
    // luminance-preserving tint and stays in the retouch group.
    var lensTint: Double = 0            // 0...100
    var lensColor: MakeupColor = MakeupColor(hue: 210, saturation: 0.45, value: 0.48)
    /// Closes the dark gaps between teeth by borrowing the enamel around them,
    /// so a spaced or uneven smile reads straighter without warping the jaw.
    var teethAlign: Double = 0          // 0...100

    // MARK: - Hair volume
    //
    // A radial bulge confined to the hair band. It is a makeup-group tool
    // because it changes how the hair reads rather than the face's geometry.
    var hairVolume: Double = 0          // 0...100

    // MARK: - Background replacement
    //
    // Fill puts a solid colour behind the subject; removal makes the background
    // transparent so an export can be dropped onto another backdrop. Both read
    // the same feathered person mask as blur/tone/saturation.
    var backgroundFill: Double = 0      // 0...100
    var backgroundFillColor: MakeupColor = MakeupColor(hue: 0, saturation: 0, value: 0.96)
    var backgroundRemove: Bool = false

    static let zero = Adjustments()

    var isIdentity: Bool { self == .zero }

    // MARK: - Field sets

    /// Which retouch sliders a patch is allowed to overwrite. A zero in a
    /// measured field is a real answer ("nothing to correct"); a field that was
    /// never measured is the owner's and must not be cleared by accident.
    struct RetouchField: OptionSet {
        let rawValue: Int
        init(rawValue: Int) { self.rawValue = rawValue }

        static let smooth = RetouchField(rawValue: 1 << 0)
        static let blemish = RetouchField(rawValue: 1 << 1)
        static let wrinkle = RetouchField(rawValue: 1 << 2)
        static let skinToneEvens = RetouchField(rawValue: 1 << 3)
        static let darkCircles = RetouchField(rawValue: 1 << 4)
        static let skinBrighten = RetouchField(rawValue: 1 << 5)
        static let texturePreserve = RetouchField(rawValue: 1 << 6)
        static let teethWhiten = RetouchField(rawValue: 1 << 7)
        static let eyeBrighten = RetouchField(rawValue: 1 << 8)
        static let eyeSharpen = RetouchField(rawValue: 1 << 9)
        static let skinFinish = RetouchField(rawValue: 1 << 10)
        static let shine = RetouchField(rawValue: 1 << 11)
        static let irisEnhance = RetouchField(rawValue: 1 << 12)
        static let lashDarken = RetouchField(rawValue: 1 << 13)
        static let lensTint = RetouchField(rawValue: 1 << 14)
        static let lensColor = RetouchField(rawValue: 1 << 15)
        static let teethAlign = RetouchField(rawValue: 1 << 16)

        static let all: RetouchField = [
            .smooth, .blemish, .wrinkle, .skinToneEvens, .darkCircles,
            .skinBrighten, .texturePreserve, .teethWhiten, .eyeBrighten,
            .eyeSharpen, .skinFinish, .shine, .irisEnhance, .lashDarken,
            .lensTint, .lensColor, .teethAlign,
        ]

        /// Exactly what `SmartAnalyzer.retouchValues` writes. Keep this next to
        /// that function's assignments; the coverage test fails if they drift.
        static let smart: RetouchField = [
            .smooth, .blemish, .wrinkle, .skinToneEvens, .darkCircles,
            .skinBrighten, .texturePreserve, .shine, .teethWhiten,
            .eyeBrighten, .eyeSharpen,
        ]
    }

    /// The same contract for global colour and light.
    struct ColorField: OptionSet {
        let rawValue: Int
        init(rawValue: Int) { self.rawValue = rawValue }

        static let exposure = ColorField(rawValue: 1 << 0)
        static let contrast = ColorField(rawValue: 1 << 1)
        static let blacks = ColorField(rawValue: 1 << 2)
        static let whites = ColorField(rawValue: 1 << 3)
        static let saturation = ColorField(rawValue: 1 << 4)
        static let vibrance = ColorField(rawValue: 1 << 5)
        static let warmth = ColorField(rawValue: 1 << 6)
        static let clarity = ColorField(rawValue: 1 << 7)
        static let vignette = ColorField(rawValue: 1 << 8)
        static let splitTone = ColorField(rawValue: 1 << 9)
        static let curveShadows = ColorField(rawValue: 1 << 10)
        static let curveMidtones = ColorField(rawValue: 1 << 11)
        static let curveHighlights = ColorField(rawValue: 1 << 12)
        static let hslHue = ColorField(rawValue: 1 << 13)
        static let hslSaturation = ColorField(rawValue: 1 << 14)
        static let hslLuminance = ColorField(rawValue: 1 << 15)

        static let all: ColorField = [
            .exposure, .contrast, .blacks, .whites, .saturation, .vibrance,
            .warmth, .clarity, .vignette, .splitTone, .curveShadows,
            .curveMidtones, .curveHighlights, .hslHue, .hslSaturation,
            .hslLuminance,
        ]

        /// What `AutoAnalyzer.autoColorLight` can assign. Vignette, split tone,
        /// curves and HSL are taste or never measured, so they stay untouched.
        static let autoColorLight: ColorField = [
            .exposure, .contrast, .blacks, .whites, .saturation, .vibrance,
            .warmth, .clarity,
        ]
    }

    // MARK: - Group views

    /// The retouch half, with geometry and color/light zeroed.
    var retouchOnly: Adjustments {
        var a = Adjustments()
        a.smooth = smooth
        a.blemish = blemish
        a.wrinkle = wrinkle
        a.skinToneEvens = skinToneEvens
        a.darkCircles = darkCircles
        a.skinBrighten = skinBrighten
        a.texturePreserve = texturePreserve
        a.teethWhiten = teethWhiten
        a.eyeBrighten = eyeBrighten
        a.eyeSharpen = eyeSharpen
        a.skinFinish = skinFinish
        a.shine = shine
        a.irisEnhance = irisEnhance
        a.lashDarken = lashDarken
        a.lensTint = lensTint
        a.lensColor = lensColor
        a.teethAlign = teethAlign
        return a
    }

    /// The geometry half, with everything else zeroed.
    var reshapeOnly: Adjustments {
        var a = Adjustments()
        a.eyeSize = eyeSize
        a.noseSize = noseSize
        a.noseTip = noseTip
        a.lipSize = lipSize
        a.cheekSize = cheekSize
        a.jawWidth = jawWidth
        a.chinLength = chinLength
        a.faceWidth = faceWidth
        a.faceLength = faceLength
        return a
    }

    /// The color/light half, with everything else zeroed.
    var colorLightOnly: Adjustments {
        var a = Adjustments()
        a.exposure = exposure
        a.contrast = contrast
        a.blacks = blacks
        a.whites = whites
        a.saturation = saturation
        a.vibrance = vibrance
        a.warmth = warmth
        a.clarity = clarity
        a.vignette = vignette
        a.splitTone = splitTone
        a.curveShadows = curveShadows
        a.curveMidtones = curveMidtones
        a.curveHighlights = curveHighlights
        a.hslHue = hslHue
        a.hslSaturation = hslSaturation
        a.hslLuminance = hslLuminance
        return a
    }

    /// Does any face-dependent tool have an effect?
    var usesFaceTools: Bool { retouchOnly != .zero || reshapeOnly != .zero || makeupOnly != .zero }

    var hasReshape: Bool { reshapeOnly != .zero }

    /// The look half: grade and grain, with everything else zeroed.
    var lookOnly: Adjustments {
        var a = Adjustments()
        a.lookID = lookID
        a.lookStrength = lookStrength
        a.grain = grain
        return a
    }

    var hasLook: Bool { lookOnly != .zero }

    /// The makeup half: lips, cheeks, brows and the two eye pigments.
    var makeupOnly: Adjustments {
        var a = Adjustments()
        a.lipTint = lipTint
        a.lipColor = lipColor
        a.blush = blush
        a.blushColor = blushColor
        a.browDefine = browDefine
        a.browColor = browColor
        a.eyeshadow = eyeshadow
        a.shadowColor = shadowColor
        a.eyeliner = eyeliner
        a.linerColor = linerColor
        a.lipGloss = lipGloss
        a.hairColor = hairColor
        a.hairTint = hairTint
        a.hairShine = hairShine
        a.hairVolume = hairVolume
        a.contour = contour
        a.contourColor = contourColor
        return a
    }

    /// The body half. These are the only controls that need the person mask.
    var bodyOnly: Adjustments {
        var a = Adjustments()
        a.bodySmooth = bodySmooth
        a.bodyTone = bodyTone
        a.bodySlim = bodySlim
        a.bodyWaist = bodyWaist
        a.bodyArms = bodyArms
        a.bodyLegs = bodyLegs
        return a
    }

    /// The background half.
    var backgroundOnly: Adjustments {
        var a = Adjustments()
        a.backgroundBlur = backgroundBlur
        a.backgroundTone = backgroundTone
        a.backgroundSaturation = backgroundSaturation
        a.backgroundFill = backgroundFill
        a.backgroundFillColor = backgroundFillColor
        a.backgroundRemove = backgroundRemove
        return a
    }

    /// True when a control needs the person mask, so the mask is only built
    /// when one of these tools is actually in use. Hair needs it too: the head
    /// band would otherwise tint a wall behind the subject.
    var usesPersonTools: Bool {
        bodyOnly != .zero || backgroundOnly != .zero
            || hairColor != 0 || hairShine != 0 || hairVolume != 0
    }

    var hasMakeup: Bool { makeupOnly != .zero }

    // MARK: - Composing groups (keeps the Auto actions independent)

    /// Copy with ONLY the makeup fields taken from `patch`.
    func applyingMakeup(_ patch: Adjustments) -> Adjustments {
        var result = self
        result.lipTint = patch.lipTint
        result.lipColor = patch.lipColor
        result.blush = patch.blush
        result.blushColor = patch.blushColor
        result.browDefine = patch.browDefine
        result.browColor = patch.browColor
        result.eyeshadow = patch.eyeshadow
        result.shadowColor = patch.shadowColor
        result.eyeliner = patch.eyeliner
        result.linerColor = patch.linerColor
        result.lipGloss = patch.lipGloss
        result.hairColor = patch.hairColor
        result.hairTint = patch.hairTint
        result.hairShine = patch.hairShine
        result.hairVolume = patch.hairVolume
        result.contour = patch.contour
        result.contourColor = patch.contourColor
        return result
    }

    /// Copy with ONLY the look fields taken from `patch`.
    func applyingLook(_ patch: Adjustments) -> Adjustments {
        var result = self
        result.lookID = patch.lookID
        result.lookStrength = patch.lookStrength
        result.grain = patch.grain
        return result
    }

    /// Copy with ONLY the color/light fields in `fields` taken from `patch`.
    func applyingColorLight(_ patch: Adjustments,
                            fields: ColorField = .all) -> Adjustments {
        var result = self
        if fields.contains(.exposure) { result.exposure = patch.exposure }
        if fields.contains(.contrast) { result.contrast = patch.contrast }
        if fields.contains(.blacks) { result.blacks = patch.blacks }
        if fields.contains(.whites) { result.whites = patch.whites }
        if fields.contains(.saturation) { result.saturation = patch.saturation }
        if fields.contains(.vibrance) { result.vibrance = patch.vibrance }
        if fields.contains(.warmth) { result.warmth = patch.warmth }
        if fields.contains(.clarity) { result.clarity = patch.clarity }
        if fields.contains(.vignette) { result.vignette = patch.vignette }
        if fields.contains(.splitTone) { result.splitTone = patch.splitTone }
        if fields.contains(.curveShadows) { result.curveShadows = patch.curveShadows }
        if fields.contains(.curveMidtones) { result.curveMidtones = patch.curveMidtones }
        if fields.contains(.curveHighlights) { result.curveHighlights = patch.curveHighlights }
        if fields.contains(.hslHue) { result.hslHue = patch.hslHue }
        if fields.contains(.hslSaturation) { result.hslSaturation = patch.hslSaturation }
        if fields.contains(.hslLuminance) { result.hslLuminance = patch.hslLuminance }
        return result
    }

    /// Copy with ONLY the retouch fields in `fields` taken from `patch`.
    func applyingRetouch(_ patch: Adjustments,
                         fields: RetouchField = .all) -> Adjustments {
        var result = self
        if fields.contains(.smooth) { result.smooth = patch.smooth }
        if fields.contains(.blemish) { result.blemish = patch.blemish }
        if fields.contains(.wrinkle) { result.wrinkle = patch.wrinkle }
        if fields.contains(.skinToneEvens) { result.skinToneEvens = patch.skinToneEvens }
        if fields.contains(.darkCircles) { result.darkCircles = patch.darkCircles }
        if fields.contains(.skinBrighten) { result.skinBrighten = patch.skinBrighten }
        if fields.contains(.texturePreserve) { result.texturePreserve = patch.texturePreserve }
        if fields.contains(.teethWhiten) { result.teethWhiten = patch.teethWhiten }
        if fields.contains(.eyeBrighten) { result.eyeBrighten = patch.eyeBrighten }
        if fields.contains(.eyeSharpen) { result.eyeSharpen = patch.eyeSharpen }
        if fields.contains(.skinFinish) { result.skinFinish = patch.skinFinish }
        if fields.contains(.shine) { result.shine = patch.shine }
        if fields.contains(.irisEnhance) { result.irisEnhance = patch.irisEnhance }
        if fields.contains(.lashDarken) { result.lashDarken = patch.lashDarken }
        if fields.contains(.lensTint) { result.lensTint = patch.lensTint }
        if fields.contains(.lensColor) { result.lensColor = patch.lensColor }
        if fields.contains(.teethAlign) { result.teethAlign = patch.teethAlign }
        return result
    }

    /// Scales the strength of an auto-generated retouch patch. Only the actual
    /// effects are scaled; `texturePreserve` is a preference about how the
    /// smoothing looks, so it is carried over unchanged.
    func scaledRetouch(by percent: Double) -> Adjustments {
        let factor = min(1, max(0, percent / 100))
        var result = self
        result.smooth = smooth * factor
        result.blemish = blemish * factor
        result.wrinkle = wrinkle * factor
        result.skinToneEvens = skinToneEvens * factor
        result.darkCircles = darkCircles * factor
        result.skinBrighten = skinBrighten * factor
        result.teethWhiten = teethWhiten * factor
        result.eyeBrighten = eyeBrighten * factor
        result.eyeSharpen = eyeSharpen * factor
        result.skinFinish = skinFinish * factor
        result.shine = shine * factor
        result.irisEnhance = irisEnhance * factor
        result.lashDarken = lashDarken * factor
        result.lensTint = lensTint * factor
        result.teethAlign = teethAlign * factor
        return result
    }

    /// Scales an auto-generated color/light patch. Every field in this group is
    /// an effect, so all of them move together with the strength.
    func scaledColorLight(by percent: Double) -> Adjustments {
        let factor = min(1, max(0, percent / 100))
        var result = self
        result.exposure = exposure * factor
        result.contrast = contrast * factor
        result.blacks = blacks * factor
        result.whites = whites * factor
        result.saturation = saturation * factor
        result.vibrance = vibrance * factor
        result.warmth = warmth * factor
        result.clarity = clarity * factor
        result.splitTone = splitTone * factor
        result.curveShadows = curveShadows * factor
        result.curveMidtones = curveMidtones * factor
        result.curveHighlights = curveHighlights * factor
        result.hslHue = hslHue.map { $0 * factor }
        result.hslSaturation = hslSaturation.map { $0 * factor }
        result.hslLuminance = hslLuminance.map { $0 * factor }
        return result
    }

    /// Copy with ONLY the geometry fields taken from `patch`.
    func applyingReshape(_ patch: Adjustments) -> Adjustments {
        var result = self
        result.eyeSize = patch.eyeSize
        result.noseSize = patch.noseSize
        result.noseTip = patch.noseTip
        result.lipSize = patch.lipSize
        result.cheekSize = patch.cheekSize
        result.jawWidth = patch.jawWidth
        result.chinLength = patch.chinLength
        result.faceWidth = patch.faceWidth
        result.faceLength = patch.faceLength
        return result
    }

    /// Copy with ONLY the body fields taken from `patch`.
    func applyingBody(_ patch: Adjustments) -> Adjustments {
        var result = self
        result.bodySmooth = patch.bodySmooth
        result.bodyTone = patch.bodyTone
        result.bodySlim = patch.bodySlim
        result.bodyWaist = patch.bodyWaist
        result.bodyArms = patch.bodyArms
        result.bodyLegs = patch.bodyLegs
        return result
    }

    /// Copy with ONLY the background fields taken from `patch`.
    func applyingBackground(_ patch: Adjustments) -> Adjustments {
        var result = self
        result.backgroundBlur = patch.backgroundBlur
        result.backgroundTone = patch.backgroundTone
        result.backgroundSaturation = patch.backgroundSaturation
        result.backgroundFill = patch.backgroundFill
        result.backgroundFillColor = patch.backgroundFillColor
        result.backgroundRemove = patch.backgroundRemove
        return result
    }
}

/// The eight hue bands the HSL tool edits. Centres are degrees on the colour
/// wheel; the half-width is how far the band reaches before its neighbour takes
/// over, chosen so reds and skin stay narrow while greens get room.
enum HSLBand: Int, CaseIterable, Identifiable, Codable {
    case red, orange, yellow, green, cyan, blue, purple, magenta

    var id: Int { rawValue }

    var title: String {
        L10n.current.hueBandTitle(self)
    }

    /// Centre of the band in degrees.
    var centerHue: Double {
        switch self {
        case .red: return 0
        case .orange: return 30
        case .yellow: return 60
        case .green: return 120
        case .cyan: return 180
        case .blue: return 240
        case .purple: return 285
        case .magenta: return 320
        }
    }

    /// Half-width of the smooth window in degrees. The windows overlap, and the
    /// engine normalises by their sum, so a colour sitting between two bands
    /// receives a share of both instead of a hard step.
    var halfWidth: Double {
        switch self {
        case .red, .magenta: return 26
        case .orange: return 24
        case .yellow: return 30
        case .green: return 44
        case .cyan: return 34
        case .blue: return 44
        case .purple: return 30
        }
    }

    /// A band's self-check fixture colour, in 8-bit sRGB.
    var sampleColor: (r: Double, g: Double, b: Double) {
        switch self {
        case .red: return (0.78, 0.12, 0.10)
        case .orange: return (0.86, 0.44, 0.10)
        case .yellow: return (0.86, 0.80, 0.12)
        case .green: return (0.16, 0.62, 0.20)
        case .cyan: return (0.10, 0.62, 0.66)
        case .blue: return (0.12, 0.24, 0.78)
        case .purple: return (0.44, 0.18, 0.66)
        case .magenta: return (0.72, 0.12, 0.58)
        }
    }
}

/// The independent tool groups. Used for per-group reset and to keep the two
/// Auto actions honest about what they touch.
enum AdjustmentGroup: String, CaseIterable, Identifiable {
    case skin, reshape, makeup, colorLight, look, body, background
    var id: String { rawValue }
}

// MARK: - Coding
//
// A project saved by an older build simply lacks the keys added since. Every
// field defaults to "no change", so a missing key reads as that default instead
// of failing the whole file. Living in an extension keeps the memberwise
// initialiser that the presets below are written with.
extension Adjustments {

    enum CodingKeys: String, CodingKey {
        case smooth, blemish, wrinkle, skinToneEvens, darkCircles, skinBrighten
        case texturePreserve, teethWhiten, eyeBrighten, eyeSharpen
        case eyeSize, noseSize, noseTip, lipSize, cheekSize, jawWidth, chinLength
        case faceWidth, faceLength
        case exposure, contrast, saturation, vibrance, warmth, clarity, vignette
        case blacks, whites
        case lookID, lookStrength, grain
        case lipTint, lipColor, blush, blushColor, browDefine, browColor
        case eyeshadow, shadowColor, eyeliner, linerColor
        case skinFinish, shine, irisEnhance, lashDarken, lipGloss, splitTone
        case bodySmooth, bodyTone, bodySlim
        case backgroundBlur, backgroundTone, backgroundSaturation
        case bodyWaist, bodyArms, bodyLegs
        case hairColor, hairTint, hairShine
        case contour, contourColor
        case curveShadows, curveMidtones, curveHighlights
        case hslHue, hslSaturation, hslLuminance
        case lensTint, lensColor, teethAlign, hairVolume
        case backgroundFill, backgroundFillColor, backgroundRemove
        // Written by the palette-only builds; read to migrate old projects.
        case lipShadeID, blushShadeID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func amount(_ key: CodingKeys) -> Double {
            (try? c.decodeIfPresent(Double.self, forKey: key)) ?? 0
        }
        func text(_ key: CodingKeys) -> String {
            (try? c.decodeIfPresent(String.self, forKey: key)) ?? ""
        }
        func flag(_ key: CodingKeys) -> Bool {
            ((try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil) ?? false
        }
        /// A per-band array, padded or trimmed to the current band count so a
        /// file written by a build with a different band list still decodes.
        func bands(_ key: CodingKeys) -> [Double] {
            let count = HSLBand.allCases.count
            var values = ((try? c.decodeIfPresent([Double].self, forKey: key)) ?? nil) ?? []
            if values.count < count {
                values += Array(repeating: 0, count: count - values.count)
            }
            return values.prefix(count).map { min(100, max(-100, $0)) }
        }
        /// A colour key, with the old shade identifier as the fallback: a file
        /// written before the picker existed names a palette entry instead.
        func color(_ key: CodingKeys, legacy: CodingKeys? = nil, fallback: MakeupColor) -> MakeupColor {
            if let stored = (try? c.decodeIfPresent(MakeupColor.self, forKey: key)) ?? nil {
                return stored
            }
            if let legacy, let shade = MakeupShade(rawValue: text(legacy)) {
                return shade.color
            }
            return fallback
        }
        smooth = amount(.smooth)
        blemish = amount(.blemish)
        wrinkle = amount(.wrinkle)
        skinToneEvens = amount(.skinToneEvens)
        darkCircles = amount(.darkCircles)
        skinBrighten = amount(.skinBrighten)
        texturePreserve = amount(.texturePreserve)
        teethWhiten = amount(.teethWhiten)
        eyeBrighten = amount(.eyeBrighten)
        eyeSharpen = amount(.eyeSharpen)
        eyeSize = amount(.eyeSize)
        noseSize = amount(.noseSize)
        noseTip = amount(.noseTip)
        lipSize = amount(.lipSize)
        cheekSize = amount(.cheekSize)
        jawWidth = amount(.jawWidth)
        chinLength = amount(.chinLength)
        faceWidth = amount(.faceWidth)
        faceLength = amount(.faceLength)
        exposure = amount(.exposure)
        contrast = amount(.contrast)
        blacks = amount(.blacks)
        whites = amount(.whites)
        saturation = amount(.saturation)
        vibrance = amount(.vibrance)
        warmth = amount(.warmth)
        clarity = amount(.clarity)
        vignette = amount(.vignette)
        lookID = text(.lookID)
        lookStrength = amount(.lookStrength)
        grain = amount(.grain)
        lipTint = amount(.lipTint)
        lipColor = color(.lipColor, legacy: .lipShadeID, fallback: MakeupShade.rose.color)
        blush = amount(.blush)
        blushColor = color(.blushColor, legacy: .blushShadeID, fallback: MakeupShade.cheekPeach.color)
        browDefine = amount(.browDefine)
        browColor = color(.browColor, fallback: MakeupShade.taupeBrow.color)
        eyeshadow = amount(.eyeshadow)
        shadowColor = color(.shadowColor, fallback: MakeupShade.taupeShadow.color)
        eyeliner = amount(.eyeliner)
        linerColor = color(.linerColor, fallback: MakeupShade.inkLiner.color)
        skinFinish = amount(.skinFinish)
        shine = amount(.shine)
        irisEnhance = amount(.irisEnhance)
        lashDarken = amount(.lashDarken)
        lipGloss = amount(.lipGloss)
        splitTone = amount(.splitTone)
        bodySmooth = amount(.bodySmooth)
        bodyTone = amount(.bodyTone)
        bodySlim = amount(.bodySlim)
        bodyWaist = amount(.bodyWaist)
        bodyArms = amount(.bodyArms)
        bodyLegs = amount(.bodyLegs)
        hairColor = amount(.hairColor)
        hairTint = color(.hairTint, fallback: MakeupShade.hairEspresso.color)
        hairShine = amount(.hairShine)
        contour = amount(.contour)
        contourColor = color(.contourColor, fallback: MakeupShade.contourSoft.color)
        curveShadows = amount(.curveShadows)
        curveMidtones = amount(.curveMidtones)
        curveHighlights = amount(.curveHighlights)
        hslHue = bands(.hslHue)
        hslSaturation = bands(.hslSaturation)
        hslLuminance = bands(.hslLuminance)
        backgroundBlur = amount(.backgroundBlur)
        backgroundTone = amount(.backgroundTone)
        backgroundSaturation = amount(.backgroundSaturation)
        lensTint = amount(.lensTint)
        lensColor = color(.lensColor, fallback: MakeupColor(hue: 210, saturation: 0.45, value: 0.48))
        teethAlign = amount(.teethAlign)
        hairVolume = amount(.hairVolume)
        backgroundFill = amount(.backgroundFill)
        backgroundFillColor = color(.backgroundFillColor,
                                    fallback: MakeupColor(hue: 0, saturation: 0, value: 0.96))
        backgroundRemove = flag(.backgroundRemove)
    }

    /// Written by hand because the legacy shade identifiers are decode-only:
    /// they have no stored property left to encode.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let amounts: [(CodingKeys, Double)] = [
            (.smooth, smooth), (.blemish, blemish), (.wrinkle, wrinkle),
            (.skinToneEvens, skinToneEvens), (.darkCircles, darkCircles),
            (.skinBrighten, skinBrighten), (.texturePreserve, texturePreserve),
            (.teethWhiten, teethWhiten), (.eyeBrighten, eyeBrighten),
            (.eyeSharpen, eyeSharpen),
            (.eyeSize, eyeSize), (.noseSize, noseSize), (.noseTip, noseTip),
            (.lipSize, lipSize), (.cheekSize, cheekSize), (.jawWidth, jawWidth),
            (.chinLength, chinLength), (.faceWidth, faceWidth), (.faceLength, faceLength),
            (.exposure, exposure), (.contrast, contrast), (.blacks, blacks),
            (.whites, whites), (.saturation, saturation), (.vibrance, vibrance),
            (.warmth, warmth), (.clarity, clarity), (.vignette, vignette),
            (.lookStrength, lookStrength), (.grain, grain),
            (.lipTint, lipTint), (.blush, blush), (.browDefine, browDefine),
            (.eyeshadow, eyeshadow), (.eyeliner, eyeliner), (.lipGloss, lipGloss),
            (.skinFinish, skinFinish), (.shine, shine),
            (.irisEnhance, irisEnhance), (.lashDarken, lashDarken),
            (.splitTone, splitTone),
            (.bodySmooth, bodySmooth), (.bodyTone, bodyTone), (.bodySlim, bodySlim),
            (.bodyWaist, bodyWaist), (.bodyArms, bodyArms), (.bodyLegs, bodyLegs),
            (.hairColor, hairColor), (.hairShine, hairShine),
            (.contour, contour),
            (.curveShadows, curveShadows), (.curveMidtones, curveMidtones),
            (.curveHighlights, curveHighlights),
            (.backgroundBlur, backgroundBlur), (.backgroundTone, backgroundTone),
            (.backgroundSaturation, backgroundSaturation),
            (.lensTint, lensTint), (.teethAlign, teethAlign), (.hairVolume, hairVolume),
            (.backgroundFill, backgroundFill),
        ]
        for (key, value) in amounts { try c.encode(value, forKey: key) }
        try c.encode(backgroundRemove, forKey: .backgroundRemove)
        try c.encode(lookID, forKey: .lookID)
        try c.encode(lipColor, forKey: .lipColor)
        try c.encode(blushColor, forKey: .blushColor)
        try c.encode(browColor, forKey: .browColor)
        try c.encode(shadowColor, forKey: .shadowColor)
        try c.encode(linerColor, forKey: .linerColor)
        try c.encode(hairTint, forKey: .hairTint)
        try c.encode(contourColor, forKey: .contourColor)
        try c.encode(lensColor, forKey: .lensColor)
        try c.encode(backgroundFillColor, forKey: .backgroundFillColor)
        try c.encode(hslHue, forKey: .hslHue)
        try c.encode(hslSaturation, forKey: .hslSaturation)
        try c.encode(hslLuminance, forKey: .hslLuminance)
    }
}

/// What a preset is for. The order of the cases is the order the sections
/// appear in the inspector.
enum PresetGroup: String, CaseIterable, Identifiable {
    case everyday, skin, beauty, color, film, makeup

    var id: String { rawValue }

    var title: String {
        L10n.current.presetGroupTitle(self)
    }
}

/// The identity of a built-in look. The raw values are what a project file
/// stores, so they never change; the name for each one lives in the string
/// table.
enum PresetID: String, CaseIterable {
    case natural, clean, fresh, minimal, softlight
    case airbrush, texture, matte, glow, eventone, bronze, porcelain
    case glamour, studio, editorial, beauty, bridal, sculpt, male
    case warmsun, cool, vibrant, muted, pastel, punchy, fade, noir, monosoft
    case golden, portra, cinema, faded, cross, kodachrome
    case rose, coral, berry, redcarpet, nude, brows
}

struct Preset: Identifiable, Equatable {
    let id: PresetID
    let group: PresetGroup
    let adjustments: Adjustments

    var title: String { L10n.current.presetTitle(id) }

    static func inGroup(_ group: PresetGroup) -> [Preset] { all.filter { $0.group == group } }
    static func with(id: String) -> Preset? {
        guard let id = PresetID(rawValue: id) else { return nil }
        return all.first { $0.id == id }
    }

    /// The library. Every entry is a starting point a photographer would
    /// actually reach for, and each one leaves at least one group alone so
    /// there is something left to adjust afterwards.
    ///
    /// Arguments follow the declaration order of `Adjustments`, which the
    /// memberwise initialiser keeps.
    static let all: [Preset] = [
        // MARK: Everyday — small, defensible corrections

        Preset(id: .natural, group: .everyday, adjustments: Adjustments(
            smooth: 22, blemish: 30, wrinkle: 18, skinToneEvens: 20,
            darkCircles: 16, texturePreserve: 78,
            teethWhiten: 12, eyeBrighten: 10, eyeSharpen: 14,
            exposure: 3, contrast: 5, vibrance: 8, warmth: 4, clarity: 6)),
        Preset(id: .clean, group: .everyday, adjustments: Adjustments(
            smooth: 16, blemish: 46, wrinkle: 12, skinToneEvens: 18,
            darkCircles: 24, texturePreserve: 86,
            teethWhiten: 16, eyeBrighten: 8,
            contrast: 6, blacks: 10, vibrance: 6, clarity: 8)),
        Preset(id: .fresh, group: .everyday, adjustments: Adjustments(
            smooth: 18, blemish: 24, skinToneEvens: 22, darkCircles: 34,
            skinBrighten: 14, texturePreserve: 82,
            teethWhiten: 20, eyeBrighten: 18, eyeSharpen: 16,
            exposure: 6, whites: 10, vibrance: 12, warmth: 5, clarity: 4)),
        Preset(id: .minimal, group: .everyday, adjustments: Adjustments(
            blemish: 38, wrinkle: 6, darkCircles: 22, texturePreserve: 100,
            eyeSharpen: 8, contrast: 2, vibrance: 2)),
        Preset(id: .softlight, group: .everyday, adjustments: Adjustments(
            smooth: 26, blemish: 18, skinToneEvens: 14, texturePreserve: 72,
            eyeBrighten: 8, exposure: 7, contrast: -6, whites: 14,
            saturation: -4, vibrance: 6, warmth: 6)),

        // MARK: Skin — what the smoothing itself should feel like

        Preset(id: .airbrush, group: .skin, adjustments: Adjustments(
            smooth: 62, blemish: 70, wrinkle: 52, skinToneEvens: 56,
            darkCircles: 44, skinBrighten: 18, texturePreserve: 38,
            teethWhiten: 30, eyeBrighten: 18,
            exposure: 3, contrast: 8, vibrance: 8, clarity: 6)),
        Preset(id: .texture, group: .skin, adjustments: Adjustments(
            smooth: 6, blemish: 26, wrinkle: 10, skinToneEvens: 10,
            texturePreserve: 100, eyeSharpen: 20,
            contrast: 10, blacks: 14, clarity: 22)),
        Preset(id: .matte, group: .skin, adjustments: Adjustments(
            smooth: 44, blemish: 40, skinToneEvens: 34,
            texturePreserve: 58, contrast: 12, blacks: 24, whites: -10,
            saturation: -6, vibrance: -4, clarity: 18)),
        Preset(id: .glow, group: .skin, adjustments: Adjustments(
            smooth: 34, blemish: 30, skinToneEvens: 28, darkCircles: 26,
            skinBrighten: 34, texturePreserve: 66,
            teethWhiten: 22, eyeBrighten: 20, eyeSharpen: 12,
            exposure: 5, whites: 18, vibrance: 10, warmth: 6)),
        Preset(id: .eventone, group: .skin, adjustments: Adjustments(
            smooth: 28, blemish: 44, skinToneEvens: 62, darkCircles: 46,
            skinBrighten: 12, texturePreserve: 70,
            contrast: 4, vibrance: 6, warmth: 3, clarity: 4)),
        Preset(id: .bronze, group: .skin, adjustments: Adjustments(
            smooth: 30, blemish: 26, skinToneEvens: 22, texturePreserve: 64,
            teethWhiten: 14, exposure: 2, contrast: 8, saturation: 6,
            vibrance: 10, warmth: 24, clarity: 10, vignette: 8)),
        Preset(id: .porcelain, group: .skin, adjustments: Adjustments(
            smooth: 54, blemish: 52, wrinkle: 40, skinToneEvens: 48,
            darkCircles: 38, skinBrighten: 30, texturePreserve: 48,
            teethWhiten: 26, eyeBrighten: 16,
            exposure: 8, contrast: 4, whites: 16, saturation: -6,
            vibrance: 4, warmth: -4)),

        // MARK: Beauty — full portraits, several groups at once

        Preset(id: .glamour, group: .beauty, adjustments: Adjustments(
            smooth: 42, blemish: 50, wrinkle: 34, skinToneEvens: 36,
            darkCircles: 30, texturePreserve: 62,
            teethWhiten: 34, eyeBrighten: 22, eyeSharpen: 28,
            eyeSize: 14, lipSize: 12, cheekSize: 8,
            exposure: 6, contrast: 10, vibrance: 14, warmth: 6, clarity: 10, vignette: 10,
            eyeshadow: 22, shadowColor: MakeupShade.champagneShadow.color,
            eyeliner: 14)),
        Preset(id: .studio, group: .beauty, adjustments: Adjustments(
            smooth: 55, blemish: 62, wrinkle: 44, skinToneEvens: 46,
            darkCircles: 38, texturePreserve: 52,
            teethWhiten: 44, eyeBrighten: 30, eyeSharpen: 38,
            eyeSize: 18, lipSize: 10, cheekSize: 14, jawWidth: -16, chinLength: 8,
            faceWidth: -8,
            exposure: 4, contrast: 16, vibrance: 10, warmth: 8, clarity: 16, vignette: 16)),
        Preset(id: .editorial, group: .beauty, adjustments: Adjustments(
            smooth: 12, blemish: 16, wrinkle: 24, skinToneEvens: 14,
            darkCircles: 20, texturePreserve: 92,
            teethWhiten: 6, eyeBrighten: 8, eyeSharpen: 26,
            cheekSize: -8, jawWidth: -20, chinLength: 10, faceWidth: -12,
            contrast: 20, blacks: 18, saturation: -10, vibrance: -4,
            warmth: -6, clarity: 24, vignette: 16)),
        Preset(id: .beauty, group: .beauty, adjustments: Adjustments(
            smooth: 38, blemish: 44, wrinkle: 26, skinToneEvens: 32,
            darkCircles: 30, skinBrighten: 16, texturePreserve: 66,
            teethWhiten: 28, eyeBrighten: 24, eyeSharpen: 24,
            eyeSize: 10, lipSize: 8,
            exposure: 4, contrast: 8, whites: 10, vibrance: 10, warmth: 4,
            clarity: 8, lipTint: 16, lipColor: MakeupShade.rose.color,
            eyeshadow: 14, shadowColor: MakeupShade.taupeShadow.color)),
        Preset(id: .bridal, group: .beauty, adjustments: Adjustments(
            smooth: 46, blemish: 48, wrinkle: 32, skinToneEvens: 40,
            darkCircles: 34, skinBrighten: 24, texturePreserve: 58,
            teethWhiten: 38, eyeBrighten: 20, eyeSharpen: 18,
            eyeSize: 8, cheekSize: 6,
            exposure: 7, contrast: 4, whites: 20, saturation: -4,
            vibrance: 8, warmth: 3, clarity: 6, vignette: 6,
            lipTint: 14, lipColor: MakeupShade.peach.color,
            blush: 16, blushColor: MakeupShade.cheekPeach.color)),
        Preset(id: .sculpt, group: .beauty, adjustments: Adjustments(
            smooth: 26, blemish: 30, skinToneEvens: 18, texturePreserve: 76,
            eyeSize: 8, cheekSize: -10, jawWidth: -18, chinLength: 6,
            faceWidth: -12, faceLength: 6,
            contrast: 14, blacks: 16, clarity: 20, vignette: 12)),
        Preset(id: .male, group: .beauty, adjustments: Adjustments(
            smooth: 14, blemish: 38, wrinkle: 10, skinToneEvens: 12,
            texturePreserve: 94, eyeBrighten: 8, eyeSharpen: 14,
            jawWidth: -8, chinLength: 6, faceWidth: -6,
            contrast: 14, blacks: 18, saturation: -6, warmth: -4, clarity: 18)),

        // MARK: Colour — the whole frame, no skin work

        Preset(id: .warmsun, group: .color, adjustments: Adjustments(
            exposure: 4, contrast: 6, whites: 10, vibrance: 12,
            warmth: 24, clarity: 4)),
        Preset(id: .cool, group: .color, adjustments: Adjustments(
            exposure: 2, contrast: 8, blacks: 10, saturation: -4,
            warmth: -22, clarity: 6)),
        Preset(id: .vibrant, group: .color, adjustments: Adjustments(
            exposure: 2, contrast: 12, blacks: 12, whites: 12,
            saturation: 8, vibrance: 24, clarity: 8)),
        Preset(id: .muted, group: .color, adjustments: Adjustments(
            contrast: 4, blacks: 12, saturation: -18, vibrance: -8,
            warmth: -3, clarity: 6)),
        Preset(id: .pastel, group: .color, adjustments: Adjustments(
            exposure: 9, contrast: -8, whites: 16, saturation: -12,
            vibrance: 4, warmth: 4)),
        Preset(id: .punchy, group: .color, adjustments: Adjustments(
            contrast: 26, blacks: 24, whites: 20, saturation: 4,
            vibrance: 12, clarity: 16)),
        Preset(id: .fade, group: .color, adjustments: Adjustments(
            exposure: 5, contrast: -12, blacks: -34, whites: -14,
            saturation: -8, vibrance: -4, warmth: 6)),
        Preset(id: .noir, group: .color, adjustments: Adjustments(
            exposure: -4, contrast: 30, blacks: 26, saturation: -100,
            clarity: 22, vignette: 26)),
        Preset(id: .monosoft, group: .color, adjustments: Adjustments(
            exposure: 5, contrast: 8, blacks: -16, whites: 10,
            saturation: -100, clarity: 6, grain: 26)),

        // MARK: Film — grade and grain, lightly supported by skin work

        Preset(id: .golden, group: .film, adjustments: Adjustments(
            smooth: 18, blemish: 20, skinBrighten: 10, texturePreserve: 80,
            exposure: 4, contrast: 6, whites: 12, vibrance: 10, warmth: 16,
            lookID: FilmLook.warmGold.rawValue, lookStrength: 55, grain: 10)),
        Preset(id: .portra, group: .film, adjustments: Adjustments(
            smooth: 22, blemish: 24, skinToneEvens: 16, texturePreserve: 84,
            exposure: 3, contrast: 4, whites: 8, saturation: -4, warmth: 6,
            lookID: FilmLook.portraitFilm.rawValue, lookStrength: 62, grain: 18)),
        Preset(id: .cinema, group: .film, adjustments: Adjustments(
            smooth: 16, blemish: 18, texturePreserve: 86, eyeSharpen: 12,
            contrast: 14, blacks: 16, warmth: -8, clarity: 8, vignette: 18,
            lookID: FilmLook.nightStock.rawValue, lookStrength: 45, grain: 14)),
        Preset(id: .faded, group: .film, adjustments: Adjustments(
            smooth: 14, texturePreserve: 88, exposure: 4, contrast: -6,
            blacks: -28, saturation: -6, warmth: 4,
            lookID: FilmLook.fadedMatte.rawValue, lookStrength: 65, grain: 22)),
        Preset(id: .cross, group: .film, adjustments: Adjustments(
            smooth: 10, texturePreserve: 90, contrast: 18, blacks: 14,
            saturation: 6, clarity: 10,
            lookID: FilmLook.crossProcess.rawValue, lookStrength: 45, grain: 12)),
        Preset(id: .kodachrome, group: .film, adjustments: Adjustments(
            smooth: 12, texturePreserve: 86, exposure: 2, contrast: 16,
            blacks: 18, saturation: 10, vibrance: 8, warmth: 10, clarity: 10,
            lookID: FilmLook.warmGold.rawValue, lookStrength: 38, grain: 20)),

        // MARK: Makeup — cosmetics, with the skin work kept minimal

        Preset(id: .rose, group: .makeup, adjustments: Adjustments(
            smooth: 20, blemish: 22, skinToneEvens: 16, skinBrighten: 12,
            texturePreserve: 78, eyeBrighten: 10, eyeSharpen: 12,
            contrast: 4, vibrance: 6, warmth: 8,
            lipTint: 48, lipColor: MakeupShade.rose.color,
            blush: 30, blushColor: MakeupShade.cheekRoseLight.color)),
        Preset(id: .coral, group: .makeup, adjustments: Adjustments(
            smooth: 18, blemish: 24, skinToneEvens: 18, skinBrighten: 14,
            texturePreserve: 74, teethWhiten: 22, eyeBrighten: 12,
            exposure: 3, vibrance: 12, warmth: 10,
            lipTint: 54, lipColor: MakeupShade.coral.color,
            blush: 34, blushColor: MakeupShade.cheekCoral.color)),
        Preset(id: .berry, group: .makeup, adjustments: Adjustments(
            smooth: 24, blemish: 28, skinToneEvens: 20, texturePreserve: 74,
            teethWhiten: 26, eyeBrighten: 12, eyeSharpen: 10,
            contrast: 8, blacks: 10, saturation: 4,
            lipTint: 38, lipColor: MakeupShade.berry.color,
            blush: 14, blushColor: MakeupShade.cheekBerry.color)),
        Preset(id: .redcarpet, group: .makeup, adjustments: Adjustments(
            smooth: 40, blemish: 46, wrinkle: 28, skinToneEvens: 38,
            darkCircles: 28, texturePreserve: 60,
            teethWhiten: 42, eyeBrighten: 22, eyeSharpen: 24, eyeSize: 10,
            contrast: 12, blacks: 14, saturation: 6, vibrance: 8, warmth: 4,
            clarity: 8, vignette: 12,
            lipTint: 48, lipColor: MakeupShade.berry.color,
            blush: 12, blushColor: MakeupShade.cheekRoseLight.color, browDefine: 18,
            eyeshadow: 26, shadowColor: MakeupShade.plumShadow.color,
            eyeliner: 22, linerColor: MakeupShade.inkLiner.color)),
        Preset(id: .nude, group: .makeup, adjustments: Adjustments(
            smooth: 12, blemish: 34, wrinkle: 8, skinToneEvens: 12,
            darkCircles: 26, texturePreserve: 94,
            teethWhiten: 16, eyeBrighten: 14, eyeSharpen: 18,
            exposure: 4, vibrance: 8, warmth: 4,
            lipTint: 26, lipColor: MakeupShade.peach.color,
            blush: 18, blushColor: MakeupShade.cheekPeach.color, browDefine: 28)),
        Preset(id: .brows, group: .makeup, adjustments: Adjustments(
            smooth: 18, blemish: 24, skinToneEvens: 14, texturePreserve: 84,
            eyeBrighten: 14, eyeSharpen: 22, contrast: 8, clarity: 10,
            lipTint: 8, lipColor: MakeupShade.peach.color, browDefine: 42)),
    ]
}

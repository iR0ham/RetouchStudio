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
public struct Adjustments: Equatable, Codable {

    // MARK: - Skin (retouch)
    public var smooth: Double = 0            // overall smoothing amount
    public var blemish: Double = 0           // acne / spots
    public var wrinkle: Double = 0           // fine lines
    public var skinToneEvens: Double = 0     // skin tone correction / evening
    public var darkCircles: Double = 0       // under-eye correction
    public var skinBrighten: Double = 0      // brightness
    public var texturePreserve: Double = 0   // 0 = plain blur, 100 = keep maximum texture
    public var teethWhiten: Double = 0
    public var eyeBrighten: Double = 0
    public var eyeSharpen: Double = 0

    // MARK: - Reshape (geometry)
    public var eyeSize: Double = 0
    public var noseSize: Double = 0
    public var noseTip: Double = 0
    public var lipSize: Double = 0
    public var cheekSize: Double = 0
    public var jawWidth: Double = 0
    public var chinLength: Double = 0
    public var faceWidth: Double = 0
    public var faceLength: Double = 0

    // MARK: - Color and light (global)
    public var exposure: Double = 0
    public var contrast: Double = 0
    /// Input level mapped to black. Positive digs the shadows out — the cure
    /// for a faded frame — and negative lets them glow.
    public var blacks: Double = 0
    /// Input level mapped to white. Positive lifts the highlights.
    public var whites: Double = 0
    public var saturation: Double = 0
    public var vibrance: Double = 0
    public var warmth: Double = 0
    public var clarity: Double = 0
    public var vignette: Double = 0

    // MARK: - Look (film grade and grain)
    //
    // `lookID` is the raw value of a `FilmLook`; an empty string means no look
    // is applied, so a fresh `Adjustments()` is still a genuine no-op.
    public var lookID: String = ""
    public var lookStrength: Double = 0    // 0...100, how far the grade is blended in
    public var grain: Double = 0           // 0...100

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
    public var blackLevel: Double { 0.30 * blacks / 100 }
    public var whiteLevel: Double { 1 - 0.30 * whites / 100 }

    // MARK: - Makeup (colour cosmetics)
    //
    // Every region owns its colour and its amount, so a lip and a cheek can be
    // different colours and the two eye tools get their own. The colours are
    // full HSV values rather than palette identifiers: the picker and the hue /
    // saturation sliders edit them directly, and a project saved by the older,
    // palette-only build is migrated from its shade identifier on decode.
    public var lipTint: Double = 0
    public var lipColor: MakeupColor = MakeupShade.rose.color
    public var blush: Double = 0
    public var blushColor: MakeupColor = MakeupShade.cheekPeach.color
    public var browDefine: Double = 0
    public var browColor: MakeupColor = MakeupShade.taupeBrow.color
    public var eyeshadow: Double = 0
    public var shadowColor: MakeupColor = MakeupShade.taupeShadow.color
    public var eyeliner: Double = 0
    public var linerColor: MakeupColor = MakeupShade.inkLiner.color

    // MARK: - Skin finish and detail
    //
    // Kept apart from the smoothing group: these decide how the finished skin
    // *reads* — matte or dewy, shiny or calm — and how much structure the eye
    // and lash keep. All are appended after the original fields so a project
    // written before they existed decodes to "no change".
    public var skinFinish: Double = 0      // -100 matte ... +100 glow
    public var shine: Double = 0           // 0...100, calms specular on the skin
    public var irisEnhance: Double = 0     // 0...100, local contrast inside the iris
    public var lashDarken: Double = 0      // 0...100
    public var lipGloss: Double = 0        // 0...100
    public var splitTone: Double = 0       // 0...100, cool shadows / warm highlights

    // MARK: - Body and background
    //
    // These run from the on-device person mask rather than from face landmarks,
    // so they work on a full-length portrait where the face is only a small
    // part of the frame.
    public var bodySmooth: Double = 0          // 0...100
    public var bodyTone: Double = 0            // -100...100
    public var bodySlim: Double = 0            // -100...100, positive narrows
    public var backgroundBlur: Double = 0      // 0...100
    public var backgroundTone: Double = 0      // -100...100
    public var backgroundSaturation: Double = 0 // -100...100

    // MARK: - Pose-driven body shaping
    //
    // Appended after the silhouette controls so a project written before the
    // pose joints existed still decodes to "no change". Positive narrows, the
    // same direction as Body Slim.
    public var bodyWaist: Double = 0           // -100...100
    public var bodyArms: Double = 0            // -100...100
    public var bodyLegs: Double = 0            // -100...100

    // MARK: - Hair
    //
    // Hair is makeup in the cosmetic sense — a pigment over its own shading —
    // but it is driven by the head band rather than a face landmark.
    public var hairColor: Double = 0           // 0...100
    public var hairTint: MakeupColor = MakeupShade.hairEspresso.color
    public var hairShine: Double = 0           // 0...100

    // MARK: - Contour
    //
    // Sculpting shade under the cheekbone and along the jaw. It lives with the
    // cosmetics because it is the same operation: a colour laid over shading.
    public var contour: Double = 0             // 0...100
    public var contourColor: MakeupColor = MakeupShade.contourSoft.color

    // MARK: - Tone curve
    //
    // Three anchors rather than an editable spline. A curve is judged at the
    // shadows, the mid-tones and the highlights; the engine interpolates
    // smoothly between them on luminance, so colour is untouched.
    public var curveShadows: Double = 0        // -100...100
    public var curveMidtones: Double = 0       // -100...100
    public var curveHighlights: Double = 0     // -100...100

    // MARK: - HSL
    //
    // Per-hue-band adjustment, indexed by `HSLBand`. Arrays rather than 24
    // stored properties: the bands are a fixed list, and the sliders edit one
    // component of one band at a time.
    public var hslHue: [Double] = Array(repeating: 0, count: HSLBand.allCases.count)
    public var hslSaturation: [Double] = Array(repeating: 0, count: HSLBand.allCases.count)
    public var hslLuminance: [Double] = Array(repeating: 0, count: HSLBand.allCases.count)

    // MARK: - Iris colour and teeth alignment
    //
    // A contact lens is a pigment on the iris that keeps its striations, which
    // is the same operation as lipstick on a lip — so it rides the same
    // luminance-preserving tint and stays in the retouch group.
    public var lensTint: Double = 0            // 0...100
    public var lensColor: MakeupColor = MakeupColor(hue: 210, saturation: 0.45, value: 0.48)
    /// Closes the dark gaps between teeth by borrowing the enamel around them,
    /// so a spaced or uneven smile reads straighter without warping the jaw.
    public var teethAlign: Double = 0          // 0...100

    // MARK: - Hair volume
    //
    // A radial bulge confined to the hair band. It is a makeup-group tool
    // because it changes how the hair reads rather than the face's geometry.
    public var hairVolume: Double = 0          // 0...100

    // MARK: - Background replacement
    //
    // Fill puts a solid colour behind the subject; removal makes the background
    // transparent so an export can be dropped onto another backdrop. Both read
    // the same feathered person mask as blur/tone/saturation.
    public var backgroundFill: Double = 0      // 0...100
    public var backgroundFillColor: MakeupColor = MakeupColor(hue: 0, saturation: 0, value: 0.96)
    public var backgroundRemove: Bool = false
    /// A stored backdrop image, drawn behind the subject when set. The file
    /// name lives in `BackdropStore`; the original name is only for the UI.
    public var backgroundImage: String = ""
    public var backgroundImageName: String = ""
    public var backgroundImageAmount: Double = 100 // 0...100

    public init(
        smooth: Double = 0, blemish: Double = 0, wrinkle: Double = 0,
        skinToneEvens: Double = 0, darkCircles: Double = 0,
        skinBrighten: Double = 0, texturePreserve: Double = 0,
        teethWhiten: Double = 0, eyeBrighten: Double = 0, eyeSharpen: Double = 0,
        eyeSize: Double = 0, noseSize: Double = 0, noseTip: Double = 0,
        lipSize: Double = 0, cheekSize: Double = 0, jawWidth: Double = 0,
        chinLength: Double = 0, faceWidth: Double = 0, faceLength: Double = 0,
        exposure: Double = 0, contrast: Double = 0, blacks: Double = 0,
        whites: Double = 0, saturation: Double = 0, vibrance: Double = 0,
        warmth: Double = 0, clarity: Double = 0, vignette: Double = 0,
        lookID: String = "", lookStrength: Double = 0, grain: Double = 0,
        lipTint: Double = 0, lipColor: MakeupColor = MakeupShade.rose.color,
        blush: Double = 0, blushColor: MakeupColor = MakeupShade.cheekPeach.color,
        browDefine: Double = 0, browColor: MakeupColor = MakeupShade.taupeBrow.color,
        eyeshadow: Double = 0, shadowColor: MakeupColor = MakeupShade.taupeShadow.color,
        eyeliner: Double = 0, linerColor: MakeupColor = MakeupShade.inkLiner.color,
        skinFinish: Double = 0, shine: Double = 0, irisEnhance: Double = 0,
        lashDarken: Double = 0, lipGloss: Double = 0, splitTone: Double = 0,
        bodySmooth: Double = 0, bodyTone: Double = 0, bodySlim: Double = 0,
        backgroundBlur: Double = 0, backgroundTone: Double = 0,
        backgroundSaturation: Double = 0,
        bodyWaist: Double = 0, bodyArms: Double = 0, bodyLegs: Double = 0,
        hairColor: Double = 0, hairTint: MakeupColor = MakeupShade.hairEspresso.color,
        hairShine: Double = 0,
        contour: Double = 0, contourColor: MakeupColor = MakeupShade.contourSoft.color,
        curveShadows: Double = 0, curveMidtones: Double = 0,
        curveHighlights: Double = 0,
        hslHue: [Double] = Array(repeating: 0, count: HSLBand.allCases.count),
        hslSaturation: [Double] = Array(repeating: 0, count: HSLBand.allCases.count),
        hslLuminance: [Double] = Array(repeating: 0, count: HSLBand.allCases.count),
        lensTint: Double = 0,
        lensColor: MakeupColor = MakeupColor(hue: 210, saturation: 0.45, value: 0.48),
        teethAlign: Double = 0, hairVolume: Double = 0,
        backgroundFill: Double = 0,
        backgroundFillColor: MakeupColor = MakeupColor(hue: 0, saturation: 0, value: 0.96),
        backgroundRemove: Bool = false,
        backgroundImage: String = "", backgroundImageName: String = "",
        backgroundImageAmount: Double = 100
    ) {
        self.smooth = smooth
        self.blemish = blemish
        self.wrinkle = wrinkle
        self.skinToneEvens = skinToneEvens
        self.darkCircles = darkCircles
        self.skinBrighten = skinBrighten
        self.texturePreserve = texturePreserve
        self.teethWhiten = teethWhiten
        self.eyeBrighten = eyeBrighten
        self.eyeSharpen = eyeSharpen
        self.eyeSize = eyeSize
        self.noseSize = noseSize
        self.noseTip = noseTip
        self.lipSize = lipSize
        self.cheekSize = cheekSize
        self.jawWidth = jawWidth
        self.chinLength = chinLength
        self.faceWidth = faceWidth
        self.faceLength = faceLength
        self.exposure = exposure
        self.contrast = contrast
        self.blacks = blacks
        self.whites = whites
        self.saturation = saturation
        self.vibrance = vibrance
        self.warmth = warmth
        self.clarity = clarity
        self.vignette = vignette
        self.lookID = lookID
        self.lookStrength = lookStrength
        self.grain = grain
        self.lipTint = lipTint
        self.lipColor = lipColor
        self.blush = blush
        self.blushColor = blushColor
        self.browDefine = browDefine
        self.browColor = browColor
        self.eyeshadow = eyeshadow
        self.shadowColor = shadowColor
        self.eyeliner = eyeliner
        self.linerColor = linerColor
        self.skinFinish = skinFinish
        self.shine = shine
        self.irisEnhance = irisEnhance
        self.lashDarken = lashDarken
        self.lipGloss = lipGloss
        self.splitTone = splitTone
        self.bodySmooth = bodySmooth
        self.bodyTone = bodyTone
        self.bodySlim = bodySlim
        self.backgroundBlur = backgroundBlur
        self.backgroundTone = backgroundTone
        self.backgroundSaturation = backgroundSaturation
        self.bodyWaist = bodyWaist
        self.bodyArms = bodyArms
        self.bodyLegs = bodyLegs
        self.hairColor = hairColor
        self.hairTint = hairTint
        self.hairShine = hairShine
        self.contour = contour
        self.contourColor = contourColor
        self.curveShadows = curveShadows
        self.curveMidtones = curveMidtones
        self.curveHighlights = curveHighlights
        self.hslHue = hslHue
        self.hslSaturation = hslSaturation
        self.hslLuminance = hslLuminance
        self.lensTint = lensTint
        self.lensColor = lensColor
        self.teethAlign = teethAlign
        self.hairVolume = hairVolume
        self.backgroundFill = backgroundFill
        self.backgroundFillColor = backgroundFillColor
        self.backgroundRemove = backgroundRemove
        self.backgroundImage = backgroundImage
        self.backgroundImageName = backgroundImageName
        self.backgroundImageAmount = backgroundImageAmount
    }

    public static let zero = Adjustments()

    public var isIdentity: Bool { self == .zero }

    // MARK: - Field sets

    /// Which retouch sliders a patch is allowed to overwrite. A zero in a
    /// measured field is a real answer ("nothing to correct"); a field that was
    /// never measured is the owner's and must not be cleared by accident.
    public struct RetouchField: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let smooth = RetouchField(rawValue: 1 << 0)
        public static let blemish = RetouchField(rawValue: 1 << 1)
        public static let wrinkle = RetouchField(rawValue: 1 << 2)
        public static let skinToneEvens = RetouchField(rawValue: 1 << 3)
        public static let darkCircles = RetouchField(rawValue: 1 << 4)
        public static let skinBrighten = RetouchField(rawValue: 1 << 5)
        public static let texturePreserve = RetouchField(rawValue: 1 << 6)
        public static let teethWhiten = RetouchField(rawValue: 1 << 7)
        public static let eyeBrighten = RetouchField(rawValue: 1 << 8)
        public static let eyeSharpen = RetouchField(rawValue: 1 << 9)
        public static let skinFinish = RetouchField(rawValue: 1 << 10)
        public static let shine = RetouchField(rawValue: 1 << 11)
        public static let irisEnhance = RetouchField(rawValue: 1 << 12)
        public static let lashDarken = RetouchField(rawValue: 1 << 13)
        public static let lensTint = RetouchField(rawValue: 1 << 14)
        public static let lensColor = RetouchField(rawValue: 1 << 15)
        public static let teethAlign = RetouchField(rawValue: 1 << 16)

        public static let all: RetouchField = [
            .smooth, .blemish, .wrinkle, .skinToneEvens, .darkCircles,
            .skinBrighten, .texturePreserve, .teethWhiten, .eyeBrighten,
            .eyeSharpen, .skinFinish, .shine, .irisEnhance, .lashDarken,
            .lensTint, .lensColor, .teethAlign,
        ]

        /// Exactly what `SmartAnalyzer.retouchValues` writes. Keep this next to
        /// that function's assignments; the coverage test fails if they drift.
        public static let smart: RetouchField = [
            .smooth, .blemish, .wrinkle, .skinToneEvens, .darkCircles,
            .skinBrighten, .texturePreserve, .shine, .teethWhiten,
            .eyeBrighten, .eyeSharpen,
        ]
    }

    /// The same contract for global colour and light.
    public struct ColorField: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let exposure = ColorField(rawValue: 1 << 0)
        public static let contrast = ColorField(rawValue: 1 << 1)
        public static let blacks = ColorField(rawValue: 1 << 2)
        public static let whites = ColorField(rawValue: 1 << 3)
        public static let saturation = ColorField(rawValue: 1 << 4)
        public static let vibrance = ColorField(rawValue: 1 << 5)
        public static let warmth = ColorField(rawValue: 1 << 6)
        public static let clarity = ColorField(rawValue: 1 << 7)
        public static let vignette = ColorField(rawValue: 1 << 8)
        public static let splitTone = ColorField(rawValue: 1 << 9)
        public static let curveShadows = ColorField(rawValue: 1 << 10)
        public static let curveMidtones = ColorField(rawValue: 1 << 11)
        public static let curveHighlights = ColorField(rawValue: 1 << 12)
        public static let hslHue = ColorField(rawValue: 1 << 13)
        public static let hslSaturation = ColorField(rawValue: 1 << 14)
        public static let hslLuminance = ColorField(rawValue: 1 << 15)

        public static let all: ColorField = [
            .exposure, .contrast, .blacks, .whites, .saturation, .vibrance,
            .warmth, .clarity, .vignette, .splitTone, .curveShadows,
            .curveMidtones, .curveHighlights, .hslHue, .hslSaturation,
            .hslLuminance,
        ]

        /// What `AutoAnalyzer.autoColorLight` can assign. Vignette, split tone,
        /// curves and HSL are taste or never measured, so they stay untouched.
        public static let autoColorLight: ColorField = [
            .exposure, .contrast, .blacks, .whites, .saturation, .vibrance,
            .warmth, .clarity,
        ]
    }

    // MARK: - Group views

    /// The retouch half, with geometry and color/light zeroed.
    public var retouchOnly: Adjustments {
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
    public var reshapeOnly: Adjustments {
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
    public var colorLightOnly: Adjustments {
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
    public var usesFaceTools: Bool { retouchOnly != .zero || reshapeOnly != .zero || makeupOnly != .zero }

    public var hasReshape: Bool { reshapeOnly != .zero }

    /// The look half: grade and grain, with everything else zeroed.
    public var lookOnly: Adjustments {
        var a = Adjustments()
        a.lookID = lookID
        a.lookStrength = lookStrength
        a.grain = grain
        return a
    }

    public var hasLook: Bool { lookOnly != .zero }

    /// The makeup half: lips, cheeks, brows and the two eye pigments.
    public var makeupOnly: Adjustments {
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
    public var bodyOnly: Adjustments {
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
    public var backgroundOnly: Adjustments {
        var a = Adjustments()
        a.backgroundBlur = backgroundBlur
        a.backgroundTone = backgroundTone
        a.backgroundSaturation = backgroundSaturation
        a.backgroundFill = backgroundFill
        a.backgroundFillColor = backgroundFillColor
        a.backgroundRemove = backgroundRemove
        a.backgroundImage = backgroundImage
        a.backgroundImageName = backgroundImageName
        a.backgroundImageAmount = backgroundImageAmount
        return a
    }

    /// True when a control needs the person mask, so the mask is only built
    /// when one of these tools is actually in use. Hair needs it too: the head
    /// band would otherwise tint a wall behind the subject.
    public var usesPersonTools: Bool {
        bodyOnly != .zero || backgroundOnly != .zero
            || hairColor != 0 || hairShine != 0 || hairVolume != 0
    }

    public var hasMakeup: Bool { makeupOnly != .zero }

    // MARK: - Composing groups (keeps the Auto actions independent)

    /// Copy with ONLY the makeup fields taken from `patch`.
    public func applyingMakeup(_ patch: Adjustments) -> Adjustments {
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
    public func applyingLook(_ patch: Adjustments) -> Adjustments {
        var result = self
        result.lookID = patch.lookID
        result.lookStrength = patch.lookStrength
        result.grain = patch.grain
        return result
    }

    /// Copy with ONLY the color/light fields in `fields` taken from `patch`.
    public func applyingColorLight(_ patch: Adjustments,
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
    public func applyingRetouch(_ patch: Adjustments,
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
    public func scaledRetouch(by percent: Double) -> Adjustments {
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
    public func scaledColorLight(by percent: Double) -> Adjustments {
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
    public func applyingReshape(_ patch: Adjustments) -> Adjustments {
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
    public func applyingBody(_ patch: Adjustments) -> Adjustments {
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
    public func applyingBackground(_ patch: Adjustments) -> Adjustments {
        var result = self
        result.backgroundBlur = patch.backgroundBlur
        result.backgroundTone = patch.backgroundTone
        result.backgroundSaturation = patch.backgroundSaturation
        result.backgroundFill = patch.backgroundFill
        result.backgroundFillColor = patch.backgroundFillColor
        result.backgroundRemove = patch.backgroundRemove
        result.backgroundImage = patch.backgroundImage
        result.backgroundImageName = patch.backgroundImageName
        result.backgroundImageAmount = patch.backgroundImageAmount
        return result
    }
}

/// The eight hue bands the HSL tool edits. Centres are degrees on the colour
/// wheel; the half-width is how far the band reaches before its neighbour takes
/// over, chosen so reds and skin stay narrow while greens get room.
public enum HSLBand: Int, CaseIterable, Identifiable, Codable {
    case red, orange, yellow, green, cyan, blue, purple, magenta

    public var id: Int { rawValue }

    /// Centre of the band in degrees.
    public var centerHue: Double {
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
    public var halfWidth: Double {
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
    public var sampleColor: (r: Double, g: Double, b: Double) {
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
public enum AdjustmentGroup: String, CaseIterable, Identifiable {
    case skin, reshape, makeup, colorLight, look, body, background
    public var id: String { rawValue }
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
        case backgroundImage, backgroundImageName, backgroundImageAmount
        // Written by the palette-only builds; read to migrate old projects.
        case lipShadeID, blushShadeID
    }

    public init(from decoder: Decoder) throws {
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
        backgroundImage = text(.backgroundImage)
        backgroundImageName = text(.backgroundImageName)
        backgroundImageAmount = amount(.backgroundImageAmount)
    }

    /// Written by hand because the legacy shade identifiers are decode-only:
    /// they have no stored property left to encode.
    public func encode(to encoder: Encoder) throws {
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
        try c.encode(backgroundImage, forKey: .backgroundImage)
        try c.encode(backgroundImageName, forKey: .backgroundImageName)
        try c.encode(backgroundImageAmount, forKey: .backgroundImageAmount)
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

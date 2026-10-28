import AppKit
import CoreGraphics
import CoreImage
import Foundation

/// تست خودکار موتور پردازش. با سوئیچ --selftest اجرا می‌شود و رابط کاربری بالا نمی‌آید.
///
/// نمونه:
///   .build/release/RetouchStudio --selftest --face /path/to/portrait.jpg --out /tmp/rt
enum SelfCheck {

    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard arguments.contains("--selftest") else { return }

        var facePath: String?
        if let index = arguments.firstIndex(of: "--face"), index + 1 < arguments.count {
            facePath = arguments[index + 1]
        }
        var outDirectory = NSTemporaryDirectory()
        if let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count {
            outDirectory = arguments[index + 1]
        }

        let passed = run(facePath: facePath, outDirectory: outDirectory)
        print(passed ? "SELFTEST: PASS" : "SELFTEST: FAIL")
        exit(passed ? 0 : 1)
    }

    static func run(facePath: String?, outDirectory: String) -> Bool {
        var passed = true
        print("-- mask orientation --")
        passed = checkMaskOrientation() && passed
        print("-- masked pipeline --")
        passed = checkMaskedPipeline() && passed
        print("-- skin smoothing preserves eye/lip detail --")
        passed = checkSmoothPreservesFeatures() && passed
        print("-- eye shield holds at portrait scale --")
        passed = checkEyeShieldAtRealScale() && passed
        print("-- full chain on a synthetic portrait --")
        passed = checkSyntheticPortrait(outDirectory: outDirectory) && passed
        print("-- auto color/light vs auto retouch separation --")
        passed = checkAutoSeparation() && passed
        print("-- auto color/light reads the tonal range --")
        passed = checkAutoColorLevels() && passed
        print("-- mask convention (opaque grayscale) --")
        passed = checkMaskConvention() && passed
        print("-- blemish gate separates skin from spots --")
        passed = checkBlemishGate() && passed
        print("-- teeth whitening only when teeth are visible --")
        passed = checkTeethGating() && passed
        print("-- frequency separation reconstructs exactly --")
        passed = checkFrequencySeparation() && passed
        print("-- healing keeps texture while clearing spots --")
        passed = checkHealing() && passed
        print("-- enamel and eye pixel gates --")
        passed = checkEyeAndEnamelGates() && passed
        print("-- pixel gates compare sRGB values --")
        passed = checkColorGateSpace() && passed
        print("-- 16-bit export and metadata --")
        passed = checkExportDepthAndMetadata(outDirectory: outDirectory) && passed
        print("-- undo and redo history --")
        passed = checkUndoHistory() && passed
        print("-- crop geometry, orientation and project round-trip --")
        passed = checkCropGeometry() && passed
        passed = checkCropLoad(outDirectory: outDirectory) && passed
        passed = checkProjectRoundTrip() && passed
        passed = checkCropProjectFlow(outDirectory: outDirectory) && passed
        print("-- manual healing brush --")
        passed = checkManualHealing() && passed
        print("-- looks: colour cube and grain --")
        passed = checkLooksAndGrain() && passed
        print("-- makeup: lips, cheeks and brows --")
        passed = checkMakeup() && passed
        print("-- preset library --")
        passed = checkPresetLibrary() && passed
        if let facePath {
            print("-- real photo --")
            passed = checkRealFace(path: facePath, outDirectory: outDirectory) && passed
            print("-- auto retouch affects only the face --")
            passed = checkAutoRetouchIsFaceLocal(path: facePath) && passed
        }
        return passed
    }

    // MARK: - ۱) جهت ماسک

    private static func checkMaskOrientation() -> Bool {
        let size = 400
        let extent = CGRect(x: 0, y: 0, width: size, height: size)
        // این مستطیل در مختصات پردازشی (مبدأ پایین-چپ) بالای تصویر است.
        let shape = MaskShape(rect: CGRect(x: 0.1, y: 0.75, width: 0.8, height: 0.2))
        guard let mask = MaskBuilder.makeMask(extent: extent, shapes: [shape], feather: 4) else {
            print("  ✗ could not build mask")
            return false
        }
        guard let maskImage = ImageProcessor.shared.renderCGImage(mask, scale: 1),
              let top = luminance(maskImage, x: 200, y: 60),
              let bottom = luminance(maskImage, x: 200, y: 340) else {
            print("  ✗ could not render mask")
            return false
        }
        let ok = top > 200 && bottom < 30
        print("  \(ok ? "✓" : "✗") top=\(top) bottom=\(bottom) (expect bright top, dark bottom)")
        return ok
    }

    // MARK: - ۲) ماسک واقعاً کجا اثر می‌گذارد

    private static func checkMaskedPipeline() -> Bool {
        let size = 400
        // The fixture must contain a feature the engine is actually designed to
        // change. Smoothing and blemish removal deliberately preserve detail
        // larger than their kernel, so a 20px block at the face centre is NOT
        // expected to move — using one here previously made this check fail for
        // the wrong reason. Fine grain plus a small spot is the honest target.
        guard let base = makeTexturedSpotImage(size: size,
                                               spotCenter: CGPoint(x: 200, y: 200),
                                               spotDiameter: 9) else {
            print("  ✗ could not build test image")
            return false
        }
        let extent = CGRect(x: 0, y: 0, width: size, height: size)

        let face = FaceGeometry.synthetic(
            boundingBox: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            faceContour: [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.25),
                          CGPoint(x: 0.75, y: 0.75), CGPoint(x: 0.25, y: 0.75)],
            leftEye: [], rightEye: [], leftEyebrow: [], rightEyebrow: [], outerLips: [], innerLips: [], nose: [])

        let processor = ImageProcessor.shared
        guard let masks = processor.buildMasks(extent: extent, faces: [face]),
              let faceMask = masks.face,
              let maskImage = processor.renderCGImage(faceMask, scale: 1),
              let maskInside = luminance(maskImage, x: 200, y: 200),
              let maskOutside = luminance(maskImage, x: 6, y: 6) else {
            print("  ✗ could not build face mask")
            return false
        }

        var adjustments = Adjustments()
        adjustments.smooth = 100
        adjustments.blemish = 100

        let output = processor.process(CIImage(cgImage: base), adjustments: adjustments,
                                       masks: masks, faces: [face])
        guard let rendered = processor.renderCGImage(output, scale: 1),
              let beforeCenter = luminance(base, x: 200, y: 200),
              let afterCenter = luminance(rendered, x: 200, y: 200),
              let beforeCorner = luminance(base, x: 6, y: 6),
              let afterCorner = luminance(rendered, x: 6, y: 6) else {
            print("  ✗ processing failed")
            return false
        }

        // Measure grain inside the face, sampled away from the mask edge so the
        // feather cannot be blamed for a change.
        let skinRect = CGRect(x: 120, y: 220, width: 40, height: 40)
        let grainBefore = roughness(base, rect: skinRect) ?? 0
        let grainAfter = roughness(rendered, rect: skinRect) ?? 0
        let grainReduced = grainBefore > 0 && grainAfter < grainBefore * 0.85

        let maskOK = maskInside > 200 && maskOutside < 30
        let changed = abs(afterCenter - beforeCenter) > 4 || grainReduced
        let untouched = abs(afterCorner - beforeCorner) <= 1
        print("  \(maskOK ? "✓" : "✗") mask: inside=\(maskInside) outside=\(maskOutside)")
        print("  \(changed ? "✓" : "✗") inside face changed: spot \(beforeCenter)→\(afterCenter), grain \(String(format: "%.1f", grainBefore))→\(String(format: "%.1f", grainAfter))")
        print("  \(untouched ? "✓" : "✗") outside face unchanged: \(afterCorner) (before processing: \(beforeCorner))")
        return maskOK && changed && untouched
    }

    /// Flat skin plus fine grain and one small spot — a fixture whose features
    /// are within the engine's working range.
    private static func makeTexturedSpotImage(size: Int, spotCenter: CGPoint, spotDiameter: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 128 / 255, green: 128 / 255, blue: 128 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))

        // Fine grain across the whole frame, so the "inside changed" test has
        // something the engine is meant to reduce.
        var generator = SeededGenerator(seed: 0x5EED_17A5)
        for _ in 0..<(size * size / 8) {
            let x = Int.random(in: 0..<size, using: &generator)
            let y = Int.random(in: 0..<size, using: &generator)
            let v = Double.random(in: 0.35...0.65, using: &generator)
            context.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }

        // A small bright spot: within the median's reach, unlike the 20px block
        // this test used to draw.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: spotCenter.x - CGFloat(spotDiameter) / 2,
                            y: spotCenter.y - CGFloat(spotDiameter) / 2,
                            width: CGFloat(spotDiameter), height: CGFloat(spotDiameter)))
        return context.makeImage()
    }

    // MARK: - ۳) صافی پوست نباید چشم و لب را تار کند

    private static func checkSmoothPreservesFeatures() -> Bool {
        let size = 400
        // تصویری پر از نویز ریز می‌سازیم؛ اندازه‌گیری «زبری» قبل و بعد نشان می‌دهد
        // صافی پوست واقعاً اعمال شده و آیا نواحی چشم دست‌نخورده مانده‌اند یا نه.
        guard let base = makeNoisyImage(size: size) else {
            print("  ✗ could not build test image")
            return false
        }
        let extent = CGRect(x: 0, y: 0, width: size, height: size)

        // چهره‌ی مربعی با چشم در مرکز؛ چشم از ماسک پوست بیرون می‌ماند.
        let eyeRect = CGRect(x: 0.45, y: 0.45, width: 0.10, height: 0.08)
        let face = FaceGeometry.synthetic(
            boundingBox: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            faceContour: [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.25),
                          CGPoint(x: 0.75, y: 0.75), CGPoint(x: 0.25, y: 0.75)],
            leftEye: [CGPoint(x: eyeRect.minX, y: eyeRect.minY),
                      CGPoint(x: eyeRect.maxX, y: eyeRect.minY),
                      CGPoint(x: eyeRect.maxX, y: eyeRect.maxY),
                      CGPoint(x: eyeRect.minX, y: eyeRect.maxY)],
            rightEye: [],
            leftEyebrow: [], rightEyebrow: [],
            outerLips: [CGPoint(x: 0.44, y: 0.30), CGPoint(x: 0.56, y: 0.30),
                         CGPoint(x: 0.56, y: 0.34), CGPoint(x: 0.44, y: 0.34)],
            innerLips: [], nose: [])

        let processor = ImageProcessor.shared
        guard let masks = processor.buildMasks(extent: extent, faces: [face]) else {
            print("  ✗ could not build mask")
            return false
        }

        var adjustments = Adjustments()
        adjustments.smooth = 80

        let source = CIImage(cgImage: base).cropped(to: extent)
        let output = processor.process(source, adjustments: adjustments,
                                       masks: masks, faces: [face])
        guard let rendered = processor.renderCGImage(output, scale: 1) else {
            print("  ✗ processing failed")
            return false
        }

        // نویز پوست (نزدیک لبه‌ی چپ داخل چهره) باید کم شود…
        let skinRect = CGRect(x: 112, y: 200, width: 40, height: 40)
        let eyeRectPx = CGRect(x: 184, y: 192, width: 32, height: 24)
        let skinBefore = roughness(base, rect: skinRect)
        let skinAfter = roughness(rendered, rect: skinRect)
        // …ولی جزئیات داخل چشم باید تقریباً دست‌نخورده بماند.
        let eyeBefore = roughness(base, rect: eyeRectPx)
        let eyeAfter = roughness(rendered, rect: eyeRectPx)

        // برای اینکه تشخیص بدهیم «منطقه‌ی تست» درست انتخاب شده، خودِ ماسک را هم می‌خوانیم.
        if let skinMask = masks.skin, let maskImage = processor.renderCGImage(skinMask, scale: 1) {
            let skinMaskValue = luminance(maskImage, x: Int(skinRect.midX), y: Int(skinRect.midY))
            let eyeMaskValue = luminance(maskImage, x: Int(eyeRectPx.midX), y: Int(eyeRectPx.midY))
            print("  • skin mask value at skin sample=\(skinMaskValue.map(String.init) ?? "?") and at eye sample=\(eyeMaskValue.map(String.init) ?? "?") (expect high on skin, ~0 on eye)")
        }

        guard let skinBefore, let skinAfter, let eyeBefore, let eyeAfter else {
            print("  ✗ texture measurement failed")
            return false
        }

        let skinSmoothed = skinAfter < skinBefore * 0.75
        let eyeIntact = eyeAfter > eyeBefore * 0.85
        let skinRatio = skinAfter / max(skinBefore, 1e-6)
        let eyeRatio = eyeAfter / max(eyeBefore, 1e-6)
        print("  \(skinSmoothed ? "✓" : "✗") skin smoothed: \(String(format: "%.1f", skinBefore)) → \(String(format: "%.1f", skinAfter)) (\(String(format: "%.2f", skinRatio))×, expect < 0.75)")
        print("  \(eyeIntact ? "✓" : "✗") eyes not blurred: \(String(format: "%.1f", eyeBefore)) → \(String(format: "%.1f", eyeAfter)) (\(String(format: "%.2f", eyeRatio))×, expect > 0.85)")
        return skinSmoothed && eyeIntact
    }

    // MARK: - ۳b) سپر چشم در مقیاس واقعی یک پرتره

    /// The hole in the skin mask is what protects the eye, and the hole only
    /// works if the silhouette's feather cannot reach across it. On a real
    /// portrait the feather is tens of pixels wide while an eye is a couple of
    /// dozen, so a 400 px fixture cannot see the failure. This one uses a face a
    /// third of a 2000 px frame — the geometry an actual photo has.
    private static func checkEyeShieldAtRealScale() -> Bool {
        let size = 2000
        let extent = CGRect(x: 0, y: 0, width: size, height: size)
        func outline(_ r: CGRect) -> [CGPoint] {
            [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
             CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        }
        let leftEye = CGRect(x: 0.409, y: 0.594, width: 0.022, height: 0.011)
        let rightEye = leftEye.offsetBy(dx: 0.16, dy: 0)
        let face = FaceGeometry.synthetic(
            boundingBox: CGRect(x: 0.34, y: 0.22, width: 0.32, height: 0.56),
            faceContour: outline(CGRect(x: 0.34, y: 0.22, width: 0.32, height: 0.56)),
            leftEye: outline(leftEye),
            rightEye: outline(rightEye),
            outerLips: outline(CGRect(x: 0.46, y: 0.34, width: 0.08, height: 0.03)))

        guard let masks = ImageProcessor.shared.buildMasks(extent: extent, faces: [face]),
              let skin = masks.skin,
              let maskImage = ImageProcessor.shared.renderCGImage(skin, scale: 1) else {
            print("  ✗ could not build the skin mask")
            return false
        }

        func coverage(_ x: CGFloat, _ y: CGFloat) -> Int? {
            luminance(maskImage, normalizedAt: CGPoint(x: x, y: y)).map { $0 * 100 / 255 }
        }
        let centre = coverage(leftEye.midX, leftEye.midY)
        // Lash line and lid crease: outside Vision's outline, inside the shield.
        let lash = coverage(leftEye.midX, leftEye.maxY + leftEye.height * 0.30)
        let cheek = coverage(0.42, 0.47)

        guard let centre, let lash, let cheek else {
            print("  ✗ could not read the skin mask")
            return false
        }
        // The lash sample sits eight pixels from the shield's edge, inside its
        // feather, so a few percent of the smoothing is still expected there.
        let eyeClear = centre < 3 && lash < 12
        let skinCovered = cheek > 60
        print("  \(eyeClear ? "✓" : "✗") skin coverage inside the eye=\(centre)% and on the lash band=\(lash)% (expect ~0)")
        print("  \(skinCovered ? "✓" : "✗") skin coverage on the cheek=\(cheek)% (expect > 60)")
        return eyeClear && skinCovered
    }

    // MARK: - ۴) زنجیره‌ی کامل روی تصویر مصنوعی

    private static func checkSyntheticPortrait(outDirectory: String) -> Bool {
        let width = 700, height = 950
        guard let base = makeSyntheticPortrait(width: width, height: height) else { return false }
        let extent = CGRect(x: 0, y: 0, width: width, height: height)

        let face = FaceGeometry.synthetic(
            boundingBox: CGRect(x: 0.28, y: 0.42, width: 0.44, height: 0.42),
            faceContour: [CGPoint(x: 0.30, y: 0.44), CGPoint(x: 0.70, y: 0.44),
                          CGPoint(x: 0.74, y: 0.62), CGPoint(x: 0.70, y: 0.82),
                          CGPoint(x: 0.30, y: 0.82), CGPoint(x: 0.26, y: 0.62)],
            leftEye: [CGPoint(x: 0.38, y: 0.63), CGPoint(x: 0.46, y: 0.63),
                           CGPoint(x: 0.46, y: 0.67), CGPoint(x: 0.38, y: 0.67)],
            rightEye: [],
            leftEyebrow: [], rightEyebrow: [],
            outerLips: [CGPoint(x: 0.44, y: 0.50), CGPoint(x: 0.56, y: 0.50),
                         CGPoint(x: 0.56, y: 0.535), CGPoint(x: 0.44, y: 0.535)],
            innerLips: [], nose: [])

        let processor = ImageProcessor.shared
        let source = CIImage(cgImage: base).cropped(to: extent)
        guard let masks = processor.buildMasks(extent: extent, faces: [face], image: source) else { return false }
        let preset = Preset.with(id: "glamour")!.adjustments
        let output = processor.process(source, adjustments: preset,
                                       masks: masks, faces: [face])

        let directory = URL(fileURLWithPath: outDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let wroteBefore = processor.write(source, to: directory.appendingPathComponent("selftest-synthetic-before.png"), format: .png, quality: 1)
        let wroteAfter = processor.write(output, to: directory.appendingPathComponent("selftest-synthetic-after.png"), format: .png, quality: 1)

        guard let rendered = processor.renderCGImage(output, scale: 1),
              let meanBefore = meanLuminance(base),
              let meanAfter = meanLuminance(rendered) else {
            print("  ✗ could not render output")
            return false
        }

        let saneOutput = meanAfter > 20 && meanAfter < 245
        print("  \(saneOutput ? "✓" : "✗") mean luminance: before=\(meanBefore) after=\(meanAfter)")
        print("  \(wroteBefore && wroteAfter ? "✓" : "✗") test files written to \(outDirectory)")
        return saneOutput && wroteBefore && wroteAfter
    }

    // MARK: - ۴) کتابخانه‌ی پریست

    /// هر پریست باید یک نقطه‌ی شروع واقعی باشد: شناسه و نام یکتا، همه‌ی
    /// مقادیر داخل بازه‌ی اسلایدر خودشان، شناسه‌های look/shade که واقعاً
    /// وجود دارند، و اثر دیدنی روی صورت در خط لوله‌ی واقعی.
    private static func checkPresetLibrary() -> Bool {
        var ok = true

        let thinGroups = PresetGroup.allCases.filter { Preset.inGroup($0).count < 4 }
        let wellStocked = Preset.all.count >= 30 && thinGroups.isEmpty
        print("  \(wellStocked ? "✓" : "✗") \(Preset.all.count) looks in \(PresetGroup.allCases.count) groups")
        for group in thinGroups {
            print("    ✗ \(group.title) has only \(Preset.inGroup(group).count) looks")
        }
        ok = wellStocked && ok

        for (label, values) in [("id", Preset.all.map(\.id)),
                                ("name", Preset.all.map(\.title))] {
            let repeats = Set(values).count != values.count
            print("  \(repeats ? "✗" : "✓") every \(label) is unique")
            ok = !repeats && ok
        }

        var sameNumbers: [String] = []
        for i in Preset.all.indices {
            for j in (i + 1)..<Preset.all.count
            where Preset.all[i].adjustments == Preset.all[j].adjustments {
                sameNumbers.append("\(Preset.all[i].title) and \(Preset.all[j].title)")
            }
        }
        print("  \(sameNumbers.isEmpty ? "✓" : "✗") no two looks share the same numbers")
        for duplicate in sameNumbers { print("    ✗ \(duplicate)") }
        ok = sameNumbers.isEmpty && ok

        // Fields whose slider only runs one way; a negative preset value here
        // would be silently clamped in the UI and read as a broken look.
        let oneSided: [(String, KeyPath<Adjustments, Double>)] = [
            ("smooth", \.smooth), ("blemish", \.blemish), ("wrinkle", \.wrinkle),
            ("skinToneEvens", \.skinToneEvens), ("darkCircles", \.darkCircles),
            ("skinBrighten", \.skinBrighten), ("texturePreserve", \.texturePreserve),
            ("teethWhiten", \.teethWhiten), ("eyeBrighten", \.eyeBrighten),
            ("eyeSharpen", \.eyeSharpen), ("vignette", \.vignette),
            ("lookStrength", \.lookStrength), ("grain", \.grain),
            ("lipTint", \.lipTint), ("blush", \.blush), ("browDefine", \.browDefine),
            ("eyeshadow", \.eyeshadow), ("eyeliner", \.eyeliner),
        ]
        let twoSided: [(String, KeyPath<Adjustments, Double>)] = [
            ("eyeSize", \.eyeSize), ("noseSize", \.noseSize), ("noseTip", \.noseTip),
            ("lipSize", \.lipSize), ("cheekSize", \.cheekSize), ("jawWidth", \.jawWidth),
            ("chinLength", \.chinLength), ("faceWidth", \.faceWidth),
            ("faceLength", \.faceLength), ("exposure", \.exposure),
            ("contrast", \.contrast), ("blacks", \.blacks), ("whites", \.whites),
            ("saturation", \.saturation), ("vibrance", \.vibrance),
            ("warmth", \.warmth), ("clarity", \.clarity),
        ]

        var offScale: [String] = []
        for preset in Preset.all {
            for (name, path) in oneSided where !preset.adjustments[keyPath: path].isFinite
                                                || preset.adjustments[keyPath: path] < 0
                                                || preset.adjustments[keyPath: path] > 100 {
                offScale.append("\(preset.id).\(name)")
            }
            for (name, path) in twoSided where !preset.adjustments[keyPath: path].isFinite
                                                 || abs(preset.adjustments[keyPath: path]) > 100 {
                offScale.append("\(preset.id).\(name)")
            }
            if !preset.adjustments.lookID.isEmpty,
               FilmLook.named(preset.adjustments.lookID) == .none || preset.adjustments.lookStrength <= 0 {
                offScale.append("\(preset.id).look")
            }
        }
        print("  \(offScale.isEmpty ? "✓" : "✗") every value is inside its own slider")
        for offender in offScale { print("    ✗ \(offender)") }
        ok = offScale.isEmpty && ok

        ok = checkPresetsThroughPipeline() && ok
        return ok
    }

    /// Small synthetic face, every look run through the real engine: a preset
    /// that leaves the face untouched is a preset the user cannot see working.
    private static func checkPresetsThroughPipeline() -> Bool {
        let width = 420, height = 560
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let faceBox = CGRect(x: 0.28, y: 0.42, width: 0.44, height: 0.42)
        guard let base = makeSyntheticPortrait(width: width, height: height) else {
            print("  ✗ could not build the synthetic portrait")
            return false
        }
        let face = FaceGeometry.synthetic(
            boundingBox: faceBox,
            faceContour: [CGPoint(x: 0.30, y: 0.44), CGPoint(x: 0.70, y: 0.44),
                          CGPoint(x: 0.74, y: 0.62), CGPoint(x: 0.70, y: 0.82),
                          CGPoint(x: 0.30, y: 0.82), CGPoint(x: 0.26, y: 0.62)],
            leftEye: [CGPoint(x: 0.38, y: 0.63), CGPoint(x: 0.46, y: 0.63),
                      CGPoint(x: 0.46, y: 0.67), CGPoint(x: 0.38, y: 0.67)],
            rightEye: [], leftEyebrow: [], rightEyebrow: [],
            outerLips: [CGPoint(x: 0.44, y: 0.50), CGPoint(x: 0.56, y: 0.50),
                        CGPoint(x: 0.56, y: 0.535), CGPoint(x: 0.44, y: 0.535)],
            innerLips: [], nose: [])

        let processor = ImageProcessor.shared
        let source = CIImage(cgImage: base).cropped(to: extent)
        // The baseline is the pipeline run with nothing set, not the raw pixels:
        // every pass through the renderer shifts the frame a little, and that
        // shift would otherwise hide what each look actually contributes.
        guard let masks = processor.buildMasks(extent: extent, faces: [face], image: source) else {
            print("  ✗ could not build masks for the preset sweep")
            return false
        }
        let cleared = processor.process(source, adjustments: .zero, masks: masks, faces: [face])
        guard let before = processor.renderCGImage(cleared, scale: 1) else {
            print("  ✗ could not render the neutral baseline")
            return false
        }

        var dead: [String] = []
        var renders: [(String, CGImage)] = []
        var weakest = ("", Double.greatestFiniteMagnitude)
        for preset in Preset.all {
            let output = processor.process(source, adjustments: preset.adjustments,
                                           masks: masks, faces: [face])
            guard let rendered = processor.renderCGImage(output, scale: 1) else {
                print("    ✗ \(preset.title) did not render")
                dead.append(preset.title)
                continue
            }
            let delta = regionDifference(before, rendered, normalized: faceBox)
            if delta < 2 { dead.append(preset.title) }
            if delta < weakest.1 { weakest = (preset.title, delta) }
            renders.append((preset.title, rendered))
        }

        print("  \(dead.isEmpty ? "✓" : "✗") all \(Preset.all.count) looks change the face (weakest: \(weakest.0) Δ\(String(format: "%.1f", weakest.1)))")
        for name in dead { print("    ✗ \(name) does nothing") }

        // Two looks that render the same face are one look wearing two names —
        // the usual symptom of a copied entry whose numbers were never changed.
        // Colour, not brightness: cosmetics and grades move hue first.
        var twins: [String] = []
        var closest = ("", "", Double.greatestFiniteMagnitude)
        for i in renders.indices {
            for j in (i + 1)..<renders.count {
                let d = colorDifference(renders[i].1, renders[j].1, normalized: faceBox, stride: 6)
                if d < closest.2 { closest = (renders[i].0, renders[j].0, d) }
                if d < 0.6 { twins.append("\(renders[i].0) and \(renders[j].0)") }
            }
        }
        print("  \(twins.isEmpty ? "✓" : "✗") every look is its own image (closest pair: \(closest.0)/\(closest.1) Δ\(String(format: "%.1f", closest.2)))")
        for pair in twins { print("    ✗ \(pair)") }
        return dead.isEmpty && twins.isEmpty
    }

    // MARK: - ۴) عکس واقعی

    private static func checkRealFace(path: String, outDirectory: String) -> Bool {
        let processor = ImageProcessor.shared
        let url = URL(fileURLWithPath: path)

        // Exercise the same entry point as the app, including detection on the
        // preview and mask building, so this test cannot drift from production.
        guard let result = processor.load(from: url, previewMaxDimension: 1400) else {
            print("  ✗ could not read test photo: \(path)")
            return false
        }

        let source = result.sourcePreview
        let previewExtent = source.extent
        let faces = result.faces
        print("  • size: \(Int(result.pixelSize.width))×\(Int(result.pixelSize.height)) | faces detected: \(faces.count)")
        for face in faces {
            print("    - face box: x=\(String(format: "%.3f", face.boundingBox.minX)) y=\(String(format: "%.3f", face.boundingBox.minY)) w=\(String(format: "%.3f", face.boundingBox.width)) h=\(String(format: "%.3f", face.boundingBox.height))")
            print("      contour=\(face.faceContour.count) eyes=\(face.eyePolygons.count) brows=\(face.eyebrowPolygons.count) lips=\(face.lipPolygon.count) nose=\(face.nose.count)")
        }
        guard !faces.isEmpty else {
            print("  ✗ no face found")
            return false
        }

        if let buffer = AutoAnalyzer.analysisBuffer(source) {
            for face in faces {
                let fraction = AutoAnalyzer.visibleTeethFraction(buffer: buffer, face: face)
                print("    - visible teeth: \(face.hasVisibleTeeth ? "yes" : "no") | openness=\(String(format: "%.2f", face.mouthOpenness)) | fraction=\(String(format: "%.2f", fraction))")
                print("    - eye sclera split: luma >= \(String(format: "%.2f", face.eyeScleraLuminance))")
            }
        }

        guard let masks = result.masksPreview else {
            print("  ✗ could not build mask")
            return false
        }
        print("    - masks: teeth=\(masks.teeth != nil ? "yes" : "no") sclera=\(masks.sclera != nil ? "yes" : "no") iris=\(masks.iris != nil ? "yes" : "no") lashes=\(masks.lashes != nil ? "yes" : "no")")

        // Where the skin mask actually sits on a real eye. Smoothing that
        // reaches the lash line is the failure a user sees as a blurred eye,
        // and only the real photo has a real eyelid.
        var shieldClear = false
        if let skin = masks.skin, let skinImage = processor.renderCGImage(skin, scale: 1) {
            var worstEye = 0, worstLash = 0
            for face in faces {
                for eye in face.eyePolygons {
                    let box = FaceGeometry.boundingBox(of: eye)
                    worstEye = max(worstEye,
                                   (luminance(skinImage, normalizedAt: CGPoint(x: box.midX, y: box.midY)) ?? 255) * 100 / 255)
                    worstLash = max(worstLash,
                                    (luminance(skinImage, normalizedAt: CGPoint(x: box.midX,
                                                                                y: box.maxY + box.height * 0.30)) ?? 255) * 100 / 255)
                }
            }
            shieldClear = worstEye < 10 && worstLash < 25
            print("    \(shieldClear ? "✓" : "✗") skin coverage on a real eye: inside=\(worstEye)% lash band=\(worstLash)% (expect < 10 / < 25)")
        }

        let directory = URL(fileURLWithPath: outDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let faceMask = masks.face {
            let overBlack = faceMask.composited(over: CIImage(color: .black).cropped(to: previewExtent))
            _ = processor.write(overBlack, to: directory.appendingPathComponent("selftest-mask.png"), format: .png, quality: 1)
            print("  ✓ skin mask written: selftest-mask.png")
        }
        for (name, mask) in [("sclera", masks.sclera), ("iris", masks.iris),
                             ("teeth", masks.teeth), ("lashes", masks.lashes)] {
            guard let mask else { continue }
            let overBlack = mask.composited(over: CIImage(color: .black).cropped(to: previewExtent))
            _ = processor.write(overBlack, to: directory.appendingPathComponent("selftest-\(name).png"),
                                format: .png, quality: 1)
        }

        _ = processor.write(source, to: directory.appendingPathComponent("selftest-face-before.png"), format: .png, quality: 1)

        let output = processor.process(source, adjustments: Preset.with(id: "glamour")!.adjustments,
                                       masks: masks, faces: faces)
        let wrote = processor.write(output, to: directory.appendingPathComponent("selftest-face-after.png"), format: .png, quality: 1)
        print("  \(wrote ? "✓" : "✗") retouched output written: selftest-face-after.png")

        // A group photo has to retouch every person in it, so the mask and the
        // skin pass are measured inside each face box rather than once overall.
        var everyFace = true
        if faces.count > 1 {
            let retouch = Preset.with(id: "glamour")!.adjustments.retouchOnly
            if let before = processor.context.createCGImage(source, from: previewExtent),
               let after = processor.context.createCGImage(
                    processor.process(source, adjustments: retouch, masks: masks, faces: faces),
                    from: previewExtent),
               let skin = masks.skin,
               let skinRender = processor.context.createCGImage(skin, from: previewExtent) {
                for (index, face) in faces.enumerated() {
                    let coverage = maskCoverage(skinRender, normalized: face.boundingBox)
                    let delta = regionDifference(before, after, normalized: face.boundingBox)
                    let ok = coverage > 0.10 && delta > 0.15
                    everyFace = everyFace && ok
                    print("  \(ok ? "✓" : "✗") face \(index + 1) in a \(faces.count)-face photo: "
                        + "skin coverage \(String(format: "%.2f", coverage)) (expect > 0.10), "
                        + "retouch Δ=\(String(format: "%.2f", delta)) (expect > 0.15)")
                }
                let reshape = Preset.with(id: "studio")!.adjustments.reshapeOnly
                for (index, face) in faces.enumerated() {
                    let controls = FeatureReshaper.controls(for: face, adjustments: reshape).count
                    let ok = controls > 0
                    everyFace = everyFace && ok
                    print("  \(ok ? "✓" : "✗") face \(index + 1) reshape: \(controls) mesh controls (expect > 0)")
                }
            } else {
                print("  ✗ could not render the masks for the multi-face check")
                everyFace = false
            }
        }
        // The real complaint about the old auto was that pressing it faded the
        // photo, and a fade is measurable: the tonal spread narrows and the black
        // floor rises. Both are checked on the actual picture.
        var autoHoldsUp = true
        if let buffer = AutoAnalyzer.analysisBuffer(source),
           let beforeImage = processor.context.createCGImage(source, from: previewExtent),
           let before = tonalSpread(beforeImage) {
            let patch = AutoAnalyzer.autoColorLight(buffer)
            if let afterRender = processor.context.createCGImage(
                    processor.process(source, adjustments: patch, masks: nil), from: previewExtent),
               let after = tonalSpread(afterRender) {
                let narrowed = (before.high - before.low) - (after.high - after.low)
                let liftedFloor = after.low - before.low
                autoHoldsUp = narrowed < 8 && liftedFloor < 6
                print("  \(autoHoldsUp ? "✓" : "✗") Auto Color on a real photo keeps the tonal range: "
                    + "spread \(String(format: "%.0f", before.high - before.low)) → \(String(format: "%.0f", after.high - after.low)), "
                    + "floor \(String(format: "%.0f", before.low)) → \(String(format: "%.0f", after.low))")
                print("     applied: exposure=\(fmt(patch.exposure)) contrast=\(fmt(patch.contrast)) "
                    + "blacks=\(fmt(patch.blacks)) whites=\(fmt(patch.whites)) warmth=\(fmt(patch.warmth)) "
                    + "vibrance=\(fmt(patch.vibrance)) saturation=\(fmt(patch.saturation)) clarity=\(fmt(patch.clarity))")
            }
        }

        return wrote && everyFace && shieldClear && autoHoldsUp
    }

    // MARK: - ۵) خودکار رنگ/نور و رتوش باید کاملاً جدا باشند

    private static func checkAutoSeparation() -> Bool {
        guard let cg = makeSyntheticPortrait(width: 700, height: 950) else {
            print("  ✗ could not build test image")
            return false
        }
        let src = CIImage(cgImage: cg)
        guard let buffer = AutoAnalyzer.analysisBuffer(src) else {
            print("  ✗ could not build analysis buffer")
            return false
        }

        var face = FaceGeometry.synthetic(
            boundingBox: CGRect(x: 0.28, y: 0.42, width: 0.44, height: 0.42),
            faceContour: [CGPoint(x: 0.30, y: 0.44), CGPoint(x: 0.70, y: 0.44),
                          CGPoint(x: 0.74, y: 0.62), CGPoint(x: 0.70, y: 0.82),
                          CGPoint(x: 0.30, y: 0.82), CGPoint(x: 0.26, y: 0.62)],
            leftEye: [CGPoint(x: 0.38, y: 0.63), CGPoint(x: 0.46, y: 0.63),
                           CGPoint(x: 0.46, y: 0.67), CGPoint(x: 0.38, y: 0.67)],
            rightEye: [],
            leftEyebrow: [], rightEyebrow: [],
            outerLips: [CGPoint(x: 0.44, y: 0.50), CGPoint(x: 0.56, y: 0.50),
                         CGPoint(x: 0.56, y: 0.535), CGPoint(x: 0.44, y: 0.535)],
            innerLips: [], nose: [])
        // The production load path always measures the eyes before Auto Retouch
        // runs; a hand-built fixture has to say so too.
        face.hasUsableEyes = true

        let extent = src.extent
        let processor = ImageProcessor.shared
        let masks = processor.buildMasks(extent: extent, faces: [face], image: src)
        let maskBuffer = masks?.skin.flatMap { AutoAnalyzer.analysisBuffer($0) }

        let colorPatch = AutoAnalyzer.autoColorLight(buffer)
        let retouchPatch = AutoAnalyzer.autoRetouch(buffer,
                                                    skinMask: maskBuffer,
                                                    faces: [face],
                                                    globalMedianLuminance: AutoAnalyzer.stats(buffer).medianLuminance)

        // «خودکار رنگ و نور» نباید هیچ فیلد رتوشی را تغییر دهد.
        let colorTouchesRetouch = colorPatch.smooth != 0 || colorPatch.blemish != 0
            || colorPatch.skinBrighten != 0 || colorPatch.teethWhiten != 0
            || colorPatch.eyeBrighten != 0 || colorPatch.eyeSharpen != 0
        // «خودکار رتوش» نباید هیچ فیلد رنگ/نوری را تغییر دهد.
        let retouchTouchesColor = retouchPatch.exposure != 0 || retouchPatch.contrast != 0
            || retouchPatch.blacks != 0 || retouchPatch.whites != 0
            || retouchPatch.saturation != 0 || retouchPatch.vibrance != 0
            || retouchPatch.warmth != 0 || retouchPatch.clarity != 0
            || retouchPatch.vignette != 0

        // و هر کدام باید چیزی را واقعاً تنظیم کند.
        let colorIsUseful = colorPatch.exposure != 0 || colorPatch.contrast != 0
            || colorPatch.blacks != 0 || colorPatch.whites != 0
            || colorPatch.saturation != 0 || colorPatch.vibrance != 0
            || colorPatch.warmth != 0 || colorPatch.clarity != 0
        let retouchIsUseful = retouchPatch.smooth != 0 && retouchPatch.eyeBrighten != 0

        print("  \(!colorTouchesRetouch ? "✓" : "✗") Auto Color & Light did not touch retouch fields")
        print("     color/light → exposure=\(fmt(colorPatch.exposure)) contrast=\(fmt(colorPatch.contrast)) blacks=\(fmt(colorPatch.blacks)) whites=\(fmt(colorPatch.whites)) saturation=\(fmt(colorPatch.saturation)) vibrance=\(fmt(colorPatch.vibrance)) warmth=\(fmt(colorPatch.warmth)) clarity=\(fmt(colorPatch.clarity))")
        print("  \(!retouchTouchesColor ? "✓" : "✗") Auto Retouch did not touch color/light fields")
        print("     retouch → smooth=\(fmt(retouchPatch.smooth)) blemish=\(fmt(retouchPatch.blemish)) skinBrighten=\(fmt(retouchPatch.skinBrighten)) teeth=\(fmt(retouchPatch.teethWhiten)) eyeBrighten=\(fmt(retouchPatch.eyeBrighten)) eyeSharpen=\(fmt(retouchPatch.eyeSharpen))")
        print("  \(colorIsUseful ? "✓" : "✗") Auto Color & Light produced meaningful values")
        print("  \(retouchIsUseful ? "✓" : "✗") Auto Retouch produced meaningful values")

        // Pressing one Auto and then the other must leave both sets in place.
        // This is the exact sequence that previously made the two look like a
        // single combined action.
        let colorOnly = Adjustments().applyingColorLight(colorPatch)
        let both = colorOnly.applyingRetouch(retouchPatch)

        let colorSurvived = both.colorLightOnly == colorOnly.colorLightOnly
        let bothPresent = both.colorLightOnly != .zero && both.retouchOnly != .zero
        print("  \(colorSurvived ? "✓" : "✗") Auto Color & Light then Auto Retouch: color/light survived")
        print("  \(bothPresent ? "✓" : "✗") both groups present at once")

        // And in the reverse order.
        let retouchOnly = Adjustments().applyingRetouch(retouchPatch)
        let reverse = retouchOnly.applyingColorLight(colorPatch)
        let reverseOK = reverse.retouchOnly == retouchOnly.retouchOnly
        print("  \(reverseOK ? "✓" : "✗") Auto Retouch then Auto Color & Light: retouch survived")

        return !colorTouchesRetouch && !retouchTouchesColor && colorIsUseful && retouchIsUseful
            && colorSurvived && bothPresent && reverseOK
    }

    private static func fmt(_ value: Double) -> String { String(format: "%.0f", value) }

    /// A vertical ramp whose tones are squeezed between `low` and `high`, with a
    /// little colour so the analysis reads a photograph rather than a test chart.
    private static func makeTonalFixture(size: Int, low: Double, high: Double) -> CGImage? {
        guard let context = CGContext(data: nil, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for y in 0..<size {
            let t = CGFloat(y) / CGFloat(size - 1)
            let v = CGFloat(low) + CGFloat(high - low) * t
            context.setFillColor(CGColor(red: min(1, v + 0.03), green: v,
                                         blue: max(0, v - 0.02), alpha: 1))
            context.fill(CGRect(x: 0, y: y, width: size, height: 1))
        }
        return context.makeImage()
    }

    /// The 0.5th, 50th and 99.5th percentiles of the frame's luminance — how far
    /// the picture actually reaches toward black and toward white, and where its
    /// mid-tones sit.
    private static func tonalSpread(_ image: CGImage) -> (low: Double, mid: Double, high: Double)? {
        guard let data = image.dataProvider?.data, let pointer = CFDataGetBytePtr(data) else { return nil }
        let bpp = max(1, image.bitsPerPixel / 8), bpr = image.bytesPerRow
        var histogram = [Int](repeating: 0, count: 256)
        var samples = 0
        var y = 0
        while y < image.height {
            var x = 0
            while x < image.width {
                let i = y * bpr + x * bpp
                if i + 2 < CFDataGetLength(data) {
                    let luma = (Int(pointer[i]) * 77 + Int(pointer[i + 1]) * 151 + Int(pointer[i + 2]) * 28) / 256
                    histogram[min(255, max(0, luma))] += 1
                    samples += 1
                }
                x += 2
            }
            y += 2
        }
        guard samples > 100 else { return nil }
        func edge(_ fraction: Double) -> Double {
            let target = Double(samples) * fraction
            var running = 0.0
            for (index, count) in histogram.enumerated() {
                running += Double(count)
                if running >= target { return Double(index) }
            }
            return 255
        }
        return (edge(0.005), edge(0.50), edge(0.995))
    }

    /// Auto Color & Light has to behave like an assistant, not like a fade: it
    /// reads where the picture's own endpoints are and stretches toward them, it
    /// does nothing where there is nothing to recover, and it is a no-op at zero.
    private static func checkAutoColorLevels() -> Bool {
        var passed = true
        let processor = ImageProcessor.shared
        let size = 128
        let extent = CGRect(x: 0, y: 0, width: size, height: size)
        func render(_ image: CIImage) -> CGImage? { processor.context.createCGImage(image, from: extent) }
        func delta(_ a: CGImage, _ b: CGImage) -> Double { meanAbsoluteDifference(a, b) ?? -1 }

        // 1) Levels at zero must be exactly the input. Everything downstream is
        //    anchored on this, including the auto's own no-op path.
        guard let faded = makeTonalFixture(size: size, low: 0.25, high: 0.75),
              let neutral = makeTonalFixture(size: size, low: 0, high: 1) else {
            print("  ✗ could not build the tonal fixtures")
            return false
        }
        let fadedSource = CIImage(cgImage: faded)
        let neutralSource = CIImage(cgImage: neutral)
        let identity = delta(render(fadedSource) ?? faded,
                             render(LookEngine.applyLevels(fadedSource, black: 0, white: 1)) ?? faded)
        let throughPipeline = delta(render(fadedSource) ?? faded,
                                    render(processor.process(fadedSource, adjustments: .zero, masks: nil)) ?? faded)
        let noopOK = identity == 0 && throughPipeline == 0
        print("  \(noopOK ? "✓" : "✗") levels at zero change nothing: kernel Δ=\(String(format: "%.2f", identity)) pipeline Δ=\(String(format: "%.2f", throughPipeline))")
        passed = noopOK && passed

        // 2) A faded frame is one whose darkest and brightest pixels stop short of
        //    the ends. The auto has to close that gap, not widen it.
        guard let fadedBuffer = AutoAnalyzer.analysisBuffer(fadedSource),
              let neutralBuffer = AutoAnalyzer.analysisBuffer(neutralSource) else {
            print("  ✗ could not build analysis buffers")
            return false
        }
        let patch = AutoAnalyzer.autoColorLight(fadedBuffer)
        guard let before = tonalSpread(render(fadedSource) ?? faded),
              let afterImage = render(processor.process(fadedSource, adjustments: patch, masks: nil)),
              let after = tonalSpread(afterImage) else {
            print("  ✗ could not measure the faded repair")
            return false
        }
        let spreadBefore = before.high - before.low, spreadAfter = after.high - after.low
        let repairOK = patch.blacks > 0 && patch.whites > 0
            && after.low < before.low && after.high > before.high
            && spreadAfter > spreadBefore + 60
        print("  \(repairOK ? "✓" : "✗") faded frame gets its endpoints back: blacks=\(fmt(patch.blacks)) whites=\(fmt(patch.whites)), spread \(String(format: "%.0f", spreadBefore)) → \(String(format: "%.0f", spreadAfter))")
        print("     measured endpoints: \(String(format: "%.0f–%.0f", before.low, before.high)) → \(String(format: "%.0f–%.0f", after.low, after.high)) (expect wider)")
        passed = repairOK && passed

        //    Repairing the ends must not move the middle. A levels pass that
        //    brightens the whole ramp is the wash-out this auto used to produce,
        //    and the mid-tone percentile is where you see it.
        let midMoved = abs(after.mid - before.mid)
        let pivotOK = midMoved <= 8
        print("  \(pivotOK ? "✓" : "✗") mid-tones hold their place: median \(String(format: "%.0f", before.mid)) → \(String(format: "%.0f", after.mid)) (expect ≤ 8 apart)")
        passed = pivotOK && passed

        //    The old auto pulled the median all the way to mid-grey, which is what
        //    produced the fade the owner complained about. The new one is capped
        //    at ±18 and a frame that only needs a small correction gets a small
        //    one, so the lever must stay well inside that cap.
        let exposureOK = abs(patch.exposure) <= 10
        print("  \(exposureOK ? "✓" : "✗") exposure correction stays modest: \(fmt(patch.exposure)) (expect ≤ 10)")
        passed = exposureOK && passed

        // 3) Full-range frame: nothing to recover at either end, so the auto must
        //    say so rather than dig the shadows out further.
        let fullPatch = AutoAnalyzer.autoColorLight(neutralBuffer)
        let restraintOK = fullPatch.blacks == 0 && fullPatch.whites == 0
        print("  \(restraintOK ? "✓" : "✗") full-range frame gets no levels nudge: blacks=\(fmt(fullPatch.blacks)) whites=\(fmt(fullPatch.whites))")
        passed = restraintOK && passed

        // 4) Strength scales the whole decision together and touches nothing else.
        let half = patch.scaledColorLight(by: 50)
        let scaleOK = abs(half.blacks - patch.blacks * 0.5) < 0.001
            && abs(half.whites - patch.whites * 0.5) < 0.001
            && abs(half.exposure - patch.exposure * 0.5) < 0.001
            && half.vignette == patch.vignette
        let none = patch.scaledColorLight(by: 0)
        let zeroOK = none.colorLightOnly == Adjustments().colorLightOnly
        // Applying it must leave the retouch sliders exactly where they were.
        var base = Adjustments()
        base.smooth = 55
        base.look = .nightStock
        let applied = base.applyingColorLight(patch)
        let isolationOK = applied.smooth == 55 && applied.look == .nightStock
            && applied.blacks == patch.blacks && applied.whites == patch.whites
        let scalingOK = scaleOK && zeroOK && isolationOK
        print("  \(scalingOK ? "✓" : "✗") strength scales levels, zero is a no-op, retouch survives")
        passed = scalingOK && passed

        return passed
    }

    // MARK: - ۵) رتوش خودکار باید فقط داخل چهره اثر بگذارد

    /// Applies the retouch patch (skin + eye + teeth) and measures how much of
    /// the change lands inside the skin mask versus outside it. The skin tools
    /// are masked to the face, so the background must stay essentially intact —
    /// if it moves, "Auto Retouch" is behaving like a global edit.
    private static func checkAutoRetouchIsFaceLocal(path: String) -> Bool {
        let processor = ImageProcessor.shared
        guard let result = processor.load(from: URL(fileURLWithPath: path), previewMaxDimension: 1400) else {
            print("  ✗ could not read \(path)")
            return false
        }
        let source = result.sourcePreview
        let faces = result.faces
        guard !faces.isEmpty else {
            print("  ✗ no face found")
            return false
        }

        guard let masks = result.masksPreview,
              let skinMask = masks.skin else {
            print("  ✗ could not build masks")
            return false
        }

        // Derive the retouch patch the same way the model does.
        guard let buffer = AutoAnalyzer.analysisBuffer(source),
              let maskBuffer = AutoAnalyzer.analysisBuffer(skinMask) else {
            print("  ✗ could not build analysis buffers")
            return false
        }
        let patch = AutoAnalyzer.autoRetouch(buffer,
                                             skinMask: maskBuffer,
                                             faces: faces,
                                             globalMedianLuminance: AutoAnalyzer.stats(buffer).medianLuminance)
        print("  • patch: smooth=\(fmt(patch.smooth)) blemish=\(fmt(patch.blemish)) skinBrighten=\(fmt(patch.skinBrighten)) eyes=\(fmt(patch.eyeBrighten))")

        guard let before = processor.renderCGImage(source, scale: 1),
              let after = processor.renderCGImage(
                processor.process(source, adjustments: patch, masks: masks, faces: faces), scale: 1),
              let maskImage = processor.renderCGImage(skinMask, scale: 1) else {
            print("  ✗ could not render")
            return false
        }

        // Compare mean change inside the skin mask vs outside it, excluding a
        // feathered band around mask edges (those legitimately blend).
        let step = 3
        var insideDelta = 0.0, insideCount = 0.0
        var outsideDelta = 0.0, outsideCount = 0.0
        var y = step
        while y < before.height - step {
            var x = step
            while x < before.width - step {
                // Mask value at this pixel, and at its 4 neighbours (ring test).
                let m = luminance(maskImage, x: x, y: y) ?? 0
                let ring = [luminance(maskImage, x: x + 6, y: y) ?? 0,
                            luminance(maskImage, x: x - 6, y: y) ?? 0,
                            luminance(maskImage, x: x, y: y + 6) ?? 0,
                            luminance(maskImage, x: x, y: y - 6) ?? 0]
                let ringMin = ring.min() ?? 0
                let ringMax = ring.max() ?? 0
                let fullyInside = m > 240 && ringMin > 240
                let fullyOutside = m < 8 && ringMax < 8
                guard fullyInside || fullyOutside else { x += step; continue }

                let b = luminance(before, x: x, y: y) ?? 0
                let a = luminance(after, x: x, y: y) ?? 0
                let delta = abs(Double(a - b))
                if fullyInside {
                    insideDelta += delta; insideCount += 1
                } else {
                    outsideDelta += delta; outsideCount += 1
                }
                x += step
            }
            y += step
        }

        guard insideCount > 0, outsideCount > 0 else {
            print("  ✗ not enough samples (inside=\(Int(insideCount)) outside=\(Int(outsideCount)))")
            return false
        }
        let insideMean = insideDelta / insideCount
        let outsideMean = outsideDelta / outsideCount
        let ratio = outsideMean / max(insideMean, 1e-6)

        // Only skin is measured here (eyes and lips are outside the mask), so
        // the expected delta is small; 0.5 still proves a real change while
        // staying above the untouched background by more than an order of
        // magnitude.
        let faceChanged = insideMean > 0.5
        let backgroundIntact = ratio < 0.25
        print("  \(faceChanged ? "✓" : "✗") face region changed: mean |Δ| = \(String(format: "%.2f", insideMean)) (\(Int(insideCount)) px)")
        print("  \(backgroundIntact ? "✓" : "✗") background nearly untouched: mean |Δ| = \(String(format: "%.2f", outsideMean)) (\(Int(outsideCount)) px), ratio = \(String(format: "%.3f", ratio)) (expect < 0.25)")
        return faceChanged && backgroundIntact
    }

    // MARK: - ۶) قرارداد ماسک: خاکستریِ کاملاً مات

    /// Every mask must be OPAQUE GRAYSCALE: alpha is always 1 and the gray level
    /// carries the coverage.
    ///
    /// This is a regression test for a real bug. Masks were briefly built as
    /// transparent-background images, and CIBlendWithMask reads the mask's
    /// PREMULTIPLIED RGB, so a "transparent" empty region silently became full
    /// coverage once the mask passed through a multiply — which applied the
    /// effect to the entire photo instead of only the face. Verifying the
    /// convention here means that failure can never come back unnoticed.
    private static func checkMaskConvention() -> Bool {
        let size = 200
        let extent = CGRect(x: 0, y: 0, width: size, height: size)
        // A shape covering the left half in processing orientation.
        let shape = MaskShape(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1.0))

        guard let mask = MaskBuilder.makeMask(extent: extent, shapes: [shape], feather: 0),
              let cg = ImageProcessor.shared.renderCGImage(mask, scale: 1),
              let data = cg.dataProvider?.data,
              let pointer = CFDataGetBytePtr(data) else {
            print("  ✗ could not build mask")
            return false
        }
        let bpp = max(1, cg.bitsPerPixel / 8)
        let count = CFDataGetLength(data)

        func pixel(_ x: Int, _ y: Int) -> (gray: Int, alpha: Int)? {
            let index = y * cg.bytesPerRow + x * bpp
            guard index + 3 < count else { return nil }
            let gray = (Int(pointer[index]) + Int(pointer[index + 1]) + Int(pointer[index + 2])) / 3
            return (gray, Int(pointer[index + 3]))
        }

        // Inside the shape: gray ~255. Outside: gray ~0. Alpha must be 255 both
        // places — that is the part that was broken.
        guard let inside = pixel(size / 4, size / 2), let outside = pixel(size * 3 / 4, size / 2) else {
            print("  ✗ could not read mask pixels")
            return false
        }

        let grayOK = inside.gray > 240 && outside.gray < 15
        let alphaOK = inside.alpha == 255 && outside.alpha == 255
        print("  \(grayOK ? "✓" : "✗") gray inside=\(inside.gray) outside=\(outside.gray) (expect 255 / 0)")
        print("  \(alphaOK ? "✓" : "✗") alpha inside=\(inside.alpha) outside=\(outside.alpha) (expect 255 / 255 — masks must be opaque)")

        // And the consequence: an empty mask must block an effect entirely.
        // Blend a white image over black through an all-zero mask; the result
        // must stay black.
        let black = CIImage(color: .black).cropped(to: extent)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: extent)
        let empty = MaskBuilder.makeMask(
            extent: extent,
            shapes: [MaskShape(mode: .erase, rect: CGRect(x: 0, y: 0, width: 0.5, height: 1.0))],
            feather: 0)
        let blocked: Bool
        if let empty,
           let out = ImageProcessor.shared.renderCGImage(
            white.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: black,
                kCIInputMaskImageKey: empty
            ]).cropped(to: extent), scale: 1),
           let d = out.dataProvider?.data, let p = CFDataGetBytePtr(d) {
            let idx = (size / 2) * out.bytesPerRow + (size / 4) * max(1, out.bitsPerPixel / 8)
            blocked = Int(p[idx]) < 15
        } else {
            blocked = false
        }
        print("  \(blocked ? "✓" : "✗") an empty mask blocks the effect (was the failure mode)")
        return grayOK && alphaOK && blocked
    }

    // MARK: - ۷) دروازه‌ی لک: پوست دست‌نخورده، لک برداشته شود

    /// Blemish removal must leave clean skin alone and still clear real spots.
    ///
    /// Both halves matter. An earlier version passed "spots cleared" while
    /// wiping out pore texture everywhere, and a later one passed "texture
    /// intact" while removing nothing at all — each looked like a pass on its
    /// own. This checks the separation directly, using the same fixture shape
    /// the thresholds were measured on.
    private static func checkBlemishGate() -> Bool {
        let size = 420
        guard let base = makeSkinFixture(size: size) else {
            print("  ✗ could not build skin fixture")
            return false
        }
        let extent = CGRect(x: 0, y: 0, width: size, height: size)

        let face = FaceGeometry.synthetic(
            boundingBox: CGRect(x: 0.18, y: 0.28, width: 0.64, height: 0.64),
            faceContour: [CGPoint(x: 0.18, y: 0.28), CGPoint(x: 0.82, y: 0.28),
                          CGPoint(x: 0.82, y: 0.92), CGPoint(x: 0.18, y: 0.92)],
            leftEye: [], rightEye: [], leftEyebrow: [], rightEyebrow: [],
            outerLips: [], innerLips: [], nose: [])

        let processor = ImageProcessor.shared
        guard let masks = processor.buildMasks(extent: extent, faces: [face]) else {
            print("  ✗ could not build mask")
            return false
        }

        var adjustments = Adjustments()
        adjustments.blemish = 75

        let source = CIImage(cgImage: base).cropped(to: extent)
        let output = processor.process(source, adjustments: adjustments,
                                       masks: masks, faces: [face])
        guard let rendered = processor.renderCGImage(output, scale: 1) else {
            print("  ✗ processing failed")
            return false
        }

        // Blemishes were planted at these normalized centres.
        let blemishCentres: [(CGFloat, CGFloat)] = [(0.34, 0.62), (0.46, 0.46), (0.60, 0.56)]
        var cleared = 0
        for (nx, ny) in blemishCentres {
            // CGImage rows are top-down; the fixture used processing coords.
            let x = Int(nx * CGFloat(size))
            let y = Int((1 - ny) * CGFloat(size))
            guard let before = luminance(base, x: x, y: y),
                  let after = luminance(rendered, x: x, y: y),
                  let ringBefore = luminance(base, x: x + 18, y: y),
                  let ringAfter = luminance(rendered, x: x + 18, y: y) else { continue }
            // A spot is cleared when its contrast against nearby skin drops.
            let contrastBefore = abs(Double(ringBefore - before))
            let contrastAfter = abs(Double(ringAfter - after))
            if contrastAfter < contrastBefore * 0.5 { cleared += 1 }
        }

        // Clean-skin patch (no spot, no feature) must keep its texture.
        let cleanRect = CGRect(x: 262, y: 145, width: 46, height: 42)
        let cleanBefore = roughness(base, rect: cleanRect) ?? 0
        let cleanAfter = roughness(rendered, rect: cleanRect) ?? 0
        let textureKept = cleanBefore > 0 ? cleanAfter / cleanBefore : 0

        let spotsCleared = cleared >= 2
        let skinIntact = textureKept > 0.85
        print("  \(spotsCleared ? "✓" : "✗") spots cleared: \(cleared)/3 (expect >= 2)")
        print("  \(skinIntact ? "✓" : "✗") clean skin texture kept: \(String(format: "%.2f", textureKept))× (expect > 0.85)")
        return spotsCleared && skinIntact
    }

    /// A face-like patch: flat skin tone, subtle pore noise, three planted
    /// blemishes. Matches the fixture the gate thresholds were measured on.
    private static func makeSkinFixture(size: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let s = CGFloat(size)
        context.setFillColor(CGColor(red: 0.86, green: 0.72, blue: 0.64, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: s, height: s))

        var generator = SeededGenerator(seed: 0x5EED_17A5)
        for _ in 0..<(size * size / 6) {
            let x = CGFloat.random(in: s * 0.22...s * 0.78, using: &generator)
            let y = CGFloat.random(in: s * 0.30...s * 0.88, using: &generator)
            let v = Double.random(in: 0.80...0.94, using: &generator)
            context.setFillColor(CGColor(red: v, green: v * 0.9, blue: v * 0.85, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }

        context.setFillColor(CGColor(red: 0.55, green: 0.35, blue: 0.33, alpha: 1))
        for (sx, sy, r) in [(0.34, 0.62, 7.0), (0.46, 0.46, 8.0), (0.60, 0.56, 6.5)] {
            context.fillEllipse(in: CGRect(x: s * sx - r, y: s * sy - r, width: r * 2, height: r * 2))
        }
        return context.makeImage()
    }

    // MARK: - ۸) سفیدکردن دندان فقط وقتی دندان دیده می‌شود

    /// A closed mouth and an open one can share identical lip geometry, so the
    /// teeth flag has to come from pixels. This verifies both halves: the flag
    /// and the mask gate — and that whitening a closed mouth changes nothing.
    private static func checkTeethGating() -> Bool {
        let size = 400
        let extent = CGRect(x: 0, y: 0, width: size, height: size)
        let face = FaceGeometry.synthetic(
            boundingBox: CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.60),
            faceContour: [CGPoint(x: 0.20, y: 0.20), CGPoint(x: 0.80, y: 0.20),
                          CGPoint(x: 0.80, y: 0.80), CGPoint(x: 0.20, y: 0.80)],
            leftEye: [], rightEye: [], leftEyebrow: [], rightEyebrow: [],
            outerLips: [CGPoint(x: 0.40, y: 0.40), CGPoint(x: 0.60, y: 0.40),
                        CGPoint(x: 0.60, y: 0.52), CGPoint(x: 0.40, y: 0.52)],
            innerLips: [CGPoint(x: 0.44, y: 0.43), CGPoint(x: 0.56, y: 0.43),
                        CGPoint(x: 0.56, y: 0.49), CGPoint(x: 0.44, y: 0.49)],
            nose: [])

        guard let closed = makeMouthImage(size: size, showsTeeth: false),
              let open = makeMouthImage(size: size, showsTeeth: true),
              let closedBuffer = AutoAnalyzer.analysisBuffer(CIImage(cgImage: closed)),
              let openBuffer = AutoAnalyzer.analysisBuffer(CIImage(cgImage: open)) else {
            print("  ✗ could not build mouth fixtures")
            return false
        }

        let closedFaces = AutoAnalyzer.annotateTeeth(faces: [face], buffer: closedBuffer)
        let openFaces = AutoAnalyzer.annotateTeeth(faces: [face], buffer: openBuffer)
        let closedFraction = AutoAnalyzer.visibleTeethFraction(buffer: closedBuffer, face: face)
        let openFraction = AutoAnalyzer.visibleTeethFraction(buffer: openBuffer, face: face)

        let closedOK = !closedFaces[0].hasVisibleTeeth
        let openOK = openFaces[0].hasVisibleTeeth
        print("  \(closedOK ? "✓" : "✗") closed mouth: teeth fraction=\(String(format: "%.2f", closedFraction)) → not visible")
        print("  \(openOK ? "✓" : "✗") open smile: teeth fraction=\(String(format: "%.2f", openFraction)) → visible")

        let processor = ImageProcessor.shared
        guard let closedMask = processor.buildMasks(extent: extent, faces: closedFaces),
              let openMask = processor.buildMasks(extent: extent, faces: openFaces) else {
            print("  ✗ could not build masks")
            return false
        }
        let gateOK = closedMask.teeth == nil && openMask.teeth != nil
        print("  \(gateOK ? "✓" : "✗") teeth mask: closed=\(closedMask.teeth == nil ? "absent" : "present") open=\(openMask.teeth == nil ? "absent" : "present")")

        var adjustments = Adjustments()
        adjustments.teethWhiten = 100
        let output = processor.process(CIImage(cgImage: closed), adjustments: adjustments,
                                       masks: closedMask, faces: closedFaces)
        guard let rendered = processor.renderCGImage(output, scale: 1),
              let before = luminance(closed, x: 200, y: 200),
              let after = luminance(rendered, x: 200, y: 200) else {
            print("  ✗ could not process closed mouth")
            return false
        }
        let untouched = abs(after - before) <= 1
        print("  \(untouched ? "✓" : "✗") closed mouth unchanged by whitening: \(before) → \(after)")

        return closedOK && openOK && gateOK && untouched
    }

    /// Flat skin with a rectangular mouth. `showsTeeth` fills the inner mouth
    /// with bright neutral enamel; otherwise it is dark and saturated.
    private static func makeMouthImage(size: Int, showsTeeth: Bool) -> CGImage? {
        guard let context = CGContext(data: nil, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let s = CGFloat(size)
        context.setFillColor(CGColor(red: 0.82, green: 0.66, blue: 0.58, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: s, height: s))
        context.setFillColor(CGColor(red: 0.62, green: 0.30, blue: 0.30, alpha: 1))
        context.fill(CGRect(x: s * 0.40, y: s * 0.40, width: s * 0.20, height: s * 0.12))
        context.setFillColor(showsTeeth
                             ? CGColor(red: 0.93, green: 0.91, blue: 0.86, alpha: 1)
                             : CGColor(red: 0.32, green: 0.12, blue: 0.13, alpha: 1))
        context.fill(CGRect(x: s * 0.44, y: s * 0.43, width: s * 0.12, height: s * 0.06))
        return context.makeImage()
    }

    // MARK: - ۹) تفکیک فرکانسی واقعی

    /// A real base/detail split must reconstruct the input exactly: base plus
    /// (image - base) is the image. The old blend-based approach could not do
    /// this because signed detail was clamped. With retention 1 the error must
    /// be at the 8-bit rounding level, and lowering retention must remove fine
    /// texture.
    private static func checkFrequencySeparation() -> Bool {
        guard SkinEngine.isFrequencySeparationAvailable else {
            print("  ✗ frequency separation kernel unavailable")
            return false
        }
        let size = 400
        guard let base = makeNoisyImage(size: size) else {
            print("  ✗ could not build test image")
            return false
        }
        let extent = CGRect(x: 0, y: 0, width: size, height: size)
        let source = CIImage(cgImage: base).cropped(to: extent)
        let low = source.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3])
            .cropped(to: extent)

        let identity = SkinEngine.recombineFrequencies(source, base: low, retention: 1)
        let smoothed = SkinEngine.recombineFrequencies(source, base: low, retention: 0.2)

        guard let identityImage = ImageProcessor.shared.renderCGImage(identity, scale: 1),
              let smoothedImage = ImageProcessor.shared.renderCGImage(smoothed, scale: 1) else {
            print("  ✗ could not render")
            return false
        }

        let delta = meanAbsoluteDifference(base, identityImage) ?? 999
        let rect = CGRect(x: 150, y: 150, width: 100, height: 100)
        let before = roughness(base, rect: rect) ?? 0
        let after = roughness(smoothedImage, rect: rect) ?? 0

        let exact = delta < 1.0
        let reduced = after < before * 0.6
        print("  \(exact ? "✓" : "✗") round trip: mean |Δ| = \(String(format: "%.2f", delta))/255 (expect < 1)")
        print("  \(reduced ? "✓" : "✗") detail reduced: \(String(format: "%.1f", before)) → \(String(format: "%.1f", after)) (expect < 0.6×)")
        return exact && reduced
    }

    // MARK: - ۱۰) هیلینگ: لک برود، بافت بماند

    /// Healing must not leave a flat disc where a blemish was. Colour comes
    /// from the local median, texture from a donor patch, so the repaired area
    /// keeps roughly the same detail as nearby skin.
    private static func checkHealing() -> Bool {
        let size = 420
        guard let base = makeSkinFixture(size: size) else {
            print("  ✗ could not build skin fixture")
            return false
        }
        let extent = CGRect(x: 0, y: 0, width: size, height: size)
        let face = FaceGeometry.synthetic(
            boundingBox: CGRect(x: 0.18, y: 0.28, width: 0.64, height: 0.64),
            faceContour: [CGPoint(x: 0.18, y: 0.28), CGPoint(x: 0.82, y: 0.28),
                          CGPoint(x: 0.82, y: 0.92), CGPoint(x: 0.18, y: 0.92)],
            leftEye: [], rightEye: [], leftEyebrow: [], rightEyebrow: [],
            outerLips: [], innerLips: [], nose: [])

        let processor = ImageProcessor.shared
        let source = CIImage(cgImage: base).cropped(to: extent)
        guard let masks = processor.buildMasks(extent: extent, faces: [face], image: source) else {
            print("  ✗ could not build mask")
            return false
        }

        var adjustments = Adjustments()
        adjustments.blemish = 100
        let output = processor.process(source, adjustments: adjustments, masks: masks, faces: [face])
        guard let rendered = processor.renderCGImage(output, scale: 1) else {
            print("  ✗ processing failed")
            return false
        }

        let blemishCentres: [(CGFloat, CGFloat)] = [(0.34, 0.62), (0.46, 0.46), (0.60, 0.56)]
        var cleared = 0
        for (nx, ny) in blemishCentres {
            let x = Int(nx * CGFloat(size))
            let y = Int((1 - ny) * CGFloat(size))
            guard let before = luminance(base, x: x, y: y),
                  let after = luminance(rendered, x: x, y: y),
                  let ringBefore = luminance(base, x: x + 18, y: y),
                  let ringAfter = luminance(rendered, x: x + 18, y: y) else { continue }
            let contrastBefore = abs(Double(ringBefore - before))
            let contrastAfter = abs(Double(ringAfter - after))
            if contrastAfter < contrastBefore * 0.5 { cleared += 1 }
        }

        // The first blemish centre, and clean skin elsewhere on the face.
        let healedRect = CGRect(x: 136, y: 153, width: 14, height: 14)
        let cleanRect = CGRect(x: 100, y: 85, width: 14, height: 14)
        let healedTexture = roughness(rendered, rect: healedRect) ?? 0
        let cleanTexture = roughness(rendered, rect: cleanRect) ?? 0
        let textureRatio = cleanTexture > 0 ? healedTexture / cleanTexture : 0

        let spotsCleared = cleared >= 2
        let textureKept = textureRatio > 0.3
        print("  \(spotsCleared ? "✓" : "✗") spots cleared: \(cleared)/3 (expect >= 2)")
        print("  \(textureKept ? "✓" : "✗") healed patch texture: \(String(format: "%.1f", healedTexture)) vs clean skin \(String(format: "%.1f", cleanTexture)) (\(String(format: "%.2f", textureRatio))×, expect > 0.30)")
        return spotsCleared && textureKept
    }

    // MARK: - ۱۱) دروازه‌های پیکسلی مینا و چشم

    /// Enamel must not cover lips, sclera must not cover the iris, and
    /// brightening must therefore leave the iris alone.
    private static func checkEyeAndEnamelGates() -> Bool {
        let processor = ImageProcessor.shared
        let size = 400
        let extent = CGRect(x: 0, y: 0, width: size, height: size)
        var passed = true

        // --- Enamel ---
        let mouthFace = FaceGeometry.synthetic(
            boundingBox: CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.60),
            faceContour: [CGPoint(x: 0.20, y: 0.20), CGPoint(x: 0.80, y: 0.20),
                          CGPoint(x: 0.80, y: 0.80), CGPoint(x: 0.20, y: 0.80)],
            leftEye: [], rightEye: [], leftEyebrow: [], rightEyebrow: [],
            outerLips: [CGPoint(x: 0.40, y: 0.40), CGPoint(x: 0.60, y: 0.40),
                        CGPoint(x: 0.60, y: 0.52), CGPoint(x: 0.40, y: 0.52)],
            innerLips: [CGPoint(x: 0.44, y: 0.43), CGPoint(x: 0.56, y: 0.43),
                        CGPoint(x: 0.56, y: 0.49), CGPoint(x: 0.44, y: 0.49)],
            nose: [])
        guard let openImage = makeMouthImage(size: size, showsTeeth: true) else {
            print("  ✗ could not build mouth fixture")
            return false
        }
        let openCI = CIImage(cgImage: openImage).cropped(to: extent)
        guard let openBuffer = AutoAnalyzer.analysisBuffer(openCI) else {
            print("  ✗ could not build mouth buffer")
            return false
        }
        let mouthFaces = AutoAnalyzer.annotateTeeth(faces: [mouthFace], buffer: openBuffer)
        if let masks = processor.buildMasks(extent: extent, faces: mouthFaces, image: openCI),
           let teeth = masks.teeth,
           let teethImage = processor.renderCGImage(teeth, scale: 1) {
            let tooth = luminance(teethImage, x: 200, y: 216) ?? 0
            let lip = luminance(teethImage, x: 200, y: 234) ?? 255
            let enamelOK = tooth > 180 && lip < 20
            print("  \(enamelOK ? "✓" : "✗") enamel mask: tooth=\(tooth) lip=\(lip) (expect > 180 / < 20)")
            passed = enamelOK && passed
        } else {
            print("  ✗ could not build enamel mask")
            passed = false
        }

        // --- Eyes ---
        let eyeFace = FaceGeometry.synthetic(
            boundingBox: CGRect(x: 0.30, y: 0.45, width: 0.40, height: 0.30),
            faceContour: [CGPoint(x: 0.30, y: 0.45), CGPoint(x: 0.70, y: 0.45),
                          CGPoint(x: 0.70, y: 0.75), CGPoint(x: 0.30, y: 0.75)],
            leftEye: [CGPoint(x: 0.36, y: 0.52), CGPoint(x: 0.50, y: 0.52),
                      CGPoint(x: 0.50, y: 0.60), CGPoint(x: 0.36, y: 0.60)],
            rightEye: [], leftEyebrow: [], rightEyebrow: [],
            outerLips: [], innerLips: [], nose: [])
        guard let eyeImage = makeEyeImage(size: size) else {
            print("  ✗ could not build eye fixture")
            return false
        }
        let eyeCI = CIImage(cgImage: eyeImage).cropped(to: extent)
        guard let eyeBuffer = AutoAnalyzer.analysisBuffer(eyeCI) else {
            print("  ✗ could not build eye buffer")
            return false
        }
        let eyeFaces = AutoAnalyzer.annotateEyes(faces: [eyeFace], buffer: eyeBuffer)
        let split = eyeFaces[0].eyeScleraLuminance

        guard let masks = processor.buildMasks(extent: extent, faces: eyeFaces, image: eyeCI),
              let sclera = masks.sclera, let iris = masks.iris, masks.eyeDetail != nil,
              let scleraImage = processor.renderCGImage(sclera, scale: 1),
              let irisImage = processor.renderCGImage(iris, scale: 1) else {
            print("  ✗ could not build eye masks")
            return false
        }

        let scleraSample = luminance(scleraImage, x: 186, y: 176) ?? 0
        let scleraAtIris = luminance(scleraImage, x: 172, y: 176) ?? 255
        let irisSample = luminance(irisImage, x: 172, y: 176) ?? 0
        let irisAtSclera = luminance(irisImage, x: 186, y: 176) ?? 255

        let scleraOK = scleraSample > 200 && scleraAtIris < 40
        let irisOK = irisSample > 180 && irisAtSclera < 60
        print("  \(scleraOK ? "✓" : "✗") sclera mask: white=\(scleraSample) at iris=\(scleraAtIris) (split=\(String(format: "%.2f", split)))")
        print("  \(irisOK ? "✓" : "✗") iris mask: iris=\(irisSample) at sclera=\(irisAtSclera)")

        var adjustments = Adjustments()
        adjustments.eyeBrighten = 100
        let output = processor.process(eyeCI, adjustments: adjustments, masks: masks, faces: eyeFaces)
        guard let rendered = processor.renderCGImage(output, scale: 1),
              let whiteBefore = luminance(eyeImage, x: 186, y: 176),
              let whiteAfter = luminance(rendered, x: 186, y: 176),
              let irisBefore = luminance(eyeImage, x: 172, y: 176),
              let irisAfter = luminance(rendered, x: 172, y: 176) else {
            print("  ✗ could not process eye fixture")
            return false
        }
        let scleraBrightened = whiteAfter - whiteBefore > 12
        let irisIntact = abs(irisAfter - irisBefore) <= 6
        print("  \(scleraBrightened ? "✓" : "✗") sclera brightened: \(whiteBefore) → \(whiteAfter)")
        print("  \(irisIntact ? "✓" : "✗") iris untouched: \(irisBefore) → \(irisAfter)")

        return passed && scleraOK && irisOK && scleraBrightened && irisIntact
    }

    /// Kernels sample the linear working space, while every gate threshold is
    /// measured on 8-bit pixels. A mid neutral (sRGB 0.60) must clear a 0.45
    /// luma floor and a saturated lip red must fail the 0.30 saturation cap.
    /// Before the gate encoded back to sRGB, the neutral landed at 0.32 and
    /// only specular highlights passed — which is the bug this pins down.
    private static func checkColorGateSpace() -> Bool {
        let size = 200
        guard let fixture = makeGateFixture(size: size) else {
            print("  ✗ could not build gate fixture")
            return false
        }
        let ci = CIImage(cgImage: fixture)
        guard let gate = MaskBuilder.colorGate(ci, lumaMin: 0.45, saturationMax: 0.30),
              let rendered = ImageProcessor.shared.renderCGImage(gate, scale: 1),
              let neutral = luminance(rendered, x: 50, y: 50),
              let saturated = luminance(rendered, x: 150, y: 50) else {
            print("  ✗ could not render gate")
            return false
        }
        let ok = neutral > 200 && saturated < 30
        print("  \(ok ? "✓" : "✗") mid neutral (sRGB 0.60)=\(neutral) lip red=\(saturated) (expect > 200 / < 30)")
        return ok
    }

    /// Left half mid neutral, right half saturated lip red.
    private static func makeGateFixture(size: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let s = CGFloat(size)
        context.setFillColor(CGColor(red: 0.60, green: 0.60, blue: 0.60, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: s / 2, height: s))
        context.setFillColor(CGColor(red: 0.62, green: 0.30, blue: 0.30, alpha: 1))
        context.fill(CGRect(x: s / 2, y: 0, width: s / 2, height: s))
        return context.makeImage()
    }

    /// Flat skin with one eye: bright sclera, dark iris and a lash line.
    private static func makeEyeImage(size: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let s = CGFloat(size)
        context.setFillColor(CGColor(red: 0.82, green: 0.66, blue: 0.58, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: s, height: s))

        context.setFillColor(CGColor(red: 0.93, green: 0.94, blue: 0.93, alpha: 1))
        context.fillEllipse(in: CGRect(x: s * 0.36, y: s * 0.52, width: s * 0.14, height: s * 0.08))

        context.setFillColor(CGColor(red: 0.15, green: 0.18, blue: 0.25, alpha: 1))
        context.fillEllipse(in: CGRect(x: s * 0.40, y: s * 0.53, width: s * 0.06, height: s * 0.06))

        context.setFillColor(CGColor(red: 0.10, green: 0.09, blue: 0.09, alpha: 1))
        context.fill(CGRect(x: s * 0.37, y: s * 0.594, width: s * 0.12, height: s * 0.006))
        return context.makeImage()
    }

    // MARK: - ۱۲) خروجی ۱۶ بیتی و متادیتا

    private static func checkExportDepthAndMetadata(outDirectory: String) -> Bool {
        let size = 96
        guard let cg = makeGrayImage(size: size, spotCenter: CGPoint(x: 48, y: 48), spotSize: 10) else {
            print("  ✗ could not build test image")
            return false
        }
        let ci = CIImage(cgImage: cg)
        let directory = URL(fileURLWithPath: outDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let processor = ImageProcessor.shared

        let metadata: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 300,
            kCGImagePropertyDPIHeight: 300,
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Retouch SelfTest"]
        ]

        let pngURL = directory.appendingPathComponent("selftest-export-16.png")
        let tiffURL = directory.appendingPathComponent("selftest-export-16.tif")
        let jpegURL = directory.appendingPathComponent("selftest-export-8.jpg")
        let wrote = processor.write(ci, to: pngURL, format: .png, quality: 1, metadata: metadata)
            && processor.write(ci, to: tiffURL, format: .tiff, quality: 1, metadata: metadata)
            && processor.write(ci, to: jpegURL, format: .jpeg, quality: 0.9, metadata: metadata)

        func depth(_ url: URL) -> Int? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return image.bitsPerComponent
        }
        func properties(_ url: URL) -> [CFString: Any] {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
            return props
        }

        let pngDepth = depth(pngURL) ?? 0
        let tiffDepth = depth(tiffURL) ?? 0
        let jpegDepth = depth(jpegURL) ?? 0
        let tiffProps = properties(tiffURL)
        let dpi = (tiffProps[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 0
        let orientation = (tiffProps[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 0
        let tiff = tiffProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let artist = tiff[kCGImagePropertyTIFFArtist] as? String ?? ""

        let depthOK = pngDepth >= 16 && tiffDepth >= 16 && jpegDepth == 8
        let metadataOK = abs(dpi - 300) < 1 && orientation == 1 && artist == "Retouch SelfTest"
        let wroteOK = wrote
        print("  \(wroteOK ? "✓" : "✗") files written: png=\(pngDepth)-bit tiff=\(tiffDepth)-bit jpeg=\(jpegDepth)-bit (expect 16 / 16 / 8)")
        print("  \(metadataOK ? "✓" : "✗") metadata: dpi=\(Int(dpi)) orientation=\(orientation) artist=\(artist.isEmpty ? "missing" : artist)")
        return wroteOK && depthOK && metadataOK
    }

    // MARK: - ۱۳) تاریخچه‌ی واگرد

    /// The undo stack is pure model logic, so it can be exercised without a
    /// photo. The debounce is the part most likely to regress: a slider drag
    /// must undo as one step, and a pending change must not be skipped.
    private static func checkUndoHistory() -> Bool {
        MainActor.assumeIsolated {
            var ok = true
            let model = EditorModel()

            model.adjustments.smooth = 30
            model.undo()
            let pendingUndone = model.adjustments.smooth == 0 && model.canRedo
            print("  \(pendingUndone ? "✓" : "✗") pending drag undone: smooth=\(Int(model.adjustments.smooth)) canRedo=\(model.canRedo)")
            ok = pendingUndone && ok

            model.redo()
            let redone = model.adjustments.smooth == 30
            print("  \(redone ? "✓" : "✗") redo restores the drag: smooth=\(Int(model.adjustments.smooth))")
            ok = redone && ok

            model.commitAdjustments()
            model.adjustments.smooth = 60
            model.commitAdjustments()
            model.undo()
            let firstUndo = model.adjustments.smooth == 30
            model.undo()
            let secondUndo = model.adjustments.smooth == 0
            print("  \(firstUndo && secondUndo ? "✓" : "✗") settled edits step back one at a time: smooth=\(Int(model.adjustments.smooth)) after two undos")
            ok = firstUndo && secondUndo && ok

            model.redo()
            model.adjustments.smooth = 80
            let branchDropped = !model.canRedo
            print("  \(branchDropped ? "✓" : "✗") a new edit clears the redo branch")
            ok = branchDropped && ok

            let presetModel = EditorModel()
            presetModel.apply(Preset.all[0])
            presetModel.undo()
            let presetUndone = presetModel.adjustments == .zero
            print("  \(presetUndone ? "✓" : "✗") preset applies as one undo step")
            ok = presetUndone && ok

            return ok
        }
    }

    // MARK: - ۱۴) برش: هندسه، جهت و پروژه

    /// The crop rect is normalized with a TOP-LEFT origin, while Core Image and
    /// the face landmarks use a bottom-left origin. Mixing the two silently
    /// crops the wrong half of the photo, so both the math and a real load are
    /// checked here.
    private static func checkCropGeometry() -> Bool {
        var ok = true

        // A 3:4 portrait: the largest square crop is full width and 75% tall.
        let square = CropGeometry.aspectFit(1, imageAspect: 0.75, in: CropGeometry.full)
        let squareOK = abs(square.width - 1) < 0.001 && abs(square.height - 0.75) < 0.001
            && abs(square.midY - 0.5) < 0.001
        print("  \(squareOK ? "✓" : "✗") square inside 3:4: \(fmtCrop(square)) (expect 1.00 × 0.75, centered)")
        ok = squareOK && ok

        // Cropping an already-cropped frame stacks, it does not restart.
        let base = CGRect(x: 0.5, y: 0.25, width: 0.4, height: 0.5)
        let draft = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let composed = CropGeometry.composed(draft, over: base)
        let composedOK = abs(composed.minX - 0.7) < 0.001 && abs(composed.minY - 0.25) < 0.001
            && abs(composed.width - 0.2) < 0.001 && abs(composed.height - 0.5) < 0.001
        print("  \(composedOK ? "✓" : "✗") stacked crop: \(fmtCrop(composed)) (expect x=0.70 y=0.25 0.20 × 0.50)")
        ok = composedOK && ok

        let fullOK = CropGeometry.isFull(CropGeometry.full)
            && !CropGeometry.isFull(CGRect(x: 0, y: 0, width: 0.999, height: 1))
        print("  \(fullOK ? "✓" : "✗") a full-frame draft means no crop")
        return fullOK && ok
    }

    /// Writes a top-bright / bottom-dark fixture and loads two crops through the
    /// production entry point. The top crop must come back bright at half size,
    /// proving the top-left crop rect reaches the right pixels.
    private static func checkCropLoad(outDirectory: String) -> Bool {
        let directory = URL(fileURLWithPath: outDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("selftest-crop-source.png")

        guard let fixture = makeCropFixture(width: 200, height: 100) else {
            print("  ✗ could not build crop fixture")
            return false
        }
        let processor = ImageProcessor.shared
        guard processor.write(CIImage(cgImage: fixture), to: url, format: .png, quality: 1) else {
            print("  ✗ could not write crop fixture")
            return false
        }

        let top = processor.load(from: url, previewMaxDimension: 400,
                                 crop: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        let bottom = processor.load(from: url, previewMaxDimension: 400,
                                    crop: CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
        guard let top, let bottom else {
            print("  ✗ could not load crops")
            return false
        }

        let sizeOK = abs(top.pixelSize.width - 100) < 1 && abs(top.pixelSize.height - 50) < 1
        let topMean = meanLuminance(top.originalPreview) ?? 0
        let bottomMean = meanLuminance(bottom.originalPreview) ?? 0
        let orientationOK = topMean > 200 && bottomMean < 60
        print("  \(sizeOK ? "✓" : "✗") crop size: \(Int(top.pixelSize.width))×\(Int(top.pixelSize.height)) (expect 100×50)")
        print("  \(orientationOK ? "✓" : "✗") crop hits the top half: top=\(topMean) bottom=\(bottomMean) (expect bright / dark)")
        return sizeOK && orientationOK
    }

    private static func checkProjectRoundTrip() -> Bool {
        let crop = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)
        let spots = [HealSpot(center: CGPoint(x: 0.3, y: 0.7), radius: 0.02),
                     HealSpot(center: CGPoint(x: 0.8, y: 0.15), radius: 0.035)]
        var adjustments = Adjustments()
        adjustments.smooth = 42
        adjustments.blacks = 28
        adjustments.whites = 44
        adjustments.look = .nightStock
        adjustments.lookStrength = 65
        adjustments.grain = 30
        adjustments.lipTint = 60
        adjustments.lipColor = MakeupShade.berry.color
        adjustments.blush = 35
        adjustments.browDefine = 50
        adjustments.eyeshadow = 25
        adjustments.eyeliner = 15

        let project = RetouchProject(imagePath: "/tmp/photo.jpg",
                                     adjustments: adjustments,
                                     exportFormat: "jpeg",
                                     exportQuality: 0.9,
                                     autoRetouchStrength: 55,
                                     autoColorStrength: 65,
                                     crop: crop,
                                     healSpots: spots)
        guard let data = try? JSONEncoder().encode(project),
              let decoded = try? JSONDecoder().decode(RetouchProject.self, from: data) else {
            print("  ✗ could not encode/decode a project")
            return false
        }
        let roundTrip = decoded.crop == crop && decoded.adjustments == adjustments
            && decoded.healSpots == spots
            && decoded.autoColorStrength == 65

        // Projects written before crop existed have no `crop` key at all.
        var legacyObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        legacyObject.removeValue(forKey: "crop")
        legacyObject.removeValue(forKey: "healSpots")
        legacyObject.removeValue(forKey: "autoColorStrength")
        if var old = legacyObject["adjustments"] as? [String: Any] {
            old.removeValue(forKey: "blacks")
            old.removeValue(forKey: "whites")
            legacyObject["adjustments"] = old
        }
        let legacyData = try? JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = legacyData.flatMap { try? JSONDecoder().decode(RetouchProject.self, from: $0) }
        let legacyOK = legacy?.crop == nil && legacy?.healSpots == nil
            && legacy?.autoColorStrength == nil
            && legacy?.adjustments.blacks == 0 && legacy?.adjustments.whites == 0
            && legacy?.adjustments.smooth == 42

        print("  \(roundTrip ? "✓" : "✗") crop, stamps and sliders survive a project round-trip")
        print("  \(legacyOK ? "✓" : "✗") a project without a crop or levels key still opens")
        return roundTrip && legacyOK
    }

    /// Reopening a project must show the cropped pixels, and an export built from
    /// them must carry the same size and content: Save Project → reopen → Export.
    private static func checkCropProjectFlow(outDirectory: String) -> Bool {
        let directory = URL(fileURLWithPath: outDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("selftest-crop-flow-source.png")
        let exportURL = directory.appendingPathComponent("selftest-crop-flow-export.png")
        let processor = ImageProcessor.shared

        guard let fixture = makeCropFixture(width: 200, height: 100),
              processor.write(CIImage(cgImage: fixture), to: sourceURL, format: .png, quality: 1) else {
            print("  ✗ could not write the crop-flow fixture")
            return false
        }

        // Top-left origin, so y = 0.5 is the lower half — the dark half of the fixture.
        let project = RetouchProject(imagePath: sourceURL.path,
                                     adjustments: .zero,
                                     exportFormat: "png",
                                     exportQuality: 1,
                                     autoRetouchStrength: 50,
                                     crop: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
        guard let data = try? JSONEncoder().encode(project),
              let reopened = try? JSONDecoder().decode(RetouchProject.self, from: data) else {
            print("  ✗ could not encode/decode the crop-flow project")
            return false
        }
        guard let loaded = processor.load(from: URL(fileURLWithPath: reopened.imagePath),
                                          previewMaxDimension: 400,
                                          crop: reopened.crop) else {
            print("  ✗ could not reopen the cropped project")
            return false
        }
        let openedOK = abs(loaded.pixelSize.width - 100) < 1 && abs(loaded.pixelSize.height - 50) < 1
        print("  \(openedOK ? "✓" : "✗") reopened project is \(Int(loaded.pixelSize.width))×\(Int(loaded.pixelSize.height)) (expect 100×50)")

        let processed = processor.process(loaded.sourceFull, adjustments: reopened.adjustments,
                                          masks: loaded.masksFull, faces: loaded.faces)
        guard processor.write(processed, to: exportURL, format: .png, quality: 1,
                              colorSpace: loaded.colorSpace, metadata: loaded.metadata),
              let source = CGImageSourceCreateWithURL(exportURL as CFURL, nil),
              let exported = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            print("  ✗ could not export or read back the cropped project")
            return false
        }
        let exportSizeOK = exported.width == 100 && exported.height == 50
        // Threshold sits between the dark half (~31) and the bright half (~219).
        let exportedMean = meanLuminance(exported) ?? 255
        let contentOK = exportedMean < 90
        print("  \(exportSizeOK ? "✓" : "✗") export from the reopened crop: \(exported.width)×\(exported.height) (expect 100×50)")
        print("  \(contentOK ? "✓" : "✗") export holds the cropped half: mean=\(exportedMean) (expect dark)")
        return openedOK && exportSizeOK && contentOK
    }

    /// The brush has to heal where it was pointed. Stamps are stored with a
    /// top-left origin while masks are drawn in bottom-left space, so a stamp on
    /// the top of the photo must clear the top spot and leave a control spot at
    /// the bottom untouched. The crop mapping round trip is checked here too,
    /// because stamps are stored against the original photo, not the frame on
    /// screen.
    private static func checkManualHealing() -> Bool {
        let size = 240
        let processor = ImageProcessor.shared
        guard let base = makeTwoSpotFixture(size: size) else {
            print("  ✗ could not build the healing fixture")
            return false
        }
        let image = CIImage(cgImage: base)

        // Spot A is drawn at CG (60, 180): the buffer row is 240-180 = 60, so its
        // top-left normalized center is (0.25, 0.25). Spot B is the mirror image
        // of that and must not move.
        let stamp = HealSpot(center: CGPoint(x: 0.25, y: 0.25), radius: 0.04)
        guard let healing = processor.spotsMask(extent: image.extent, spots: [stamp]),
              let maskImage = processor.renderCGImage(healing.mask, scale: 1),
              let healedCG = processor.renderCGImage(
                  processor.process(image, adjustments: .zero, masks: nil, spots: healing),
                  scale: 1) else {
            print("  ✗ could not run the healing pass")
            return false
        }

        let maskTop = luminance(maskImage, x: 60, y: 60) ?? 0
        let maskBottom = luminance(maskImage, x: 180, y: 180) ?? 0
        let maskOK = maskTop > 200 && maskBottom < 30
        print("  \(maskOK ? "✓" : "✗") stamp lands where it was clicked: mask top=\(maskTop) bottom=\(maskBottom)")

        let beforeA = luminance(base, x: 60, y: 60) ?? 255
        let afterA = luminance(healedCG, x: 60, y: 60) ?? 0
        let beforeB = luminance(base, x: 180, y: 180) ?? 0
        let afterB = luminance(healedCG, x: 180, y: 180) ?? 255
        let clearedOK = beforeA < 70 && abs(afterA - 128) < 45
        let untouchedOK = abs(beforeB - afterB) <= 1
        print("  \(clearedOK ? "✓" : "✗") stamped spot healed: \(beforeA) → \(afterA) (expect dark → near 128)")
        print("  \(untouchedOK ? "✓" : "✗") unstamped spot untouched: \(beforeB) → \(afterB)")

        // Healing borrows neighbouring texture. A flat median patch would leave
        // the stamped disc far smoother than clean skin beside it.
        let healedTexture = roughness(healedCG, rect: CGRect(x: 48, y: 48, width: 26, height: 26)) ?? 0
        let cleanTexture = roughness(healedCG, rect: CGRect(x: 96, y: 96, width: 26, height: 26)) ?? 0
        let textureOK = cleanTexture > 0 && healedTexture > cleanTexture * 0.35
        print("  \(textureOK ? "✓" : "✗") texture survives the patch: healed=\(healedTexture) clean=\(cleanTexture)")

        // A crop moves a stamp onto the new frame and back without drift, and a
        // stamp outside the crop stops existing on screen.
        let crop = CGRect(x: 0.2, y: 0.1, width: 0.5, height: 0.4)
        guard let mapped = HealGeometry.workingSpots([stamp], crop: crop).first else {
            print("  ✗ the stamp was dropped by a crop that contains it")
            return false
        }
        let back = HealSpot(center: HealGeometry.originalCenter(mapped.center, crop: crop),
                            radius: HealGeometry.originalRadius(mapped.radius, crop: crop))
        let roundTripOK = abs(back.center.x - stamp.center.x) < 0.0001
            && abs(back.center.y - stamp.center.y) < 0.0001
            && abs(back.radius - stamp.radius) < 0.0001
        print("  \(roundTripOK ? "✓" : "✗") stamp survives a crop round trip: \(fmtPoint(back.center)) r=\(String(format: "%.4f", back.radius))")

        let outside = HealSpot(center: CGPoint(x: 0.9, y: 0.9), radius: 0.02)
        let droppedOK = HealGeometry.workingSpots([outside], crop: crop).isEmpty
        print("  \(droppedOK ? "✓" : "✗") a stamp outside the crop leaves the frame")

        return maskOK && clearedOK && untouchedOK && textureOK && roundTripOK && droppedOK
    }

    // MARK: - Looks: colour cube and grain

    /// Bottom-to-top grey ramp, drawn in CG space so y = 0 is black.
    private static func makeRampImage(size: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for y in 0..<size {
            let v = CGFloat(y) / CGFloat(size - 1)
            context.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 1))
            context.fill(CGRect(x: 0, y: y, width: size, height: 1))
        }
        return context.makeImage()
    }

    /// Mean difference between horizontally adjacent pixels. A smooth picture —
    /// a ramp, a defocused sky — scores near zero no matter how bright it is,
    /// so this is what separates real texture from an overall tone shift.
    private static func adjacentVariation(_ image: CGImage) -> Double {
        guard image.width > 1,
              let data = image.dataProvider?.data, let pointer = CFDataGetBytePtr(data) else { return -1 }
        let bpp = max(1, image.bitsPerPixel / 8), bpr = image.bytesPerRow
        let count = CFDataGetLength(data)
        var total = 0.0, samples = 0.0
        var y = 0
        while y < image.height {
            var x = 0
            while x + 1 < image.width {
                let left = y * bpr + x * bpp, right = y * bpr + (x + 1) * bpp
                if right + 2 < count {
                    let a = Double(Int(pointer[left]) + Int(pointer[left + 1]) + Int(pointer[left + 2])) / 3.0
                    let b = Double(Int(pointer[right]) + Int(pointer[right + 1]) + Int(pointer[right + 2])) / 3.0
                    total += abs(a - b)
                    samples += 1
                }
                x += 2
            }
            y += 2
        }
        guard samples > 0 else { return -1 }
        return total / samples
    }

    /// The darker of the two ends of the ramp fixture, which is where a matte
    /// lift shows up. Sampling both ends means the check does not depend on
    /// which way round Core Image hands the bitmap back.
    private static func rampFloor(_ image: CGImage) -> Double {
        guard let data = image.dataProvider?.data, let pointer = CFDataGetBytePtr(data) else { return -1 }
        let bpr = image.bytesPerRow, mid = image.width / 2
        func row(_ y: Int) -> Double {
            let i = y * bpr + mid * max(1, image.bitsPerPixel / 8)
            return Double(Int(pointer[i]) + Int(pointer[i + 1]) + Int(pointer[i + 2])) / 3.0
        }
        guard image.height > 1 else { return -1 }
        return min(row(0), row(image.height - 1))
    }

    private static func checkLooksAndGrain() -> Bool {
        var passed = true
        guard let ramp = makeRampImage(size: 128) else {
            print("  ✗ could not build the ramp fixture")
            return false
        }
        let processor = ImageProcessor.shared
        let source = CIImage(cgImage: ramp)
        let extent = source.extent
        func render(_ image: CIImage) -> CGImage? { processor.context.createCGImage(image, from: extent) }
        func delta(_ a: CGImage, _ b: CGImage) -> Double { meanAbsoluteDifference(a, b) ?? -1 }

        let baseline = render(source) ?? ramp

        // 1) A look has to be a genuine no-op before it is dialled in.
        let untouched = LookEngine.applyLook(source, look: .crossProcess, strength: 0)
        let noLook = LookEngine.applyLook(source, look: .none, strength: 1)
        let zeroD = delta(baseline, render(untouched) ?? baseline)
        let noneD = delta(baseline, render(noLook) ?? baseline)
        let noopOK = zeroD == 0 && noneD == 0
        print("  \(noopOK ? "✓" : "✗") zero strength and \"None\" change nothing: Δ=\(zeroD) / \(noneD) (expect 0)")
        passed = noopOK && passed

        // 2) Every named look has to actually move the pixels, and the strength
        //    slider has to blend monotonically toward it.
        for look in FilmLook.allCases where look != .none {
            let quarter = delta(baseline, render(LookEngine.applyLook(source, look: look, strength: 0.25)) ?? baseline)
            let full = delta(baseline, render(LookEngine.applyLook(source, look: look, strength: 1)) ?? baseline)
            let ok = full > 0.5 && quarter > 0 && quarter < full
            print("  \(ok ? "✓" : "✗") \(look.title): quarter Δ=\(String(format: "%.2f", quarter)) < full Δ=\(String(format: "%.2f", full))")
            passed = ok && passed
        }

        // 3) A matte grade lifts the black floor; the highlights stay put.
        let matte = render(LookEngine.applyLook(source, look: .fadedMatte, strength: 1)) ?? baseline
        let matteFloor = rampFloor(matte)
        let baseFloor = rampFloor(baseline)
        let liftOK = matteFloor > baseFloor + 15
        print("  \(liftOK ? "✓" : "✗") Faded Matte lifts the black floor: \(String(format: "%.1f", baseFloor)) → \(String(format: "%.1f", matteFloor))")
        passed = liftOK && passed

        // 4) Grain has to add texture, not tone: adjacent pixels start to
        //    differ while the picture underneath keeps its shape.
        let cleanTexture = adjacentVariation(baseline)
        let grainy = render(LookEngine.addGrain(source, amount: 0.6, extent: extent)) ?? baseline
        let grainyTexture = adjacentVariation(grainy)
        let grainyMean = meanLuminance(grainy) ?? -1
        let baseMean = meanLuminance(baseline) ?? -1
        // Grain is multiplied in linear light, so it costs a little density —
        // a faded print does the same. What must not happen is the picture
        // changing shape while it darkens.
        let grainOK = grainyTexture > max(6, cleanTexture + 6) && abs(grainyMean - baseMean) < 10
        print("  \(grainOK ? "✓" : "✗") grain adds texture: adjacent Δ \(String(format: "%.2f", cleanTexture)) → "
            + "\(String(format: "%.2f", grainyTexture)), mean \(baseMean) → \(grainyMean)")
        let deeper = render(LookEngine.addGrain(source, amount: 1, extent: extent)) ?? baseline
        let monotonicOK = adjacentVariation(deeper) > grainyTexture
        print("  \(monotonicOK ? "✓" : "✗") more grain is coarser: \(String(format: "%.2f", grainyTexture)) → \(String(format: "%.2f", adjacentVariation(deeper)))")
        let noGrain = delta(baseline, render(LookEngine.addGrain(source, amount: 0, extent: extent)) ?? baseline)
        let grainNoopOK = noGrain == 0
        print("  \(grainNoopOK ? "✓" : "✗") grain at zero changes nothing: Δ=\(noGrain)")
        passed = grainOK && monotonicOK && grainNoopOK && passed

        // 5) The grade and the grain have to reach the real pipeline, not just
        //    the engine helpers.
        var graded = Adjustments()
        graded.look = .nightStock
        graded.lookStrength = 100
        var grainOnly = Adjustments()
        grainOnly.grain = 70
        let throughPipeline = delta(baseline, render(processor.process(source, adjustments: graded, masks: nil)) ?? baseline)
        let grainThroughPipeline = delta(baseline, render(processor.process(source, adjustments: grainOnly, masks: nil)) ?? baseline)
        let pipelineOK = throughPipeline > 1 && grainThroughPipeline > 0.3
        print("  \(pipelineOK ? "✓" : "✗") process() applies them: look Δ=\(String(format: "%.2f", throughPipeline)), "
            + "grain Δ=\(String(format: "%.2f", grainThroughPipeline))")
        passed = pipelineOK && passed

        // 6) Group isolation: clearing the look must leave the sliders alone and
        //    vice versa.
        var mixed = Adjustments(smooth: 40, exposure: 20)
        mixed.look = .warmGold
        mixed.lookStrength = 80
        mixed.grain = 45
        let lookCleared = mixed.applyingLook(Adjustments().lookOnly)
        let otherCleared = mixed.applyingRetouch(Adjustments().retouchOnly)
            .applyingColorLight(Adjustments().colorLightOnly)
        let isolationOK = lookCleared.lookStrength == 0 && lookCleared.grain == 0
            && lookCleared.smooth == 40 && lookCleared.exposure == 20
            && otherCleared.smooth == 0 && otherCleared.exposure == 0
            && otherCleared.lookStrength == 80 && otherCleared.grain == 45
        print("  \(isolationOK ? "✓" : "✗") clearing a look keeps the sliders, and the reverse")
        passed = isolationOK && passed

        // 7) An older project file has no look keys at all.
        var legacyObject: [String: Any] = ["smooth": 30.0, "blemish": 12.0]
        legacyObject["faceWidth"] = nil
        let legacyData = try? JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = legacyData.flatMap { try? JSONDecoder().decode(Adjustments.self, from: $0) }
        let legacyOK = legacy?.smooth == 30 && legacy?.lookID == "" && legacy?.lookStrength == 0 && legacy?.grain == 0
        print("  \(legacyOK ? "✓" : "✗") adjustments without look keys still decode")
        passed = legacyOK && passed

        return passed
    }

    // MARK: - Makeup

    /// Cosmetics have to colour the feature they are named for, keep the
    /// shading that makes it look three-dimensional, and leave the rest of the
    /// photo bit-for-bit alone.
    private static func checkMakeup() -> Bool {
        var passed = true
        let size = 400
        let extent = CGRect(x: 0, y: 0, width: size, height: size)
        let face = makeupFace()
        let processor = ImageProcessor.shared
        guard let fixture = makeMakeupFixture(size: size),
              let masks = processor.buildMasks(extent: extent, faces: [face]) else {
            print("  ✗ could not build the makeup fixture or masks")
            return false
        }
        let source = CIImage(cgImage: fixture)
        func output(_ a: Adjustments) -> CGImage {
            processor.renderCGImage(processor.process(source, adjustments: a, masks: masks, faces: [face]),
                                    scale: 1) ?? fixture
        }
        let baseline = output(Adjustments())

        // 1) The masks makeup needs. The brow band is the risky one: Vision
        //    traces a thin outline, so without the widening the colour would
        //    sit on a line instead of on the brow.
        let browBox = FaceGeometry.boundingBox(of: face.leftEyebrow)
        var maskChecks: [Double] = []
        if let browMask = masks.brows, let rendered = processor.renderCGImage(browMask, scale: 1) {
            maskChecks.append(maskCoverage(rendered, normalized: browBox))
        } else {
            print("  ✗ no brow mask")
            passed = false
        }
        if let cheekMask = masks.cheeks, let rendered = processor.renderCGImage(cheekMask, scale: 1) {
            maskChecks.append(maskCoverage(rendered, normalized: face.leftBlushRect))
        } else {
            print("  ✗ no cheek mask")
            passed = false
        }
        let lipsOK = masks.lips != nil
        let coverageOK = maskChecks.allSatisfy { $0 > 0.55 } && lipsOK
        let coverageText = maskChecks.map { String(format: "%.2f", $0) }.joined(separator: ", ")
        print("  \(coverageOK ? "✓" : "✗") masks cover their features (brow, cheek coverage: \(coverageText))")
        passed = coverageOK && passed

        // The eye regions are thin bands, so they are measured on their own
        // scale: a lid is a strip of skin, and a lash line is a line.
        let lidRect = face.eyelidRects.first ?? .zero
        let lashRect = face.lashLineRects.first ?? .zero
        let lidCoverage = masks.lids.flatMap { processor.renderCGImage($0, scale: 1) }
            .map { maskCoverage($0, normalized: lidRect) } ?? -1
        let lashCoverage = masks.liners.flatMap { processor.renderCGImage($0, scale: 1) }
            .map { maskCoverage($0, normalized: lashRect) } ?? -1
        let eyeMasksOK = lidCoverage > 0.45 && lashCoverage > 0.25
        print("  \(eyeMasksOK ? "✓" : "✗") eyelid and lash-line masks (coverage: \(String(format: "%.2f", lidCoverage)), \(String(format: "%.2f", lashCoverage)))")
        passed = eyeMasksOK && passed

        // 2) Untouched, makeup is nothing at all.
        let idle = output(Adjustments(lipColor: MakeupShade.berry.color))
        let idleDelta = meanColorDifference(baseline, idle, normalized: CGRect(x: 0, y: 0, width: 1, height: 1))
        let idleOK = idleDelta == 0
        print("  \(idleOK ? "✓" : "✗") a colour with no amount changes nothing: Δ=\(String(format: "%.2f", idleDelta))")
        passed = idleOK && passed

        // 3) Lip colour lands on the lips and nowhere else, and grows with the
        //    slider.
        var lip = Adjustments()
        lip.lipTint = 100
        var halfLip = Adjustments()
        halfLip.lipTint = 50
        let lipResult = output(lip)
        let lipDelta = meanColorDifference(baseline, lipResult, normalized: face.lipRect ?? .zero)
        let halfLipDelta = meanColorDifference(baseline, output(halfLip), normalized: face.lipRect ?? .zero)
        let lipOK = lipDelta > 8 && halfLipDelta > 1 && halfLipDelta < lipDelta
        print("  \(lipOK ? "✓" : "✗") lips take the colour: Δ=\(String(format: "%.1f", halfLipDelta)) at 50, \(String(format: "%.1f", lipDelta)) at 100")
        passed = lipOK && passed

        let elsewhere = [mid(face.foreheadRect), mid(FaceGeometry.boundingBox(of: face.leftEyebrow))]
        let spill = elsewhere.map { sampleDelta(baseline, lipResult, at: $0) }
        let containedOK = spill.allSatisfy { $0 <= 1 }
        print("  \(containedOK ? "✓" : "✗") lip colour stays off the forehead and brows: Δ=\(spill.map { String(format: "%.1f", $0) }.joined(separator: ", "))")
        passed = containedOK && passed

        // 4) The lips must not become a flat sticker: the strip pattern drawn
        //    into the fixture has to survive.
        let before = lipStripRange(baseline, face: face, size: size)
        let after = lipStripRange(lipResult, face: face, size: size)
        let shadingOK = before > 20 && after > before * 0.5
        print("  \(shadingOK ? "✓" : "✗") lip shading survives the colour: range \(String(format: "%.0f", before)) → \(String(format: "%.0f", after))")
        passed = shadingOK && passed

        // 5) Blush flushes the cheeks only.
        var blush = Adjustments()
        blush.blush = 100
        let blushResult = output(blush)
        let cheekDelta = max(meanColorDifference(baseline, blushResult, normalized: face.leftBlushRect),
                             meanColorDifference(baseline, blushResult, normalized: face.rightBlushRect))
        let blushFar = sampleDelta(baseline, blushResult, at: mid(face.foreheadRect))
        let blushLips = sampleDelta(baseline, blushResult, at: face.lipRect.map(mid) ?? .zero)
        let blushOK = cheekDelta > 2 && blushFar <= 1 && blushLips <= 1
        print("  \(blushOK ? "✓" : "✗") blush on the cheeks: Δ=\(String(format: "%.1f", cheekDelta)); forehead \(String(format: "%.1f", blushFar)), lips \(String(format: "%.1f", blushLips))")
        passed = blushOK && passed

        // 6) Brows get denser, not painted.
        var brow = Adjustments()
        brow.browDefine = 100
        let browResult = output(brow)
        let browLift = regionMeanLuminance(baseline, normalized: browBox)
            - regionMeanLuminance(browResult, normalized: browBox)
        let browFar = sampleDelta(baseline, browResult, at: mid(face.foreheadRect))
        let browOK = browLift > 1 && browFar <= 1
        print("  \(browOK ? "✓" : "✗") brows darken: −\(String(format: "%.1f", browLift)) levels inside, Δ=\(String(format: "%.1f", browFar)) on the forehead")
        passed = browOK && passed

        // 7) Eyeshadow colours the lid band and stops there.
        var shadow = Adjustments()
        shadow.eyeshadow = 100
        shadow.shadowColor = MakeupShade.plumShadow.color
        let shadowResult = output(shadow)
        let lidDelta = meanColorDifference(baseline, shadowResult, normalized: lidRect)
        let shadowLips = sampleDelta(baseline, shadowResult, at: face.lipRect.map(mid) ?? .zero)
        let shadowOK = lidDelta > 2 && shadowLips <= 1
        print("  \(shadowOK ? "✓" : "✗") eyeshadow on the lid: Δ=\(String(format: "%.1f", lidDelta)); lips \(String(format: "%.1f", shadowLips))")
        passed = shadowOK && passed

        // 8) Eyeliner darkens the lash line and nothing else.
        var liner = Adjustments()
        liner.eyeliner = 100
        let linerResult = output(liner)
        let lashDrop = regionMeanLuminance(baseline, normalized: lashRect)
            - regionMeanLuminance(linerResult, normalized: lashRect)
        let linerFar = sampleDelta(baseline, linerResult, at: mid(face.foreheadRect))
        let linerOK = lashDrop > 1 && linerFar <= 1
        print("  \(linerOK ? "✓" : "✗") eyeliner darkens the lash line: −\(String(format: "%.1f", lashDrop)) levels inside, Δ=\(String(format: "%.1f", linerFar)) on the forehead")
        passed = linerOK && passed

        // 9) The colours have to be different colours, not one colour at
        //    different strengths. Rose is redder than berry, which carries blue.
        var berry = Adjustments()
        berry.lipTint = 100
        berry.lipColor = MakeupShade.berry.color
        var rose = Adjustments()
        rose.lipTint = 100
        rose.lipColor = MakeupShade.rose.color
        let roseRed = redMinusBlue(rose, face: face, from: output)
        let berryRed = redMinusBlue(berry, face: face, from: output)
        let shadeOK = roseRed != nil && berryRed != nil
            && roseRed! > berryRed! + 2
        print("  \(shadeOK ? "✓" : "✗") rose vs berry on the lips: red−blue \(String(format: "%.1f", roseRed ?? -999)) vs \(String(format: "%.1f", berryRed ?? -999))")
        passed = shadeOK && passed

        // 10) Hue and saturation are real controls, not decoration: the same
        //     amount with a different hue has to render a different lip.
        var warm = Adjustments()
        warm.lipTint = 100
        warm.lipColor = MakeupColor(hue: 30, saturation: 0.7, value: 0.8)
        var cool = Adjustments()
        cool.lipTint = 100
        cool.lipColor = MakeupColor(hue: 210, saturation: 0.7, value: 0.8)
        let warmRed = redMinusBlue(warm, face: face, from: output) ?? 0
        let coolRed = redMinusBlue(cool, face: face, from: output) ?? 0
        var grey = Adjustments()
        grey.lipTint = 100
        grey.lipColor = MakeupColor(hue: 30, saturation: 0, value: 0.8)
        let greyRed = redMinusBlue(grey, face: face, from: output) ?? 999
        // The blend always keeps a little of the lip's own colour, so a grey
        // pigment still reads slightly warm — it must be far less warm than a
        // fully saturated one, not neutral to the last digit.
        let hueOK = warmRed > coolRed + 10 && greyRed < warmRed - 20
        print("  \(hueOK ? "✓" : "✗") hue and saturation move the lip: red−blue \(String(format: "%.1f", warmRed)) warm, \(String(format: "%.1f", coolRed)) cool, \(String(format: "%.1f", greyRed)) at zero saturation")
        passed = hueOK && passed

        // 11) The catalogue itself: every region stocked, every family stocked,
        //     no duplicate identifiers or colours.
        let ids = Set(MakeupShade.all.map(\.id))
        let colours = Set(MakeupShade.all.map { "\($0.color.hue)/\($0.color.saturation)/\($0.color.value)" })
        let familiesStocked = MakeupFamily.allCases.allSatisfy {
            MakeupShade.shades(.lips, family: $0).count >= 3
                && MakeupShade.shades(.cheeks, family: $0).count >= 3
        }
        let regionsStocked = MakeupRegion.allCases.allSatisfy { MakeupShade.shades($0).count >= 4 }
        let paletteOK = ids.count == MakeupShade.all.count
            && colours.count == MakeupShade.all.count
            && familiesStocked && regionsStocked
        print("  \(paletteOK ? "✓" : "✗") palette: \(MakeupShade.all.count) shades, every family and region stocked, no duplicates")
        passed = paletteOK && passed

        // 12) Makeup is its own group: clearing it keeps everything else, and
        //     clearing the others keeps it.
        var mixed = Adjustments(smooth: 40, exposure: 20)
        mixed.look = .warmGold
        mixed.lookStrength = 80
        mixed.lipTint = 60
        mixed.browDefine = 30
        mixed.eyeliner = 20
        let makeupCleared = mixed.applyingMakeup(Adjustments().makeupOnly)
        let othersCleared = mixed.applyingRetouch(Adjustments().retouchOnly)
            .applyingColorLight(Adjustments().colorLightOnly)
            .applyingLook(Adjustments().lookOnly)
        let groupOK = makeupCleared.lipTint == 0 && makeupCleared.browDefine == 0
            && makeupCleared.eyeliner == 0
            && makeupCleared.smooth == 40 && makeupCleared.exposure == 20
            && makeupCleared.lookStrength == 80
            && othersCleared.lipTint == 60 && othersCleared.browDefine == 30
            && othersCleared.eyeliner == 20
            && othersCleared.smooth == 0 && othersCleared.lookStrength == 0
        print("  \(groupOK ? "✓" : "✗") makeup resets as one group, alone")
        passed = groupOK && passed

        // 13) A project file from before the picker names a shade instead of a
        //     colour, and has no eye makeup at all.
        let legacyJSON = """
        {"smooth": 30.0, "blemish": 12.0, "lipShadeID": "berry", "blushShadeID": "rose"}
        """
        let legacy = legacyJSON.data(using: .utf8).flatMap {
            try? JSONDecoder().decode(Adjustments.self, from: $0)
        }
        let legacyOK = legacy?.lipTint == 0 && legacy?.blush == 0 && legacy?.browDefine == 0
            && legacy?.eyeshadow == 0 && legacy?.eyeliner == 0
            && legacy?.lipColor == MakeupShade.berry.color
            && legacy?.blushColor == MakeupShade.rose.color
        print("  \(legacyOK ? "✓" : "✗") a project with shade names migrates to colours")
        passed = legacyOK && passed

        return passed
    }

    /// Mean red-minus-blue across the lips for a given makeup state.
    private static func redMinusBlue(_ a: Adjustments,
                                     face: FaceGeometry,
                                     from output: (Adjustments) -> CGImage) -> Double? {
        guard let rect = face.lipRect, let channels = meanChannels(output(a), normalized: rect) else { return nil }
        return Double(channels.r - channels.b)
    }

    /// Brightness range across the lip strips, used to prove the colour keeps
    /// the shading rather than laying a flat sticker over it.
    private static func lipStripRange(_ image: CGImage, face: FaceGeometry, size: Int) -> Double {
        guard let rect = face.lipRect else { return 0 }
        var values: [Double] = []
        for step in 0..<9 {
            let x = rect.minX + rect.width * (CGFloat(step) + 0.5) / 9
            if let value = luminance(image, normalizedAt: CGPoint(x: x, y: rect.midY)) {
                values.append(Double(value))
            }
        }
        guard let maxV = values.max(), let minV = values.min() else { return 0 }
        return maxV - minV
    }

    /// A face with the regions makeup works on, sized so the derived cheek and
    /// blush rects land clear of the lips and the nose.
    private static func makeupFace() -> FaceGeometry {
        func box(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> [CGPoint] {
            [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0),
             CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1)]
        }
        return FaceGeometry.synthetic(
            boundingBox: CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.60),
            faceContour: box(0.20, 0.20, 0.80, 0.80),
            leftEye: box(0.35, 0.55, 0.45, 0.60),
            rightEye: box(0.55, 0.55, 0.65, 0.60),
            leftEyebrow: box(0.34, 0.63, 0.46, 0.655),
            rightEyebrow: box(0.54, 0.63, 0.66, 0.655),
            outerLips: box(0.42, 0.32, 0.58, 0.42),
            innerLips: [],
            nose: box(0.47, 0.44, 0.53, 0.54))
    }

    /// Skin-toned canvas with a striped mouth and two dark brows. CG draws from
    /// the bottom left, the same origin the geometry uses.
    private static func makeMakeupFixture(size: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let s = CGFloat(size)
        context.setFillColor(CGColor(red: 0.82, green: 0.66, blue: 0.58, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: s, height: s))

        // Eight strips across the lips, bright to dark: the shading a colour
        // layer has to preserve.
        let strips = 8
        let stripWidth = s * 0.16 / CGFloat(strips)
        for index in 0..<strips {
            let factor = 0.55 + 0.50 * Double(index) / Double(strips - 1)
            context.setFillColor(CGColor(red: 0.62 * factor, green: 0.28 * factor,
                                         blue: 0.28 * factor, alpha: 1))
            context.fill(CGRect(x: s * 0.42 + CGFloat(index) * stripWidth, y: s * 0.32,
                                width: stripWidth + 1, height: s * 0.10))
        }

        context.setFillColor(CGColor(red: 0.26, green: 0.19, blue: 0.14, alpha: 1))
        context.fill(CGRect(x: s * 0.34, y: s * 0.63, width: s * 0.12, height: s * 0.025))
        context.fill(CGRect(x: s * 0.54, y: s * 0.63, width: s * 0.12, height: s * 0.025))
        return context.makeImage()
    }

    private static func fmtPoint(_ point: CGPoint) -> String {
        String(format: "(%.2f, %.2f)", point.x, point.y)
    }

    /// Flat gray skin with fine grain and two dark spots, one in the top-left
    /// quadrant and one in the bottom-right, drawn in CG (bottom-left) space.
    private static func makeTwoSpotFixture(size: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 128 / 255, green: 128 / 255, blue: 128 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))

        var generator = SeededGenerator(seed: 0x5EED_17A5)
        for _ in 0..<(size * size / 8) {
            let x = Int.random(in: 0..<size, using: &generator)
            let y = Int.random(in: 0..<size, using: &generator)
            let v = Double.random(in: 0.35...1.0, using: &generator)
            context.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }

        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 55, y: 175, width: 10, height: 10))
        context.fill(CGRect(x: 175, y: 55, width: 10, height: 10))
        return context.makeImage()
    }

    private static func fmtCrop(_ rect: CGRect) -> String {
        String(format: "x=%.2f y=%.2f %.2f × %.2f", rect.minX, rect.minY, rect.width, rect.height)
    }

    /// «زبری» یک ناحیه: میانگین اختلاف روشنایی هر پیکسل با همسایه‌ی راست و بالایش.
    /// عدد بزرگ‌تر = بافت/جزئیات بیشتر. برای سنجش اثر صافی پوست استفاده می‌شود.
    private static func roughness(_ image: CGImage, rect: CGRect) -> Double? {
        guard let data = image.dataProvider?.data, let pointer = CFDataGetBytePtr(data) else { return nil }
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        let count = CFDataGetLength(data)

        func value(_ x: Int, _ y: Int) -> Double? {
            guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
            let index = y * image.bytesPerRow + x * bytesPerPixel
            guard index + 2 < count else { return nil }
            return Double(Int(pointer[index]) + Int(pointer[index + 1]) + Int(pointer[index + 2])) / 3.0
        }

        var total = 0.0
        var samples = 0.0
        let x0 = max(0, Int(rect.minX)), x1 = min(image.width - 1, Int(rect.maxX))
        let y0 = max(0, Int(rect.minY)), y1 = min(image.height - 1, Int(rect.maxY))
        guard x1 > x0, y1 > y0 else { return nil }
        for y in y0..<y1 {
            for x in x0..<x1 {
                guard let c = value(x, y), let r = value(x + 1, y), let u = value(x, y + 1) else { continue }
                total += abs(c - r) + abs(c - u)
                samples += 2
            }
        }
        guard samples > 0 else { return nil }
        return total / samples
    }

    /// Fixtures must draw the same noise every run. With the system generator
    /// the healing check failed on roughly one build in ten, because a random
    /// scatter occasionally left the sample point sitting on a bright grain
    /// cluster instead of on the median the patch was measured against.
    struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static func makeNoisyImage(size: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.72, green: 0.62, blue: 0.55, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))

        // نویز ریز و پرکنتراست = شبیه‌سازی بافت پوست و منافذ.
        var generator = SeededGenerator(seed: 0x5EED_17A5)
        for _ in 0..<(size * size / 3) {
            let x = Int.random(in: 0..<size, using: &generator)
            let y = Int.random(in: 0..<size, using: &generator)
            let v = Double.random(in: 0.35...1.0, using: &generator)
            context.setFillColor(CGColor(red: v, green: v * 0.86, blue: v * 0.76, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
        return context.makeImage()
    }

    private static func luminance(_ image: CGImage, x: Int, y: Int) -> Int? {
        guard let data = image.dataProvider?.data, let pointer = CFDataGetBytePtr(data) else { return nil }
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        let index = y * image.bytesPerRow + x * bytesPerPixel
        let count = CFDataGetLength(data)
        guard index + 2 < count else { return nil }
        return (Int(pointer[index]) + Int(pointer[index + 1]) + Int(pointer[index + 2])) / 3
    }

    /// A Vision bounding box, normalized with a bottom-left origin, converted to
    /// pixel bounds in a top-left bitmap.
    private static func pixelBounds(of rect: CGRect, in image: CGImage) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let x0 = max(0, Int(rect.minX * w)), x1 = min(image.width, Int(rect.maxX * w))
        let y0 = max(0, Int((1 - rect.maxY) * h)), y1 = min(image.height, Int((1 - rect.minY) * h))
        return (x0, y0, x1, y1)
    }

    /// Fraction of sampled pixels a mask covers inside a bounding box.
    private static func maskCoverage(_ mask: CGImage, normalized rect: CGRect) -> Double {
        guard let data = mask.dataProvider?.data, let pointer = CFDataGetBytePtr(data) else { return -1 }
        let bpp = max(1, mask.bitsPerPixel / 8), bpr = mask.bytesPerRow
        let count = CFDataGetLength(data)
        let b = pixelBounds(of: rect, in: mask)
        var covered = 0, total = 0
        var y = b.y0
        while y < b.y1 {
            var x = b.x0
            while x < b.x1 {
                let index = y * bpr + x * bpp
                if index + 2 < count {
                    if (Int(pointer[index]) + Int(pointer[index + 1]) + Int(pointer[index + 2])) / 3 > 60 {
                        covered += 1
                    }
                    total += 1
                }
                x += 2
            }
            y += 2
        }
        return total > 0 ? Double(covered) / Double(total) : -1
    }

    /// Centre of a normalized rect, in the same bottom-left coordinates the
    /// face geometry uses.
    private static func mid(_ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    /// Red, green and blue of one pixel of an 8-bit RGBA bitmap. Row 0 is the
    /// top of the picture, so a normalized bottom-left point needs flipping.
    private static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard let data = image.dataProvider?.data, let pointer = CFDataGetBytePtr(data) else { return nil }
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        let index = y * image.bytesPerRow + x * bytesPerPixel
        guard index + 2 < CFDataGetLength(data) else { return nil }
        return (Int(pointer[index]), Int(pointer[index + 1]), Int(pointer[index + 2]))
    }

    private static func pixel(_ image: CGImage, normalized point: CGPoint) -> (r: Int, g: Int, b: Int)? {
        let x = Int((point.x * CGFloat(image.width)).rounded())
        let y = Int(((1 - point.y) * CGFloat(image.height)).rounded())
        return pixel(image, x: x, y: y)
    }

    private static func luminance(_ image: CGImage, normalizedAt point: CGPoint) -> Int? {
        guard let rgb = pixel(image, normalized: point) else { return nil }
        return (rgb.r + rgb.g + rgb.b) / 3
    }

    /// Channel change at a single point, for "did this spill onto that region".
    /// An unreadable pixel reports a large delta so a test cannot pass on nil.
    private static func sampleDelta(_ a: CGImage, _ b: CGImage, at point: CGPoint) -> Double {
        guard let p = pixel(a, normalized: point), let q = pixel(b, normalized: point) else { return 999 }
        return Double(abs(p.r - q.r) + abs(p.g - q.g) + abs(p.b - q.b)) / 3
    }

    /// Mean absolute difference over all three channels inside a normalized box.
    /// Luminance alone hides a hue shift: rose and berry differ mostly in blue.
    /// Mean absolute RGB distance over a coarse grid, with both buffers read
    /// once — the shape a preset sweep needs when it compares hundreds of pairs.
    private static func colorDifference(_ a: CGImage, _ b: CGImage,
                                        normalized rect: CGRect, stride: Int) -> Double {
        guard a.width == b.width, a.height == b.height,
              let da = a.dataProvider?.data, let pa = CFDataGetBytePtr(da),
              let db = b.dataProvider?.data, let pb = CFDataGetBytePtr(db) else { return -1 }
        let bpp = max(1, a.bitsPerPixel / 8), bpr = a.bytesPerRow
        let bounds = pixelBounds(of: rect, in: a)
        var total = 0.0, samples = 0.0
        var y = bounds.y0
        while y < bounds.y1 {
            var x = bounds.x0
            while x < bounds.x1 {
                let i = y * bpr + x * bpp
                total += Double(abs(Int(pa[i]) - Int(pb[i]))
                              + abs(Int(pa[i + 1]) - Int(pb[i + 1]))
                              + abs(Int(pa[i + 2]) - Int(pb[i + 2]))) / 3
                samples += 1
                x += stride
            }
            y += stride
        }
        return samples > 0 ? total / samples : -1
    }

    private static func meanColorDifference(_ a: CGImage, _ b: CGImage, normalized rect: CGRect) -> Double {
        guard a.width == b.width, a.height == b.height else { return -1 }
        let bounds = pixelBounds(of: rect, in: a)
        var total = 0.0, samples = 0.0
        var y = bounds.y0
        while y < bounds.y1 {
            var x = bounds.x0
            while x < bounds.x1 {
                if let p = pixel(a, x: x, y: y), let q = pixel(b, x: x, y: y) {
                    total += Double(abs(p.r - q.r) + abs(p.g - q.g) + abs(p.b - q.b)) / 3
                    samples += 1
                }
                x += 2
            }
            y += 2
        }
        return samples > 0 ? total / samples : -1
    }

    private static func regionMeanLuminance(_ image: CGImage, normalized rect: CGRect) -> Double {
        guard let value = meanChannels(image, normalized: rect) else { return -1 }
        return Double(value.r + value.g + value.b) / 3
    }

    private static func meanChannels(_ image: CGImage, normalized rect: CGRect) -> (r: Int, g: Int, b: Int)? {
        let bounds = pixelBounds(of: rect, in: image)
        var red = 0.0, green = 0.0, blue = 0.0, samples = 0.0
        var y = bounds.y0
        while y < bounds.y1 {
            var x = bounds.x0
            while x < bounds.x1 {
                if let rgb = pixel(image, x: x, y: y) {
                    red += Double(rgb.r); green += Double(rgb.g); blue += Double(rgb.b)
                    samples += 1
                }
                x += 2
            }
            y += 2
        }
        guard samples > 0 else { return nil }
        return (Int(red / samples), Int(green / samples), Int(blue / samples))
    }

    /// Mean absolute luminance change inside a bounding box, on a grid.
    private static func regionDifference(_ a: CGImage, _ b: CGImage, normalized rect: CGRect) -> Double {
        guard a.width == b.width, a.height == b.height,
              let da = a.dataProvider?.data, let pa = CFDataGetBytePtr(da),
              let db = b.dataProvider?.data, let pb = CFDataGetBytePtr(db) else { return -1 }
        let bpp = max(1, a.bitsPerPixel / 8), bpr = a.bytesPerRow
        let bounds = pixelBounds(of: rect, in: a)
        var total = 0.0, samples = 0.0
        var y = bounds.y0
        while y < bounds.y1 {
            var x = bounds.x0
            while x < bounds.x1 {
                let i = y * bpr + x * bpp
                let la = (Int(pa[i]) + Int(pa[i + 1]) + Int(pa[i + 2])) / 3
                let lb = (Int(pb[i]) + Int(pb[i + 1]) + Int(pb[i + 2])) / 3
                total += Double(abs(la - lb))
                samples += 1
                x += 2
            }
            y += 2
        }
        return samples > 0 ? total / samples : -1
    }

    /// Mean absolute per-pixel luminance difference, sampled on a grid.
    private static func meanAbsoluteDifference(_ a: CGImage, _ b: CGImage) -> Double? {
        guard a.width == b.width, a.height == b.height else { return nil }
        var total = 0.0
        var samples = 0.0
        var y = 0
        while y < a.height {
            var x = 0
            while x < a.width {
                if let la = luminance(a, x: x, y: y), let lb = luminance(b, x: x, y: y) {
                    total += abs(Double(la - lb))
                    samples += 1
                }
                x += 3
            }
            y += 3
        }
        guard samples > 0 else { return nil }
        return total / samples
    }

    private static func meanLuminance(_ image: CGImage) -> Double? {
        guard let data = image.dataProvider?.data, let pointer = CFDataGetBytePtr(data) else { return nil }
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        let count = CFDataGetLength(data)
        var total = 0.0
        var samples = 0.0
        var y = 0
        while y < image.height {
            var x = 0
            while x < image.width {
                let index = y * image.bytesPerRow + x * bytesPerPixel
                if index + 2 < count {
                    total += Double(Int(pointer[index]) + Int(pointer[index + 1]) + Int(pointer[index + 2])) / 3.0
                    samples += 1
                }
                x += 7
            }
            y += 7
        }
        guard samples > 0 else { return nil }
        return (total / samples * 10).rounded() / 10
    }

    /// Top half bright, bottom half dark. In CG drawing coordinates y = 0 is
    /// the bottom, matching Core Image.
    private static func makeCropFixture(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        context.setFillColor(CGColor(red: 0.86, green: 0.86, blue: 0.86, alpha: 1))
        context.fill(CGRect(x: 0, y: h / 2, width: w, height: h / 2))
        context.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h / 2))
        return context.makeImage()
    }

    private static func makeGrayImage(size: Int, spotCenter: CGPoint, spotSize: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 128 / 255, green: 128 / 255, blue: 128 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: spotCenter.x - CGFloat(spotSize) / 2,
                            y: spotCenter.y - CGFloat(spotSize) / 2,
                            width: CGFloat(spotSize), height: CGFloat(spotSize)))
        return context.makeImage()
    }

    private static func makeSyntheticPortrait(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        let w = CGFloat(width), h = CGFloat(height)
        context.setFillColor(CGColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // صورت
        context.setFillColor(CGColor(red: 0.86, green: 0.70, blue: 0.60, alpha: 1))
        context.fillEllipse(in: CGRect(x: w * 0.28, y: h * 0.40, width: w * 0.44, height: h * 0.46))

        // موی سر
        context.setFillColor(CGColor(red: 0.22, green: 0.14, blue: 0.10, alpha: 1))
        context.fillEllipse(in: CGRect(x: w * 0.25, y: h * 0.72, width: w * 0.50, height: h * 0.26))

        // چشم‌ها
        context.setFillColor(CGColor(red: 0.92, green: 0.92, blue: 0.90, alpha: 1))
        context.fillEllipse(in: CGRect(x: w * 0.37, y: h * 0.62, width: w * 0.10, height: h * 0.045))
        context.fillEllipse(in: CGRect(x: w * 0.53, y: h * 0.62, width: w * 0.10, height: h * 0.045))
        context.setFillColor(CGColor(red: 0.18, green: 0.22, blue: 0.30, alpha: 1))
        context.fillEllipse(in: CGRect(x: w * 0.405, y: h * 0.625, width: w * 0.04, height: h * 0.032))
        context.fillEllipse(in: CGRect(x: w * 0.565, y: h * 0.625, width: w * 0.04, height: h * 0.032))

        // لب‌ها
        context.setFillColor(CGColor(red: 0.72, green: 0.36, blue: 0.34, alpha: 1))
        context.fillEllipse(in: CGRect(x: w * 0.42, y: h * 0.50, width: w * 0.16, height: h * 0.045))

        // چند لک و جوش
        context.setFillColor(CGColor(red: 0.70, green: 0.36, blue: 0.34, alpha: 1))
        let spots: [(CGFloat, CGFloat, CGFloat)] = [(0.34, 0.56, 0.018), (0.64, 0.60, 0.014),
                                                    (0.44, 0.68, 0.012), (0.58, 0.48, 0.016),
                                                    (0.36, 0.46, 0.013), (0.66, 0.52, 0.011)]
        for spot in spots {
            context.fillEllipse(in: CGRect(x: w * (spot.0 - spot.2 / 2), y: h * (spot.1 - spot.2 / 2),
                                           width: w * spot.2, height: w * spot.2))
        }

        // نویز ریز پوست
        for _ in 0..<4000 {
            let x = CGFloat.random(in: w * 0.30...w * 0.70)
            let y = CGFloat.random(in: h * 0.42...h * 0.84)
            let value = CGFloat.random(in: 0.72...0.95)
            context.setFillColor(CGColor(red: value, green: value * 0.83, blue: value * 0.72, alpha: 0.35))
            context.fill(CGRect(x: x, y: y, width: 1.6, height: 1.6))
        }

        return context.makeImage()
    }
}

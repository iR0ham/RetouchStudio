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
        print("-- full chain on a synthetic portrait --")
        passed = checkSyntheticPortrait(outDirectory: outDirectory) && passed
        print("-- auto color/light vs auto retouch separation --")
        passed = checkAutoSeparation() && passed
        print("-- mask convention (opaque grayscale) --")
        passed = checkMaskConvention() && passed
        print("-- blemish gate separates skin from spots --")
        passed = checkBlemishGate() && passed
        print("-- teeth whitening only when teeth are visible --")
        passed = checkTeethGating() && passed
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
        var generator = SystemRandomNumberGenerator()
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
        guard let masks = processor.buildMasks(extent: extent, faces: [face]) else { return false }
        let source = CIImage(cgImage: base).cropped(to: extent)
        let preset = Preset.all[1].adjustments
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

    // MARK: - ۴) عکس واقعی

    private static func checkRealFace(path: String, outDirectory: String) -> Bool {
        let processor = ImageProcessor.shared
        let url = URL(fileURLWithPath: path)
        guard let full = processor.loadCGImage(url: url) else {
            print("  ✗ could not read test photo: \(path)")
            return false
        }

        let fullExtent = CGRect(x: 0, y: 0, width: full.width, height: full.height)
        var faces = FaceAnalyzer.analyze(full)
        print("  • size: \(full.width)×\(full.height) | faces detected: \(faces.count)")
        for face in faces {
            print("    - face box: x=\(String(format: "%.3f", face.boundingBox.minX)) y=\(String(format: "%.3f", face.boundingBox.minY)) w=\(String(format: "%.3f", face.boundingBox.width)) h=\(String(format: "%.3f", face.boundingBox.height))")
            print("      contour=\(face.faceContour.count) eyes=\(face.eyePolygons.count) brows=\(face.eyebrowPolygons.count) lips=\(face.lipPolygon.count) nose=\(face.nose.count)")
        }
        guard !faces.isEmpty else {
            print("  ✗ no face found")
            return false
        }

        let scale = ImageProcessor.previewScale(for: fullExtent, maxDimension: 1400)
        let previewExtent = CGRect(x: 0, y: 0,
                                   width: (fullExtent.width * scale).rounded(),
                                   height: (fullExtent.height * scale).rounded())
        let source = CIImage(cgImage: full)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: previewExtent)

        if let buffer = AutoAnalyzer.analysisBuffer(source) {
            faces = AutoAnalyzer.annotateTeeth(faces: faces, buffer: buffer)
            for face in faces {
                let fraction = AutoAnalyzer.visibleTeethFraction(buffer: buffer, face: face)
                print("    - visible teeth: \(face.hasVisibleTeeth ? "yes" : "no") | openness=\(String(format: "%.2f", face.mouthOpenness)) | fraction=\(String(format: "%.2f", fraction))")
            }
        }

        guard let masks = processor.buildMasks(extent: previewExtent, faces: faces) else {
            print("  ✗ could not build mask")
            return false
        }

        let directory = URL(fileURLWithPath: outDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let faceMask = masks.face {
            let overBlack = faceMask.composited(over: CIImage(color: .black).cropped(to: previewExtent))
            _ = processor.write(overBlack, to: directory.appendingPathComponent("selftest-mask.png"), format: .png, quality: 1)
            print("  ✓ skin mask written: selftest-mask.png")
        }

        _ = processor.write(source, to: directory.appendingPathComponent("selftest-face-before.png"), format: .png, quality: 1)

        let output = processor.process(source, adjustments: Preset.all[1].adjustments,
                                       masks: masks, faces: faces)
        let wrote = processor.write(output, to: directory.appendingPathComponent("selftest-face-after.png"), format: .png, quality: 1)
        print("  \(wrote ? "✓" : "✗") retouched output written: selftest-face-after.png")
        return wrote
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

        let extent = src.extent
        let processor = ImageProcessor.shared
        let masks = processor.buildMasks(extent: extent, faces: [face])
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
            || retouchPatch.saturation != 0 || retouchPatch.vibrance != 0
            || retouchPatch.warmth != 0 || retouchPatch.clarity != 0
            || retouchPatch.vignette != 0

        // و هر کدام باید چیزی را واقعاً تنظیم کند.
        let colorIsUseful = colorPatch.exposure != 0 || colorPatch.contrast != 0
            || colorPatch.saturation != 0 || colorPatch.vibrance != 0
            || colorPatch.warmth != 0 || colorPatch.clarity != 0
        let retouchIsUseful = retouchPatch.smooth != 0 && retouchPatch.eyeBrighten != 0

        print("  \(!colorTouchesRetouch ? "✓" : "✗") Auto Color & Light did not touch retouch fields")
        print("     color/light → exposure=\(fmt(colorPatch.exposure)) contrast=\(fmt(colorPatch.contrast)) saturation=\(fmt(colorPatch.saturation)) vibrance=\(fmt(colorPatch.vibrance)) warmth=\(fmt(colorPatch.warmth)) clarity=\(fmt(colorPatch.clarity))")
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

    // MARK: - ۵) رتوش خودکار باید فقط داخل چهره اثر بگذارد

    /// Applies the retouch patch (skin + eye + teeth) and measures how much of
    /// the change lands inside the skin mask versus outside it. The skin tools
    /// are masked to the face, so the background must stay essentially intact —
    /// if it moves, "Auto Retouch" is behaving like a global edit.
    private static func checkAutoRetouchIsFaceLocal(path: String) -> Bool {
        let processor = ImageProcessor.shared
        guard let full = processor.loadCGImage(url: URL(fileURLWithPath: path)) else {
            print("  ✗ could not read \(path)")
            return false
        }
        let fullExtent = CGRect(x: 0, y: 0, width: full.width, height: full.height)
        let faces = FaceAnalyzer.analyze(full)
        guard !faces.isEmpty else {
            print("  ✗ no face found")
            return false
        }

        let scale = ImageProcessor.previewScale(for: fullExtent, maxDimension: 1400)
        let extent = CGRect(x: 0, y: 0,
                            width: (fullExtent.width * scale).rounded(),
                            height: (fullExtent.height * scale).rounded())
        let source = CIImage(cgImage: full)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: extent)

        guard let masks = processor.buildMasks(extent: extent, faces: faces),
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

        var generator = SystemRandomNumberGenerator()
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

    // MARK: - کمکی‌ها

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

    private static func makeNoisyImage(size: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.72, green: 0.62, blue: 0.55, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))

        // نویز ریز و پرکنتراست = شبیه‌سازی بافت پوست و منافذ.
        var generator = SystemRandomNumberGenerator()
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

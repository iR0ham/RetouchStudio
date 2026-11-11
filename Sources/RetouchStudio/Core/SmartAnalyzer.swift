import CoreGraphics
import Foundation
import StudioCore

/// Reads a photo the way a retoucher would, on the same 512 px buffer the
/// automatic tools already use: what the skin texture is like, where the
/// blemishes are, whether the under-eye area is darker than the cheek, whether
/// the T-zone is shiny, whether there are lines that are not pores.
///
/// Everything here is measurement. Deciding how much to apply is left to the
/// caller, so the report can show the numbers before anything changes.
enum SmartAnalyzer {

    // MARK: - Report types

    struct Finding: Identifiable, Equatable {
        enum Kind: String {
            case texture, blemish, wrinkles, darkCircles, shine, unevenTone
            case teeth, eyes
            case exposure, contrast, levels, whiteBalance, color, detail, balanced
        }

        /// What the measurement found. The words live in the string table, so
        /// the same report reads in either language.
        enum Detail: Equatable {
            case texturePronounced
            case textureVisible
            case textureFine
            case spots(Int)
            case linesHeavy
            case linesLight
            case underEyeStrong
            case underEyeMild
            case underEyeFaint
            case shineHeavy
            case shineLight
            case tonePatchy
            case toneSlight
            case teethWarm
            case teethSlight
            case eyesDim
            case eyesCatchlight
            case exposureDark
            case exposureBright
            case contrastFlat
            case levelsFaded
            case castBlue
            case castWarm
            case colorDull
            case detailSoft
            case balanced
        }

        var kind: Kind
        /// 0 = nothing to do, 1 = the strongest case this analyzer reports.
        var severity: Double
        var detail: Detail

        var id: String { kind.rawValue }
    }

    struct FaceReading: Identifiable {
        let index: Int
        /// Face area in normalized image units, used to weight the merge.
        let area: Double
        let findings: [Finding]
        let retouch: Adjustments
        /// The face crop the blemish finder looked through, so the report can
        /// show the exact pixels instead of asking the owner to trust a count.
        var spotPreview: CGImage?
        /// Suggested spots in preview-normalized coordinates; radius is a
        /// fraction of the preview's short side.
        var spotMarkers: [SpotMarker] = []

        var id: Int { index }
    }

    struct SpotMarker {
        var center: CGPoint
        var radius: CGFloat
    }

    /// One blemish, in working-image coordinates (top-left origin, normalized).
    struct Spot {
        var center: CGPoint
        /// Radius as a fraction of the short side, ready for `HealSpot`.
        var radius: CGFloat
        var strength: Double
    }

    /// A face-centred crop rendered at its own resolution. A small face in a
    /// full-body frame is about 90 px on the 512 px analysis buffer, where a
    /// blemish is 1–2 px and a glasses frame is a many-pixel blob — that scale
    /// is why the first detector healed lenses and hair. This crop restores the
    /// pixels the eye actually sees.
    struct FaceCrop {
        var buffer: PixelBuffer
        /// Skin mask rendered into the same frame, when one was available.
        var skin: PixelBuffer?
        /// Face box in buffer pixels, top-left origin.
        var faceRect: CGRect
        /// The same face box in image coordinates (bottom-left normalized), so
        /// landmark regions can be mapped into the crop.
        var faceBox: CGRect
        /// Eyes, brows, lips and nostrils in buffer pixels, top-left origin.
        var exclusions: [CGRect]
        /// Where the crop sits in the working image, top-left normalized.
        var frame: CGRect
        /// Working image size in pixels, for converting radii back.
        var workingSize: CGSize
        /// The rendered crop, shown in the report.
        var image: CGImage?
    }

    /// A detection in buffer pixels, before it is mapped back to the photo.
    struct RawSpot {
        var center: CGPoint
        var radius: Double
        var strength: Double
    }

    struct Report {
        var faces: [FaceReading]
        var photoFindings: [Finding]
        var colorLight: Adjustments
        var retouch: Adjustments
        var spots: [Spot]
        var skinRoughness: Double
    }

    // MARK: - Entry point

    static func analyze(buffer: PixelBuffer,
                        skinMask: PixelBuffer?,
                        faces: [FaceGeometry],
                        crops: [FaceCrop?] = []) -> Report {
        let colorLight = AutoAnalyzer.autoColorLight(buffer)
        let skinMedian = AutoAnalyzer.skinMedianLuminance(buffer, mask: skinMask)
        var readings: [FaceReading] = []
        var allSpots: [Spot] = []

        for (index, face) in faces.enumerated() {
            var findings: [Finding] = []
            let crop = index < crops.count ? crops[index] : nil

            // Texture is read on the face crop, where every face is the same
            // pixel size. On the 512 px frame a distant face is a few dozen
            // pixels wide and its own grain aliases into three times the
            // roughness of a close-up of the same skin, which is how the old
            // automatic asked for maximum smoothing on almost every photo.
            let cropRoughness = crop.flatMap { cropTexture($0) }
            let bufferRoughness = regionRoughness(buffer, rect: face.leftCheekRect)
                ?? regionRoughness(buffer, rect: face.rightCheekRect)
                ?? 0.008
            let textureSeverity = cropRoughness.map {
                clamp(($0 - 0.020) / 0.035, 0, 1)
            } ?? clamp((bufferRoughness - 0.012) * 35, 0, 1)
            findings.append(Finding(
                kind: .texture,
                severity: textureSeverity,
                detail: textureDetail(textureSeverity)
            ))

            let spots = crop.map { detectSpots(in: $0) }
                ?? detectSpots(in: buffer, mask: skinMask, near: face)
            allSpots.append(contentsOf: spots)
            let spotSeverity = clamp(Double(spots.count) * 0.14, 0, 1)
            if !spots.isEmpty {
                findings.append(Finding(
                    kind: .blemish,
                    severity: spotSeverity,
                    detail: .spots(spots.count)
                ))
            }

            // Lines are horizontal bands. Row means high-passed along y show
            // them whether the face is lit from above, from the side or from
            // behind, and they ignore vertical hair strands and lateral
            // shading. Measured on the crop for the same scale reason as the
            // texture above; the buffer fallback only runs on large faces.
            let band = crop.flatMap {
                cropBand($0, rect: face.foreheadRect)
            } ?? normalizedBandEnergy(buffer, rect: face.foreheadRect)
            let wrinkleSeverity = band > 0
                ? clamp((band - 0.010) / 0.010, 0, 1)
                : clamp((verticalEdgeEnergy(buffer, rects: wrinkleRects(face)) - 0.006) * 110, 0, 1)
            if wrinkleSeverity > 0.08 {
                findings.append(Finding(
                    kind: .wrinkles,
                    severity: wrinkleSeverity,
                    detail: wrinkleSeverity > 0.55 ? .linesHeavy : .linesLight
                ))
            }

            let eyeRatio = underEyeRatio(buffer, face: face)
                ?? 1
            // 0.93 is normal lighting for an eye bag; 0.80 is a real shadow.
            let darkSeverity = clamp((0.93 - eyeRatio) / 0.13, 0, 1)
            if darkSeverity > 0.05 {
                findings.append(Finding(
                    kind: .darkCircles,
                    severity: darkSeverity,
                    detail: darkSeverity > 0.55 ? .underEyeStrong
                        : darkSeverity > 0.3 ? .underEyeMild
                        : .underEyeFaint
                ))
            }

            let shine = shineFraction(buffer, face: face)
            let shineSeverity = clamp((shine - 0.02) * 9, 0, 1)
            if shineSeverity > 0.08 {
                findings.append(Finding(
                    kind: .shine,
                    severity: shineSeverity,
                    detail: shineSeverity > 0.5 ? .shineHeavy : .shineLight
                ))
            }

            // Patchiness is the same scale problem as texture: on the analysis
            // buffer a small face is measured in 6 px blocks, so its own pores
            // read as blotches. The crop measures 8 px of skin no matter how
            // much of the frame the face fills.
            let cropUneven = crop.flatMap { unevenOnCrop($0) }
            let uneven = cropUneven ?? unevenTone(buffer, face: face)
            let unevenSeverity = cropUneven != nil
                ? clamp((uneven - 0.050) / 0.040, 0, 1)
                : clamp((uneven - 0.070) / 0.055, 0, 1)
            if unevenSeverity > 0.1 {
                findings.append(Finding(
                    kind: .unevenTone,
                    severity: unevenSeverity,
                    detail: unevenSeverity > 0.5 ? .tonePatchy : .toneSlight
                ))
            }

            // Warmth is measured, not assumed: neutral teeth report nothing,
            // so pressing Auto on a photo with a normal smile does not whiten.
            if face.hasVisibleTeeth {
                let yellowness = teethYellowness(buffer, face: face)
                let severity = clamp((yellowness - 0.05) * 5, 0, 1)
                if severity > 0 {
                    findings.append(Finding(
                        kind: .teeth,
                        severity: severity,
                        detail: severity > 0.5 ? .teethWarm : .teethSlight
                    ))
                }
            }

            if face.hasUsableEyes {
                // Brightening only means something when the whites are actually
                // dim; the 70th-percentile sclera level says so. Sharpening the
                // catchlight is available whenever the eyes are measurable.
                let bright = face.eyeScleraLevel.map { clamp((0.68 - $0) / 0.18, 0, 1) } ?? 0
                findings.append(Finding(
                    kind: .eyes,
                    severity: max(bright, 0.2),
                    detail: bright > 0.15 ? .eyesDim : .eyesCatchlight
                ))
            }

            let area = Double(face.boundingBox.width * face.boundingBox.height)
            let retouch = retouchValues(findings: findings,
                                        hasEyes: face.hasUsableEyes,
                                        scleraLevel: face.eyeScleraLevel,
                                        skinMedian: skinMedian)
            let markers = markers(for: spots, in: crop)
            readings.append(FaceReading(index: index,
                                        area: max(area, 0.0001),
                                        findings: findings,
                                        retouch: retouch,
                                        spotPreview: crop?.image,
                                        spotMarkers: markers))
        }

        // One blemish found twice (both cheeks overlap) should be healed once.
        let spots = dedupe(allSpots)

        return Report(faces: readings,
                      photoFindings: photoFindings(from: colorLight),
                      colorLight: colorLight,
                      retouch: merge(readings),
                      spots: spots,
                      skinRoughness: AutoAnalyzer.skinRoughness(buffer, mask: skinMask) ?? 0)
    }

    // MARK: - Retouch values

    /// Every value comes from a measurement of this face; the caps keep any
    /// single one from becoming the whole edit. A value of zero means the
    /// measurement found nothing to correct, which is a real answer: pressing
    /// Auto on a photo that is already clean should not repaint it.
    static func retouchValues(findings: [Finding],
                              hasEyes: Bool,
                              scleraLevel: Double?,
                              skinMedian: Double?) -> Adjustments {
        func severity(_ kind: Finding.Kind) -> Double {
            findings.first { $0.kind == kind }?.severity ?? 0
        }

        var a = Adjustments()
        // Each line is a floor plus a measured rise. The floors are what a
        // retoucher would call a first pass, never the cap; a face whose own
        // numbers come out clean stays close to them instead of being pushed to
        // the top of the range the way the old single-roughness formula did.
        a.smooth = 6 + 20 * severity(.texture)
        a.texturePreserve = clamp(94 - a.smooth * 0.65, 70, 92)
        // Nothing is healed where nothing was found: a blemish count of zero is
        // the detector saying this skin has no isolated dark spots, and a
        // blanket median would spend that as freckles and stubble.
        a.blemish = severity(.blemish) > 0 ? 10 + 18 * severity(.blemish) : 0
        a.wrinkle = 16 * severity(.wrinkles)
        a.skinToneEvens = 6 + 14 * severity(.unevenTone)
        a.darkCircles = 24 * severity(.darkCircles)
        // Shine was measured in the T-zone, and the existing matte control is
        // what answers it — the report must never name a problem the sliders
        // cannot reach.
        a.shine = 30 * severity(.shine)
        // Light is added to a face that sits too dark; it is never taken away.
        // The old automatic compared skin with the frame median and darkened a
        // well-lit face whenever the wall behind it was brighter.
        a.skinBrighten = skinMedian.map { clamp((0.46 - $0) * 120, 0, 14) } ?? 0
        // Whitening follows the measured warmth, which is already gated by the
        // finding above — neutral teeth contribute nothing.
        a.teethWhiten = severity(.teeth) > 0 ? 8 + 10 * severity(.teeth) : 0
        // Brightening the whites follows the sclera measurement: when they are
        // already bright there is nothing honest to add. Sharpening the iris
        // works whenever the eyes are measurable.
        let eyeBright = scleraLevel.map { clamp((0.68 - $0) / 0.18, 0, 1) } ?? 0
        a.eyeBrighten = eyeBright > 0 ? 8 + 8 * eyeBright : 0
        a.eyeSharpen = hasEyes ? 6 : 0
        return a
    }

    /// The sliders are global, so one suggestion has to represent the whole
    /// photo. Each face's values are weighted by its area: a large face in the
    /// frame drives the result more than a small one in the background.
    private static func merge(_ readings: [FaceReading]) -> Adjustments {
        guard !readings.isEmpty else { return Adjustments() }
        let totalArea = readings.reduce(0) { $0 + $1.area }
        guard totalArea > 0 else { return readings[0].retouch }

        var merged = Adjustments()
        let keys: [WritableKeyPath<Adjustments, Double>] = [
            \.smooth, \.blemish, \.wrinkle, \.skinToneEvens,
            \.darkCircles, \.shine, \.skinBrighten, \.teethWhiten,
            \.eyeBrighten, \.eyeSharpen
        ]
        for key in keys {
            merged[keyPath: key] = readings.reduce(0) {
                $0 + $1.retouch[keyPath: key] * $1.area
            } / totalArea
        }
        merged.texturePreserve = clamp(94 - merged.smooth * 0.65, 70, 92)
        return merged
    }

    // MARK: - Photo-level findings

    private static func photoFindings(from a: Adjustments) -> [Finding] {
        var findings: [Finding] = []
        func add(_ kind: Finding.Kind, _ detail: Finding.Detail, _ severity: Double) {
            findings.append(Finding(kind: kind, severity: clamp(severity, 0, 1),
                                    detail: detail))
        }

        if a.exposure > 2 {
            add(.exposure, .exposureDark, clamp(a.exposure / 20, 0.1, 1))
        } else if a.exposure < -2 {
            add(.exposure, .exposureBright, clamp(-a.exposure / 12, 0.1, 1))
        }
        if a.contrast > 5 {
            add(.contrast, .contrastFlat, clamp(a.contrast / 22, 0.1, 1))
        }
        if a.blacks > 4 || a.whites > 4 {
            add(.levels, .levelsFaded, clamp(max(a.blacks, a.whites) / 30, 0.1, 1))
        }
        if abs(a.warmth) > 3 {
            add(.whiteBalance, a.warmth > 0 ? .castBlue : .castWarm,
                clamp(abs(a.warmth) / 20, 0.1, 1))
        }
        if a.vibrance > 4 || a.saturation < -2 {
            add(.color, .colorDull, clamp(max(a.vibrance / 20, -a.saturation / 18), 0.1, 1))
        }
        if a.clarity > 3 {
            add(.detail, .detailSoft, clamp(a.clarity / 12, 0.1, 1))
        }
        if findings.isEmpty {
            add(.balanced, .balanced, 0)
        }
        return findings
    }

    // MARK: - Texture and line measurements

    private static func regionRoughness(_ buffer: PixelBuffer, rect: CGRect) -> Double? {
        let r = bufferRect(rect, buffer)
        guard r.width > 2, r.height > 2 else { return nil }
        let step = max(1, min(r.width, r.height) / 24)
        var total = 0.0, samples = 0.0
        for y in stride(from: r.minY + step, to: r.maxY - step, by: step) {
            for x in stride(from: r.minX + step, to: r.maxX - step, by: step) {
                let center = buffer.luminance(x: x, y: y)
                total += abs(center - buffer.luminance(x: x + step, y: y))
                total += abs(center - buffer.luminance(x: x, y: y + step))
                samples += 2
            }
        }
        guard samples > 8 else { return nil }
        return total / samples
    }

    /// Mean luminance step across the middle of the face, on the crop and at a
    /// fixed pixel distance. The crop puts every face at the same scale, so the
    /// number describes the skin rather than how much of the frame it fills.
    private static func cropTexture(_ crop: FaceCrop) -> Double? {
        let box = crop.faceRect
        let buffer = crop.buffer
        let step = 3
        let x0 = Int(box.minX + box.width * 0.22)
        let x1 = Int(box.minX + box.width * 0.78)
        let y0 = Int(box.minY + box.height * 0.28)
        let y1 = Int(box.minY + box.height * 0.72)
        guard x1 - x0 > 4 * step, y1 - y0 > 4 * step else { return nil }
        let skin = crop.skin.flatMap {
            $0.width == buffer.width && $0.height == buffer.height ? $0 : nil
        }
        var total = 0.0, samples = 0.0
        var y = y0
        while y < y1 - step {
            var x = x0
            while x < x1 - step {
                if let skin, skin.luminance(x: x, y: y) < 0.5 {
                    x += step
                    continue
                }
                let center = buffer.luminance(x: x, y: y)
                total += abs(center - buffer.luminance(x: x + step, y: y))
                total += abs(center - buffer.luminance(x: x, y: y + step))
                samples += 2
                x += step
            }
            y += step
        }
        return samples > 0 ? total / samples : nil
    }

    /// Patchiness on the crop: the mean luminance step over a distance far
    /// enough that pores and grain fall inside it and only genuine light-dark
    /// zones register. `cropTexture` measures the same patch at 3 px; the two
    /// together separate "rough" from "blotchy".
    private static func unevenOnCrop(_ crop: FaceCrop) -> Double? {
        let box = crop.faceRect
        let buffer = crop.buffer
        let reach = 8, step = 4
        let x0 = Int(box.minX + box.width * 0.22)
        let x1 = Int(box.minX + box.width * 0.78)
        let y0 = Int(box.minY + box.height * 0.28)
        let y1 = Int(box.minY + box.height * 0.72)
        guard x1 - x0 > 4 * reach, y1 - y0 > 4 * reach else { return nil }
        let skin = crop.skin.flatMap {
            $0.width == buffer.width && $0.height == buffer.height ? $0 : nil
        }
        var total = 0.0, samples = 0.0
        var y = y0
        while y < y1 - reach {
            var x = x0
            while x < x1 - reach {
                if let skin, skin.luminance(x: x, y: y) < 0.5 {
                    x += step
                    continue
                }
                let center = buffer.luminance(x: x, y: y)
                total += abs(center - buffer.luminance(x: x + reach, y: y))
                total += abs(center - buffer.luminance(x: x, y: y + reach))
                samples += 2
                x += step
            }
            y += step
        }
        return samples > 40 ? total / samples : nil
    }

    /// Visibility of horizontal bands — lines — in a face region, measured on
    /// the crop. Row means remove lateral shading and vertical hair; the y
    /// high-pass removes the broad light falloff across a forehead, which is
    /// what made the old vertical-gradient measure call every face lined.
    private static func cropBand(_ crop: FaceCrop, rect: CGRect) -> Double? {
        let px = cropRect(rect, crop: crop)
        guard px.width > 12, px.height > 12 else { return nil }
        return bandEnergy(crop.buffer, rect: px)
    }

    /// A region in `FaceGeometry` space (bottom-left normalized, image-wide)
    /// mapped into the crop's pixels. The crop was made from `faceBox`, so that
    /// box is the origin of the mapping and `faceRect` is where it landed.
    private static func cropRect(_ rect: CGRect, crop: FaceCrop) -> CGRect {
        let box = crop.faceBox, dst = crop.faceRect
        guard !rect.isNull, box.width > 0.0001, box.height > 0.0001 else { return .zero }
        let sx = dst.width / box.width, sy = dst.height / box.height
        return CGRect(x: dst.minX + (rect.minX - box.minX) * sx,
                      y: dst.minY + (box.maxY - rect.maxY) * sy,
                      width: rect.width * sx, height: rect.height * sy)
    }

    /// Same measurement on the 512 px analysis buffer, used only when a face is
    /// too small to render a crop. `rect` is in face-geometry coordinates.
    private static func normalizedBandEnergy(_ buffer: PixelBuffer, rect: CGRect) -> Double {
        let r = bufferRect(rect, buffer)
        guard r.width > 12, r.height > 12 else { return 0 }
        return bandEnergy(buffer, rect: CGRect(x: r.minX, y: r.minY,
                                               width: r.width, height: r.height))
    }

    /// Horizontal band energy inside `rect`, in buffer pixels.
    private static func bandEnergy(_ buffer: PixelBuffer, rect: CGRect) -> Double {
        let x0 = max(1, Int(rect.minX.rounded()))
        let x1 = min(buffer.width - 2, Int(rect.maxX.rounded()))
        let y0 = max(1, Int(rect.minY.rounded()))
        let y1 = min(buffer.height - 2, Int(rect.maxY.rounded()))
        guard x1 - x0 > 12, y1 - y0 > 12 else { return 0 }
        let left = x0 + Int(Double(x1 - x0) * 0.15)
        let right = x1 - Int(Double(x1 - x0) * 0.15)
        guard right > left else { return 0 }

        var rows: [Double] = []
        rows.reserveCapacity(y1 - y0)
        for y in y0..<y1 {
            var sum = 0.0
            var count = 0
            for x in stride(from: left, to: right, by: 2) {
                sum += buffer.luminance(x: x, y: y)
                count += 1
            }
            rows.append(count > 0 ? sum / Double(count) : 0)
        }
        // A line is a few pixels thick; a seven-row mean is the shading
        // underneath it.
        let reach = 3
        guard rows.count > 2 * reach + 4 else { return 0 }
        var residuals: [Double] = []
        for y in reach..<(rows.count - reach) {
            var local = 0.0
            for k in -reach...reach { local += rows[y + k] }
            local /= Double(2 * reach + 1)
            residuals.append(rows[y] - local)
        }
        let mean = residuals.reduce(0, +) / Double(residuals.count)
        let variance = residuals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(residuals.count)
        return variance.squareRoot()
    }

    /// Rectangles where lines show first: the forehead and the skin beside the
    /// outer eye corners.
    private static func wrinkleRects(_ face: FaceGeometry) -> [CGRect] {
        var rects = [face.foreheadRect]
        for eye in [face.leftEyeRect, face.rightEyeRect] {
            let width = eye.width * 0.55
            let height = eye.height * 1.1
            let outerX = eye.midX < face.boundingBox.midX
                ? eye.minX - width * 0.55
                : eye.maxX - width * 0.45
            rects.append(CGRect(x: outerX, y: eye.midY - height / 2,
                                width: width, height: height))
        }
        return rects
    }

    /// Mean vertical luminance gradient: a horizontal line (a wrinkle) shows up
    /// here, while grain is symmetric and cancels out.
    private static func verticalEdgeEnergy(_ buffer: PixelBuffer, rects: [CGRect]) -> Double {
        var total = 0.0, samples = 0.0
        for rect in rects {
            let r = bufferRect(rect, buffer)
            guard r.width > 2, r.height > 2 else { continue }
            let step = max(1, min(r.width, r.height) / 20)
            for y in stride(from: r.minY + 1, to: r.maxY - 1, by: step) {
                for x in stride(from: r.minX, to: r.maxX, by: step) {
                    let up = buffer.luminance(x: x, y: y - 1)
                    let down = buffer.luminance(x: x, y: y + 1)
                    total += abs(down - up)
                    samples += 1
                }
            }
        }
        return samples > 0 ? total / samples : 0
    }

    // MARK: - Tone and colour measurements

    /// Mean luminance of the eye bag against the cheek it sits on. A ratio near
    /// 1 is normal lighting; below about 0.8 reads as a shadow.
    private static func underEyeRatio(_ buffer: PixelBuffer, face: FaceGeometry) -> Double? {
        let cheek = meanLuminance(buffer, rects: [face.leftCheekRect, face.rightCheekRect])
        guard cheek > 0.02 else { return nil }
        var under: [CGRect] = []
        for eye in [face.leftEyeRect, face.rightEyeRect] {
            let width = eye.width * 0.95
            let height = eye.height * 1.0
            under.append(CGRect(x: eye.midX - width / 2,
                                y: eye.minY - height * 1.05,
                                width: width, height: height))
        }
        let luma = meanLuminance(buffer, rects: under)
        guard luma > 0.01 else { return nil }
        return luma / cheek
    }

    private static func shineFraction(_ buffer: PixelBuffer, face: FaceGeometry) -> Double {
        let rects = [face.foreheadRect, face.noseRect]
        var bright = 0.0, total = 0.0
        for raw in rects {
            let rect = bufferRect(raw, buffer)
            guard rect.width > 2, rect.height > 2 else { continue }
            let step = max(1, min(rect.width, rect.height) / 16)
            for y in stride(from: rect.minY, to: rect.maxY, by: step) {
                for x in stride(from: rect.minX, to: rect.maxX, by: step) {
                    let (r, g, b) = buffer.rgb(x: x, y: y)
                    let maxChannel = max(r, max(g, b))
                    let minChannel = min(r, min(g, b))
                    let saturation = maxChannel > 0.0001 ? (maxChannel - minChannel) / maxChannel : 0
                    if buffer.luminance(x: x, y: y) > 0.86 && saturation < 0.12 { bright += 1 }
                    total += 1
                }
            }
        }
        return total > 0 ? bright / total : 0
    }

    /// Standard deviation of 4 × 4 block means across the cheeks and forehead.
    /// Smooth skin changes slowly; blotchy skin jumps between blocks.
    private static func unevenTone(_ buffer: PixelBuffer, face: FaceGeometry) -> Double {
        let rects = [face.leftCheekRect, face.rightCheekRect, face.foreheadRect]
        var means: [Double] = []
        for raw in rects {
            let rect = bufferRect(raw, buffer)
            guard rect.width > 8, rect.height > 8 else { continue }
            for by in 0..<4 {
                for bx in 0..<4 {
                    let x0 = rect.minX + rect.width * bx / 4
                    let x1 = rect.minX + rect.width * (bx + 1) / 4
                    let y0 = rect.minY + rect.height * by / 4
                    let y1 = rect.minY + rect.height * (by + 1) / 4
                    let mean = meanLuminance(buffer, x0: x0, x1: x1, y0: y0, y1: y1)
                    if mean > 0.01 { means.append(mean) }
                }
            }
        }
        guard means.count >= 4 else { return 0 }
        let mean = means.reduce(0, +) / Double(means.count)
        let variance = means.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(means.count)
        return variance.squareRoot()
    }

    /// Warmth of the enamel: a neutral tooth sits close to grey, a yellow one
    /// has more red and blue than green in the bright pixels of the mouth.
    private static func teethYellowness(_ buffer: PixelBuffer, face: FaceGeometry) -> Double {
        guard let rect = face.teethRect else { return 0 }
        let r = bufferRect(rect, buffer)
        guard r.width > 2, r.height > 2 else { return 0 }
        let step = max(1, min(r.width, r.height) / 12)
        var total = 0.0, samples = 0.0
        for y in stride(from: r.minY, to: r.maxY, by: step) {
            for x in stride(from: r.minX, to: r.maxX, by: step) {
                let (red, green, blue) = buffer.rgb(x: x, y: y)
                let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                guard luma > 0.45 else { continue }
                total += (red + blue) / 2 - green
                samples += 1
            }
        }
        return samples > 0 ? total / samples : 0
    }

    private static func meanLuminance(_ buffer: PixelBuffer, rects: [CGRect]) -> Double {
        var total = 0.0, samples = 0.0
        for raw in rects {
            let rect = bufferRect(raw, buffer)
            guard rect.width > 1, rect.height > 1 else { continue }
            let step = max(1, min(rect.width, rect.height) / 12)
            for y in stride(from: rect.minY, to: rect.maxY, by: step) {
                for x in stride(from: rect.minX, to: rect.maxX, by: step) {
                    total += buffer.luminance(x: x, y: y)
                    samples += 1
                }
            }
        }
        return samples > 0 ? total / samples : 0
    }

    /// Mean over a rectangle already expressed in buffer pixels.
    private static func meanLuminance(_ buffer: PixelBuffer,
                                      x0: Int, x1: Int, y0: Int, y1: Int) -> Double {
        guard x1 > x0, y1 > y0 else { return 0 }
        let step = max(1, min(x1 - x0, y1 - y0) / 8)
        var total = 0.0, samples = 0.0
        for y in stride(from: y0, to: y1, by: step) {
            for x in stride(from: x0, to: x1, by: step) {
                total += buffer.luminance(x: x, y: y)
                samples += 1
            }
        }
        return samples > 0 ? total / samples : 0
    }

    // MARK: - Blemish detection

    /// Blemishes are found on a face-sized crop, in scale space.
    ///
    /// The first version scanned the 512 px analysis buffer. In a full-body
    /// photo a face is about 90 px wide there and an acne spot is one or two
    /// pixels — smaller than the compression blocks around it. What *is* large
    /// at that scale is everything the detector should ignore: a lens, a frame,
    /// a lock of hair. It found those, and the healing pass (which used the
    /// largest suggested radius for every stamp) smeared the face.
    ///
    /// This version instead:
    ///  1. runs on a face crop rendered at its own resolution, so a blemish is
    ///     a few pixels wide again while a lens is a large object;
    ///  2. builds a difference-of-Gaussians scale stack, which returns a size
    ///     for every blob — that size becomes the heal radius of that spot;
    ///  3. requires a candidate to be round (Hessian eigenvalue ratio), of skin
    ///     hue — both the spot and the ring around it — and surrounded by skin.
    ///     A frame is a line, a lens is another colour, hair is not skin: all
    ///     three fall out without needing an object detector.

    /// Spots suggested for one face, mapped back into working-image
    /// coordinates with the radius as a fraction of the short side.
    static func detectSpots(in crop: FaceCrop, limit: Int = 24) -> [Spot] {
        let raw = rawSpots(in: crop.buffer,
                           skin: crop.skin,
                           face: crop.faceRect,
                           exclusions: crop.exclusions,
                           limit: limit)
        let w = crop.workingSize.width
        let h = crop.workingSize.height
        let shortSide = Double(min(w, h))
        let bufferWidth = Double(crop.buffer.width)
        let bufferHeight = Double(crop.buffer.height)
        guard bufferWidth >= 1, bufferHeight >= 1, shortSide >= 1,
              crop.frame.width > 0, crop.frame.height > 0 else { return [] }

        let photoWidth = Double(crop.frame.width) * Double(w)
        let photoHeight = Double(crop.frame.height) * Double(h)
        return raw.map { spot in
            let photoX = Double(crop.frame.minX) * Double(w)
                + Double(spot.center.x) / bufferWidth * photoWidth
            let photoY = Double(crop.frame.minY) * Double(h)
                + Double(spot.center.y) / bufferHeight * photoHeight
            let radius = spot.radius / bufferWidth * photoWidth
            return Spot(center: CGPoint(x: CGFloat(photoX / Double(w)),
                                        y: CGFloat(photoY / Double(h))),
                        radius: CGFloat(radius / shortSide),
                        strength: spot.strength)
        }
    }

    /// Fallback for buffers that arrive without a crop (synthetic fixtures, or
    /// a face too small to render one). It uses the same detector, so it is
    /// safe, just less precise.
    static func detectSpots(in buffer: PixelBuffer,
                            mask: PixelBuffer?,
                            near face: FaceGeometry,
                            limit: Int = 24) -> [Spot] {
        let box = bufferRect(face.boundingBox, buffer)
        guard box.width > 8, box.height > 8 else { return [] }
        let exclusions = exclusionRects(for: face).compactMap { rect -> CGRect? in
            let r = bufferRect(rect, buffer)
            guard r.width > 0, r.height > 0 else { return nil }
            return CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height)
        }
        let raw = rawSpots(in: buffer,
                           skin: mask,
                           face: CGRect(x: box.minX, y: box.minY,
                                        width: box.width, height: box.height),
                           exclusions: exclusions,
                           limit: limit)
        let shortSide = Double(min(buffer.width, buffer.height))
        guard shortSide >= 1 else { return [] }
        return raw.map { spot in
            Spot(center: CGPoint(x: CGFloat(Double(spot.center.x) / Double(buffer.width)),
                                 y: CGFloat(Double(spot.center.y) / Double(buffer.height))),
                 radius: CGFloat(spot.radius / shortSide),
                 strength: spot.strength)
        }
    }

    /// Regions that must never be read as blemishes: eyes and lashes, brows,
    /// lips and the nostrils. Glasses cannot be masked geometrically, so the
    /// colour and roundness gates handle them instead.
    static func exclusionRects(for face: FaceGeometry) -> [CGRect] {
        var rects = face.shieldRects
        for brow in face.eyebrowPolygons {
            let box = FaceGeometry.boundingBox(of: brow)
            guard box.width > 0.001, box.height > 0.0001 else { continue }
            rects.append(box.insetBy(dx: -box.width * 0.15, dy: -box.height * 0.40))
        }
        // A mouth corner folds into a shadow as soon as the face smiles. The
        // crease is structure, not pigment, and lands just outside the lip
        // shield, so each corner gets its own small zone.
        if let lips = face.lipRect, lips.width > 0.001, lips.height > 0.001 {
            let w = lips.width * 0.15
            let h = lips.height * 0.50
            rects.append(CGRect(x: lips.minX - w, y: lips.midY - h / 2,
                                width: w, height: h))
            rects.append(CGRect(x: lips.maxX, y: lips.midY - h / 2,
                                width: w, height: h))
        }
        // The nose is a knot of creases, nostril rims and cast shadow, and
        // landmark geometry under-reports the wings. Nothing on the nose is
        // offered as a blemish; the manual brush still reaches it.
        let nose = face.noseRect
        if !nose.isNull, nose.width > 0.001, nose.height > 0.001 {
            rects.append(CGRect(x: nose.minX - nose.width * 0.28,
                                y: nose.minY - nose.height * 0.15,
                                width: nose.width * 1.56,
                                height: nose.height * 1.30))
        }
        // Glasses are not landmarks, and a rim below the eye reads as a dark
        // blob. Each lens is covered as its own box: the glass reaches past
        // the eye opening by most of an eye, so the box grows by more than
        // half an eye on every side. Keeping the boxes per eye — instead of
        // one band across the face — leaves the cheekbone and the temple
        // outside, where blemishes actually sit.
        let eyes = face.eyeRects.filter { !$0.isNull && $0.width > 0.001 }
        for eye in eyes {
            let w = max(eye.width, 0.004), h = max(eye.height, 0.004)
            rects.append(CGRect(x: eye.minX - w * 0.55,
                                y: eye.minY - h * 0.85,
                                width: w * 2.10,
                                height: h * 2.70))
        }
        // The bridge of a frame crosses the nose at eye height; it is short
        // and dark enough to pass as a spot without this strip.
        if eyes.count >= 2 {
            let innerLeft = eyes.map(\.maxX).min() ?? 0
            let innerRight = eyes.map(\.minX).max() ?? 0
            let top = eyes.map(\.maxY).max() ?? 0
            let bottom = eyes.map(\.minY).min() ?? 0
            let h = max(eyes.map(\.height).max() ?? 0.01, 0.004)
            if innerRight > innerLeft {
                rects.append(CGRect(x: innerLeft, y: bottom - h * 0.90,
                                    width: innerRight - innerLeft,
                                    height: (top - bottom) + h * 1.80))
            }
        }
        // Vision's box takes in the ears and the hair beside them, and the
        // jewellery that hangs there reads as a dark blob on skin. Blemish
        // work is about the central face; the manual brush still reaches
        // the edge of the jaw.
        let bb = face.boundingBox
        let eyeLow = eyes.map(\.minY).min() ?? (bb.midY)
        let side = bb.width * 0.08
        let sideHeight = max(0, eyeLow - bb.minY) + bb.height * 0.30
        if sideHeight > 0 {
            rects.append(CGRect(x: bb.minX, y: bb.minY, width: side, height: sideHeight))
            rects.append(CGRect(x: bb.maxX - side, y: bb.minY, width: side, height: sideHeight))
        }
        return rects
    }

    /// Marker positions for the report thumbnail, in crop-normalized units.
    private static func markers(for spots: [Spot], in crop: FaceCrop?) -> [SpotMarker] {
        guard let crop, let image = crop.image,
              crop.frame.width > 0, crop.frame.height > 0,
              crop.workingSize.width > 0, crop.workingSize.height > 0 else { return [] }
        let previewShort = Double(min(image.width, image.height))
        let workingShort = Double(min(crop.workingSize.width, crop.workingSize.height))
        guard previewShort > 1, workingShort > 1 else { return [] }
        return spots.compactMap { spot in
            let x = (Double(spot.center.x) - Double(crop.frame.minX)) / Double(crop.frame.width)
            let y = (Double(spot.center.y) - Double(crop.frame.minY)) / Double(crop.frame.height)
            guard x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
            return SpotMarker(center: CGPoint(x: CGFloat(x), y: CGFloat(y)),
                              radius: CGFloat(Double(spot.radius) * workingShort / previewShort))
        }
    }

    static func rawSpots(in buffer: PixelBuffer,
                         skin: PixelBuffer?,
                         face: CGRect,
                         exclusions: [CGRect],
                         limit: Int) -> [RawSpot] {
        let bw = buffer.width, bh = buffer.height
        let fx0 = max(1, Int(face.minX.rounded(.up)))
        let fx1 = min(bw - 2, Int(face.maxX.rounded(.down)))
        let fy0 = max(1, Int(face.minY.rounded(.up)))
        let fy1 = min(bh - 2, Int(face.maxY.rounded(.down)))
        guard fx1 - fx0 >= 12, fy1 - fy0 >= 12 else { return [] }
        let faceWidth = Double(fx1 - fx0)

        // Blob scales are a fraction of the face: a full-body face and a
        // close-up describe the same kind of skin in a different pixel count.
        // The floor keeps glasses rims, a nostril edge and a hoop of jewellery
        // — all a couple of pixels wide — out of the smallest scale, where
        // they are indistinguishable from a pinprick. A spot that small is
        // below what the report should offer; the manual brush still reaches it.
        let sigma0 = max(1.5, faceWidth * 0.006)
        let ladder = [sigma0, sigma0 * 1.6, sigma0 * 2.56]
        let maxSigma = ladder[ladder.count - 1]
        let pad = Int((maxSigma * 3).rounded(.up)) + 2
        let wx0 = max(0, fx0 - pad), wx1 = min(bw, fx1 + pad + 1)
        let wy0 = max(0, fy0 - pad), wy1 = min(bh, fy1 + pad + 1)
        let ww = wx1 - wx0, wh = wy1 - wy0
        guard ww > 8, wh > 8 else { return [] }

        var luma = [Double](repeating: 0, count: ww * wh)
        for y in 0..<wh {
            let row = y * ww
            for x in 0..<ww {
                let (r, g, b) = buffer.rgb(x: wx0 + x, y: wy0 + y)
                luma[row + x] = 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
        }

        var skinGate: [Bool]?
        if let skin, skin.width == bw, skin.height == bh {
            var gate = [Bool](repeating: false, count: ww * wh)
            for y in 0..<wh {
                let row = y * ww
                for x in 0..<ww where skin.luminance(x: wx0 + x, y: wy0 + y) > 0.45 {
                    gate[row + x] = true
                }
            }
            skinGate = gate
        }

        let faceRect = CGRect(x: fx0, y: fy0, width: fx1 - fx0, height: fy1 - fy0)
        let skinChroma = medianChroma(buffer, face: faceRect, skin: skin)

        var sigmas = ladder
        sigmas.append(maxSigma * 1.6)
        let blurred = sigmas.map { gaussianBlur(luma, width: ww, height: wh, sigma: $0) }

        var dogs: [[Double]] = []
        for k in 0..<ladder.count {
            var d = [Double](repeating: 0, count: ww * wh)
            let fine = blurred[k], coarse = blurred[k + 1]
            for i in 0..<(ww * wh) { d[i] = fine[i] - coarse[i] }
            dogs.append(d)
        }

        // The threshold clears the pores, not the blemishes: their energy is
        // what the local noise estimate already contains.
        var noiseSamples: [Double] = []
        noiseSamples.reserveCapacity(((fx1 - fx0) / 2 + 1) * ((fy1 - fy0) / 2 + 1))
        var ny = fy0
        while ny < fy1 {
            var nx = fx0
            while nx < fx1 {
                noiseSamples.append(abs(dogs[0][(ny - wy0) * ww + (nx - wx0)]))
                nx += 2
            }
            ny += 2
        }
        let threshold = min(0.050, max(0.014, medianOf(noiseSamples) * 4.0))

        // Long structures are not blemishes even when they curve: a glasses
        // frame is one connected dark line running across the eye, a hoop of
        // an earring is a ring, a lock of hair runs to the edge of the face.
        // The judgement has to be made at the scale the blob was found on: a
        // wire frame looks fragmented and round at the finest scale, yet is a
        // continuous line at its own width. A blemish is an isolated disc at
        // every scale, so anything whose same-scale component runs much wider
        // than the blob claims to be is structure, not pigment.
        struct Components {
            var labels: [Int]
            var boxes: [CGRect]
        }
        var components: [Components] = []
        for k in 0..<dogs.count {
            let componentLimit = max(0.008, threshold * (1 + 0.30 * Double(k)) * 0.55)
            var labels = [Int](repeating: -1, count: ww * wh)
            var boxes: [CGRect] = []
            var stack: [Int] = []
            for start in 0..<(ww * wh)
            where labels[start] < 0 && -dogs[k][start] >= componentLimit {
                let label = boxes.count
                var minX = ww, maxX = 0, minY = wh, maxY = 0
                labels[start] = label
                stack.append(start)
                while let index = stack.popLast() {
                    let x = index % ww, y = index / ww
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                    for dy in -1...1 {
                        let ny = y + dy
                        guard ny >= 0, ny < wh else { continue }
                        for dx in -1...1 {
                            let nx = x + dx
                            guard nx >= 0, nx < ww else { continue }
                            let j = ny * ww + nx
                            if labels[j] < 0, -dogs[k][j] >= componentLimit {
                                labels[j] = label
                                stack.append(j)
                            }
                        }
                    }
                }
                boxes.append(CGRect(x: minX, y: minY,
                                    width: maxX - minX + 1, height: maxY - minY + 1))
            }
            components.append(Components(labels: labels, boxes: boxes))
        }

        struct Candidate {
            var x: Double
            var y: Double
            var scale: Int
            var strength: Double
        }
        var candidates: [Candidate] = []

        for k in 0..<dogs.count {
            let d = dogs[k]
            let scaleThreshold = threshold * (1 + 0.30 * Double(k))
            for y in fy0..<fy1 {
                let row = (y - wy0) * ww - wx0
                for x in fx0..<fx1 {
                    let i = row + x
                    let v = d[i]
                    guard -v >= scaleThreshold else { continue }
                    // Minimum in the 3 × 3 neighbourhood and across scales: a
                    // blob is deepest at the scale that matches its size.
                    guard v <= d[i - 1], v <= d[i + 1],
                          v <= d[i - ww], v <= d[i + ww],
                          v <= d[i - ww - 1], v <= d[i - ww + 1],
                          v <= d[i + ww - 1], v <= d[i + ww + 1] else { continue }
                    if k > 0, v > dogs[k - 1][i] { continue }
                    if k + 1 < dogs.count, v > dogs[k + 1][i] { continue }
                    if isExcluded(Double(x), Double(y), exclusions) { continue }
                    if let skinGate, !skinGate[i] { continue }

                    // Roundness. A round blob curves the same way in both
                    // directions; a frame, a lash or a crease is flat along its
                    // length, which shows up as a near-zero minor curvature.
                    let b = blurred[k]
                    let lxx = b[i + 1] - 2 * b[i] + b[i - 1]
                    let lyy = b[i + ww] - 2 * b[i] + b[i - ww]
                    let lxy = (b[i + ww + 1] - b[i + ww - 1]
                               - b[i - ww + 1] + b[i - ww - 1]) * 0.25
                    guard lxx > 0, lyy > 0 else { continue }
                    let trace = lxx + lyy
                    let det = lxx * lyy - lxy * lxy
                    guard det > 0 else { continue }
                    let root = max(0, trace * trace - 4 * det).squareRoot()
                    let minor = (trace - root) / 2
                    let major = (trace + root) / 2
                    guard minor > 1e-9, major / minor <= 4.0 else { continue }

                    let radius = ladder[k] * 1.4142
                    // A dark line curving through the eye reaches far beyond
                    // its local blob width; a blemish does not.
                    let label = components[k].labels[i]
                    if label >= 0 {
                        let box = components[k].boxes[label]
                        let span = Double(max(box.width, box.height))
                        guard span <= max(14.0, radius * 9.0) else { continue }
                    }
                    // A blemish is a filled core, not one stray pixel that
                    // happens to be darker: the response has to cover the disc
                    // the scale claims. This is what keeps sensor grain and
                    // compression sparkle out of the suggestions.
                    if !hasDarkCore(d, width: ww, index: i, radius: radius,
                                    threshold: scaleThreshold * 0.4) { continue }
                    // The spot itself must be skin hue. This rejects a lens,
                    // a black frame and coloured reflections; a red pimple is
                    // allowed to lean a little warm.
                    let (ar, ag, ab) = averageColor(buffer, x: x, y: y,
                                                    radius: max(1, Int(radius.rounded())))
                    let sum = ar + ag + ab
                    guard sum > 0.12 else { continue }
                    guard hypot(ar / sum - skinChroma.r, ag / sum - skinChroma.g) < 0.12 else { continue }

                    // So must the ring around it, and that ring has to be skin
                    // rather than a lens surface or the hairline.
                    let ring = max(radius * 1.9, radius + 2)
                    var ringChroma: [(Double, Double)] = []
                    var ringLuma: [Double] = []
                    var ringOffsets: [(Double, Double)] = []
                    var ringSkin = 0, ringTotal = 0
                    for step in 0..<12 {
                        let angle = Double(step) * .pi / 6
                        let rx = x + Int((cos(angle) * ring).rounded())
                        let ry = y + Int((sin(angle) * ring).rounded())
                        guard rx > wx0, rx < wx1 - 1, ry > wy0, ry < wy1 - 1 else { continue }
                        ringTotal += 1
                        if let skinGate, skinGate[(ry - wy0) * ww + (rx - wx0)] { ringSkin += 1 }
                        let (rr, rg, rb) = buffer.rgb(x: rx, y: ry)
                        let rs = rr + rg + rb
                        guard rs > 0.12 else { continue }
                        ringChroma.append((rr / rs, rg / rs))
                        ringLuma.append(luma[(ry - wy0) * ww + (rx - wx0)])
                        ringOffsets.append((cos(angle), sin(angle)))
                    }
                    guard ringTotal >= 6 else { continue }
                    if skinGate != nil, Double(ringSkin) / Double(ringTotal) < 0.45 { continue }
                    guard !ringChroma.isEmpty else { continue }
                    let ringR = medianOf(ringChroma.map { $0.0 })
                    let ringG = medianOf(ringChroma.map { $0.1 })
                    guard hypot(ringR - skinChroma.r, ringG - skinChroma.g) < 0.095 else { continue }
                    // A blemish is a depression in smoothly shaded skin, so
                    // the ring around it follows the face's own gradient. When
                    // the ring crosses a glasses frame, a lens edge, a nostril
                    // rim or jewellery, a plane fitted to the ring leaves a
                    // large residual: structure, not pigment.
                    guard ringResidual(ringLuma, offsets: ringOffsets) <= 0.052 else { continue }

                    // Sub-pixel centre from the response around the extremum.
                    var weight = 0.0, sx = 0.0, sy = 0.0
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let w = max(0, -d[i + dy * ww + dx])
                            weight += w
                            sx += w * Double(x + dx)
                            sy += w * Double(y + dy)
                        }
                    }
                    guard weight > 0 else { continue }
                    let cx = sx / weight, cy = sy / weight
                    // The extremum can sit just outside an exclusion and still
                    // pull its centre back inside, so the final centre is what
                    // has to be clear of the eyes, lips and nose.
                    guard !isExcluded(cx, cy, exclusions) else { continue }
                    candidates.append(Candidate(x: cx, y: cy, scale: k, strength: -v))
                }
            }
        }

        var kept: [RawSpot] = []
        for candidate in candidates.sorted(by: { $0.strength > $1.strength }) {
            let radius = ladder[candidate.scale] * 1.4142
            // A smaller detection inside a larger one is the same blemish seen
            // at another scale (or a corner of a non-round patch), not a second
            // spot: the larger disc is what gets healed anyway.
            let overlaps = kept.contains {
                hypot(Double($0.center.x) - candidate.x,
                      Double($0.center.y) - candidate.y)
                    < max($0.radius, radius) * 1.05
            }
            guard !overlaps else { continue }
            // The stamp has to cover the blob's soft edge, but never grow into
            // a face-wide patch: 4.5% of the face width is already a big spot.
            let stampRadius = min(radius * 1.25, faceWidth * 0.045)
            kept.append(RawSpot(center: CGPoint(x: CGFloat(candidate.x),
                                                y: CGFloat(candidate.y)),
                                radius: stampRadius,
                                strength: candidate.strength))
            if kept.count >= limit { break }
        }
        return kept
    }

    private static func isExcluded(_ x: Double, _ y: Double, _ rects: [CGRect]) -> Bool {
        rects.contains { x >= Double($0.minX) && x <= Double($0.maxX)
                         && y >= Double($0.minY) && y <= Double($0.maxY) }
    }

    /// RMS distance of the ring samples from the best-fit plane through them.
    /// Smooth skin shading is nearly planar over a few pixels and fits closely;
    /// a hard edge crossing the ring cannot be fitted.
    private static func ringResidual(_ values: [Double],
                                     offsets: [(Double, Double)]) -> Double {
        let n = Double(values.count)
        guard n >= 6, values.count == offsets.count else { return 1 }
        var su = 0.0, sv = 0.0, suu = 0.0, svv = 0.0, suv = 0.0
        var sz = 0.0, suz = 0.0, svz = 0.0
        for (t, z) in zip(offsets, values) {
            su += t.0
            sv += t.1
            suu += t.0 * t.0
            svv += t.1 * t.1
            suv += t.0 * t.1
            sz += z
            suz += t.0 * z
            svz += t.1 * z
        }
        func det(_ a: [[Double]]) -> Double {
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1])
                - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
                + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let m = [[n, su, sv], [su, suu, suv], [sv, suv, svv]]
        let d = det(m)
        guard abs(d) > 1e-9 else { return 1 }
        let rhs = [sz, suz, svz]
        var coeffs = [0.0, 0.0, 0.0]
        for col in 0..<3 {
            var mc = m
            for row in 0..<3 { mc[row][col] = rhs[row] }
            coeffs[col] = det(mc) / d
        }
        var resid = 0.0
        for (t, z) in zip(offsets, values) {
            let fit = coeffs[0] + coeffs[1] * t.0 + coeffs[2] * t.1
            resid += (z - fit) * (z - fit)
        }
        return (resid / n).squareRoot()
    }

    /// True when at least half of the disc around an extremum carries a strong
    /// response. Grain produces a peak at one pixel; a blemish produces a
    /// filled core.
    private static func hasDarkCore(_ plane: [Double],
                                    width: Int,
                                    index: Int,
                                    radius: Double,
                                    threshold: Double) -> Bool {
        let r = max(1, Int(radius.rounded()))
        var inside = 0, strong = 0
        for dy in -r...r {
            for dx in -r...r where dx * dx + dy * dy <= r * r {
                let j = index + dy * width + dx
                guard j >= 0, j < plane.count else { continue }
                inside += 1
                if -plane[j] >= threshold { strong += 1 }
            }
        }
        guard inside > 0 else { return false }
        return Double(strong) / Double(inside) >= 0.50
    }

    /// Median skin hue of the face, as chromaticity. Median rather than mean so
    /// a few dark brows or a lens do not drag the reference.
    private static func medianChroma(_ buffer: PixelBuffer,
                                     face: CGRect,
                                     skin: PixelBuffer?) -> (r: Double, g: Double) {
        let hasSkin = skin.map { $0.width == buffer.width && $0.height == buffer.height } ?? false
        var reds: [Double] = [], greens: [Double] = []
        let x0 = max(0, Int(face.minX)), x1 = min(buffer.width, Int(face.maxX))
        let y0 = max(0, Int(face.minY)), y1 = min(buffer.height, Int(face.maxY))
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                if hasSkin, let skin, skin.luminance(x: x, y: y) < 0.5 {
                    x += 3
                    continue
                }
                let (r, g, b) = buffer.rgb(x: x, y: y)
                let sum = r + g + b
                if sum > 0.18, sum < 2.4 {
                    reds.append(r / sum)
                    greens.append(g / sum)
                }
                x += 3
            }
            y += 3
        }
        guard reds.count >= 30 else { return (1.0 / 3.0, 1.0 / 3.0) }
        return (medianOf(reds), medianOf(greens))
    }

    private static func averageColor(_ buffer: PixelBuffer,
                                     x: Int, y: Int, radius: Int) -> (Double, Double, Double) {
        let r = max(1, radius)
        var sumR = 0.0, sumG = 0.0, sumB = 0.0, count = 0.0
        for dy in -r...r {
            for dx in -r...r where dx * dx + dy * dy <= r * r {
                let (pr, pg, pb) = buffer.rgb(x: x + dx, y: y + dy)
                sumR += pr
                sumG += pg
                sumB += pb
                count += 1
            }
        }
        guard count > 0 else { return (0, 0, 0) }
        return (sumR / count, sumG / count, sumB / count)
    }

    /// Separable Gaussian, edge-clamped. The planes are small (a face crop), so
    /// the direct kernel is simpler and more predictable than an approximation.
    private static func gaussianBlur(_ source: [Double],
                                     width: Int, height: Int,
                                     sigma: Double) -> [Double] {
        let radius = max(1, Int((3 * sigma).rounded()))
        var kernel = [Double](repeating: 0, count: 2 * radius + 1)
        var kernelSum = 0.0
        for i in -radius...radius {
            let v = exp(-Double(i * i) / (2 * sigma * sigma))
            kernel[i + radius] = v
            kernelSum += v
        }
        for i in kernel.indices { kernel[i] /= kernelSum }

        var horizontal = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                var acc = 0.0
                for k in -radius...radius {
                    let xx = min(width - 1, max(0, x + k))
                    acc += source[row + xx] * kernel[k + radius]
                }
                horizontal[row + x] = acc
            }
        }

        var result = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var acc = 0.0
                for k in -radius...radius {
                    let yy = min(height - 1, max(0, y + k))
                    acc += horizontal[yy * width + x] * kernel[k + radius]
                }
                result[y * width + x] = acc
            }
        }
        return result
    }

    private static func medianOf(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    static func dedupe(_ spots: [Spot]) -> [Spot] {
        var kept: [Spot] = []
        for spot in spots.sorted(by: { $0.strength > $1.strength }) {
            let overlaps = kept.contains {
                hypot($0.center.x - spot.center.x, $0.center.y - spot.center.y)
                    <= max($0.radius, spot.radius)
            }
            if !overlaps { kept.append(spot) }
        }
        return kept
    }

    // MARK: - Geometry

    /// `FaceGeometry` is bottom-left oriented; `PixelBuffer` starts at the top
    /// row, so the y axis flips here and only here. A region a face did not
    /// provide (no nose landmarks, say) arrives as a null rect, which must
    /// collapse to an empty pixel range instead of trapping on the conversion.
    private static func bufferRect(_ rect: CGRect, _ buffer: PixelBuffer) -> (minX: Int, maxX: Int, minY: Int, maxY: Int, width: Int, height: Int) {
        let empty = (minX: 0, maxX: 0, minY: 0, maxY: 0, width: 0, height: 0)
        guard !rect.isNull,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { return empty }
        let w = Double(buffer.width), h = Double(buffer.height)
        let x0 = max(0, Int((rect.minX * CGFloat(w)).rounded(.down)))
        let x1 = min(buffer.width, Int((rect.maxX * CGFloat(w)).rounded(.up)))
        let y0 = max(0, Int(((1 - rect.maxY) * CGFloat(h)).rounded(.down)))
        let y1 = min(buffer.height, Int(((1 - rect.minY) * CGFloat(h)).rounded(.up)))
        return (x0, max(x0, x1), y0, max(y0, y1), max(0, x1 - x0), max(0, y1 - y0))
    }

    // MARK: - Copy

    private static func textureDetail(_ severity: Double) -> Finding.Detail {
        if severity > 0.6 { return .texturePronounced }
        if severity > 0.3 { return .textureVisible }
        return .textureFine
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(high, max(low, value))
    }
}

import CoreGraphics
import CoreImage
import Foundation

/// یک بافر پیکسلی ساده‌ی RGBA8 برای تحلیل آماری تصویر.
struct PixelBuffer {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytesPerPixel: Int
    let data: [UInt8]

    init?(cgImage: CGImage) {
        guard let data = cgImage.dataProvider?.data,
              let pointer = CFDataGetBytePtr(data) else { return nil }
        let bpp = max(1, cgImage.bitsPerPixel / 8)
        guard bpp >= 3 else { return nil }
        let length = CFDataGetLength(data)
        self.width = cgImage.width
        self.height = cgImage.height
        self.bytesPerRow = cgImage.bytesPerRow
        self.bytesPerPixel = bpp
        self.data = Array(UnsafeBufferPointer(start: pointer, count: length))
    }

    /// روشنایی پیکسل، بین ۰ و ۱. مقدار آلفا لحاظ نمی‌شود چون بافر RGBA8 بدون پیش‌ضرب است.
    func luminance(x: Int, y: Int) -> Double {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        let index = y * bytesPerRow + x * bytesPerPixel
        guard index + 2 < data.count else { return 0 }
        let r = Double(data[index]), g = Double(data[index + 1]), b = Double(data[index + 2])
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
    }

    func rgb(x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
        guard x >= 0, y >= 0, x < width, y < height else { return (0, 0, 0) }
        let index = y * bytesPerRow + x * bytesPerPixel
        guard index + 2 < data.count else { return (0, 0, 0) }
        return (Double(data[index]) / 255.0, Double(data[index + 1]) / 255.0, Double(data[index + 2]) / 255.0)
    }
}

/// Global image statistics used by Auto Color & Light.
struct ImageStats {
    var meanLuminance: Double = 0
    /// Median luminance. More robust than the mean on backlit or mostly dark
    /// frames, where a bright or dark background would otherwise dominate.
    var medianLuminance: Double = 0
    var lowLuminance: Double = 0      // 5th percentile
    var highLuminance: Double = 0     // 95th percentile
    var contrastSigma: Double = 0
    var meanSaturation: Double = 0
    var meanRed: Double = 0
    var meanBlue: Double = 0
    /// High-frequency energy; higher = sharper image.
    var detail: Double = 0
}

enum AutoAnalyzer {

    /// گام نمونه‌برداری تا تحلیل روی عکس‌های بزرگ سریع بماند.
    private static let analysisMaxDimension: CGFloat = 512

    // MARK: - ساخت بافر تحلیل

    static func analysisBuffer(_ image: CIImage) -> PixelBuffer? {
        let extent = image.extent
        guard extent.width >= 2, extent.height >= 2 else { return nil }
        let scale = min(1, analysisMaxDimension / max(extent.width, extent.height))
        let scaled = scale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image
        let zeroed = scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.origin.x,
                                                              y: -scaled.extent.origin.y))
        let w = max(2, Int(zeroed.extent.width.rounded()))
        let h = max(2, Int(zeroed.extent.height.rounded()))
        guard let cg = ImageProcessor.shared.renderCGImage(zeroed, scale: 1) else { return nil }
        _ = (w, h)
        return PixelBuffer(cgImage: cg)
    }

    // MARK: - آماره‌ها

    static func stats(_ buffer: PixelBuffer) -> ImageStats {
        var stats = ImageStats()
        let stepX = max(1, buffer.width / 256)
        let stepY = max(1, buffer.height / 256)

        var luminanceSum = 0.0, luminanceSquareSum = 0.0
        var saturationSum = 0.0, redSum = 0.0, blueSum = 0.0
        var detailSum = 0.0
        var samples = 0.0, detailSamples = 0.0
        var histogram = [Int](repeating: 0, count: 256)

        var y = 0
        while y < buffer.height {
            var x = 0
            while x < buffer.width {
                let (r, g, b) = buffer.rgb(x: x, y: y)
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                luminanceSum += luma
                luminanceSquareSum += luma * luma
                histogram[min(255, max(0, Int(luma * 255)))] += 1
                redSum += r
                blueSum += b

                let maxChannel = max(r, max(g, b))
                let minChannel = min(r, min(g, b))
                saturationSum += maxChannel > 0.0001 ? (maxChannel - minChannel) / maxChannel : 0
                samples += 1

                if x + stepX < buffer.width {
                    let right = buffer.luminance(x: x + stepX, y: y)
                    detailSum += abs(luma - right)
                    detailSamples += 1
                }
                x += stepX
            }
            y += stepY
        }

        guard samples > 0 else { return stats }
        let mean = luminanceSum / samples
        let variance = max(0, luminanceSquareSum / samples - mean * mean)
        stats.meanLuminance = mean
        stats.medianLuminance = percentile(histogram, fraction: 0.50, total: Int(samples))
        stats.lowLuminance = percentile(histogram, fraction: 0.05, total: Int(samples))
        stats.highLuminance = percentile(histogram, fraction: 0.95, total: Int(samples))
        stats.contrastSigma = variance.squareRoot()
        stats.meanSaturation = saturationSum / samples
        stats.meanRed = redSum / samples
        stats.meanBlue = blueSum / samples
        stats.detail = detailSamples > 0 ? detailSum / detailSamples : 0
        return stats
    }

    /// «زبری» بافت پوست در نواحی‌ای که ماسک سفید است.
    /// عدد بزرگ‌تر = بافت/منافذ بیشتر.
    static func skinRoughness(_ buffer: PixelBuffer, mask: PixelBuffer?) -> Double? {
        let step = max(1, buffer.width / 200)
        var total = 0.0
        var samples = 0.0

        var y = step
        while y < buffer.height - step {
            var x = step
            while x < buffer.width - step {
                let isSkin: Bool
                if let mask, mask.width == buffer.width, mask.height == buffer.height {
                    isSkin = mask.luminance(x: x, y: y) > 0.5
                } else {
                    isSkin = true
                }
                if isSkin {
                    let center = buffer.luminance(x: x, y: y)
                    let right = buffer.luminance(x: x + step, y: y)
                    let up = buffer.luminance(x: x, y: y + step)
                    total += abs(center - right) + abs(center - up)
                    samples += 2
                }
                x += step
            }
            y += step
        }
        guard samples > 0 else { return nil }
        return total / samples
    }

    /// Median luminance inside the skin mask. Percentile-based so a few dark
    /// features (lashes, shadowed nostrils) cannot drag the estimate down the
    /// way an average would.
    static func skinMedianLuminance(_ buffer: PixelBuffer, mask: PixelBuffer?) -> Double? {
        guard let mask, mask.width == buffer.width, mask.height == buffer.height else { return nil }
        let step = max(1, buffer.width / 200)
        var histogram = [Int](repeating: 0, count: 256)
        var samples = 0
        var y = 0
        while y < buffer.height {
            var x = 0
            while x < buffer.width {
                if mask.luminance(x: x, y: y) > 0.5 {
                    let luma = buffer.luminance(x: x, y: y)
                    histogram[min(255, max(0, Int(luma * 255)))] += 1
                    samples += 1
                }
                x += step
            }
            y += step
        }
        guard samples > 0 else { return nil }
        return percentile(histogram, fraction: 0.50, total: samples)
    }

    private static func percentile(_ histogram: [Int], fraction: Double, total: Int) -> Double {
        guard total > 0 else { return 0 }
        let target = Int((Double(total - 1) * fraction).rounded())
        var cumulative = 0
        for (index, count) in histogram.enumerated() {
            cumulative += count
            if cumulative > target { return Double(index) / 255.0 }
        }
        return 1
    }

    // MARK: - Teeth visibility

    /// Annotates every face with whether its inner-mouth region actually shows
    /// teeth. Measured across the portrait fixtures: the fraction of bright,
    /// low-saturation pixels inside the inner lip separates open smiles (>= 0.43)
    /// from closed mouths (<= 0.29), while lip geometry does not (a closed mouth
    /// can look as "open" as a smile).
    static func annotateTeeth(faces: [FaceGeometry], buffer: PixelBuffer) -> [FaceGeometry] {
        faces.map { face in
            var annotated = face
            annotated.hasVisibleTeeth = face.mouthOpenness > 0.25
                && visibleTeethFraction(buffer: buffer, face: face) > 0.32
            return annotated
        }
    }

    static func visibleTeethFraction(buffer: PixelBuffer, face: FaceGeometry) -> Double {
        guard let rect = face.teethRect, rect.width > 0, rect.height > 0 else { return 0 }
        let width = Double(buffer.width), height = Double(buffer.height)
        let x0 = max(0, Int(rect.minX * width))
        let x1 = min(buffer.width - 1, Int(rect.maxX * width))
        // PixelBuffer rows are top-down; FaceGeometry is bottom-left oriented.
        let y0 = max(0, Int((1 - rect.maxY) * height))
        let y1 = min(buffer.height - 1, Int((1 - rect.minY) * height))
        guard x1 > x0, y1 > y0 else { return 0 }

        let stepX = max(1, (x1 - x0) / 48)
        let stepY = max(1, (y1 - y0) / 24)
        var bright = 0.0
        var total = 0.0

        var y = y0
        while y <= y1 {
            var x = x0
            while x <= x1 {
                let (r, g, b) = buffer.rgb(x: x, y: y)
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let maxChannel = max(r, max(g, b))
                let minChannel = min(r, min(g, b))
                let saturation = maxChannel > 0.0001 ? (maxChannel - minChannel) / maxChannel : 0
                if luma > 0.45 && saturation < 0.30 { bright += 1 }
                total += 1
                x += stepX
            }
            y += stepY
        }
        guard total > 0 else { return 0 }
        return bright / total
    }

    // MARK: - Eye brightness

    /// Measures where sclera sits in luminance for each face. An absolute
    /// threshold cannot work for both a pale and a deep skin tone, so the
    /// split is taken from the eye opening itself: the dark part of the
    /// histogram is iris, lashes and lid line; the bright part is sclera.
    static func annotateEyes(faces: [FaceGeometry], buffer: PixelBuffer) -> [FaceGeometry] {
        faces.map { face in
            var annotated = face
            if let split = eyeLuminanceSplit(buffer: buffer, face: face) {
                annotated.eyeScleraLuminance = split
                annotated.hasUsableEyes = true
            }
            return annotated
        }
    }

    /// 30th percentile of luminance inside the inner half of each eye opening,
    /// nudged up slightly so iris pixels stay below it. Returns nil when the
    /// eyes are closed or too small to measure.
    static func eyeLuminanceSplit(buffer: PixelBuffer, face: FaceGeometry) -> Double? {
        var histogram = [Int](repeating: 0, count: 256)
        var samples = 0

        for eye in face.eyePolygons {
            let box = FaceGeometry.boundingBox(of: eye)
            guard box.width > 0.005, box.height > 0.003 else { continue }
            // Inner half of the opening: mostly sclera and iris, no lid skin.
            let inner = CGRect(x: box.midX - box.width * 0.28,
                               y: box.midY - box.height * 0.30,
                               width: box.width * 0.56,
                               height: box.height * 0.60)
            let width = Double(buffer.width), height = Double(buffer.height)
            let x0 = max(0, Int(inner.minX * width))
            let x1 = min(buffer.width - 1, Int(inner.maxX * width))
            let y0 = max(0, Int((1 - inner.maxY) * height))
            let y1 = min(buffer.height - 1, Int((1 - inner.minY) * height))
            guard x1 > x0, y1 > y0 else { continue }

            var y = y0
            while y <= y1 {
                var x = x0
                while x <= x1 {
                    let luma = buffer.luminance(x: x, y: y)
                    histogram[min(255, max(0, Int(luma * 255)))] += 1
                    samples += 1
                    x += max(1, (x1 - x0) / 16)
                }
                y += max(1, (y1 - y0) / 8)
            }
        }

        guard samples >= 24 else { return nil }
        let low = percentile(histogram, fraction: 0.30, total: samples)
        return min(0.82, max(0.30, low + 0.04))
    }

    // MARK: - خودکار ۱: رنگ و نور

    /// What the tonality of the picture actually is, measured where the subject
    /// sits rather than where the frame happens to be brightest.
    struct TonalReadout {
        var black: Double = 0          // 0.5th percentile of the subject histogram
        var white: Double = 1          // 99.5th percentile
        var median: Double = 0.5
        var interQuartile: Double = 0  // 25th to 75th: the slope through the mid-tones
        var saturation: Double = 0
        /// Mean channels of the near-neutral mid-tones — the reference a grey
        /// world balance needs. `neutralShare` says whether there were enough.
        var neutral = SIMD3<Double>(repeating: 0)
        var neutralShare: Double = 0
        var detail: Double = 0
        var shadowClip: Double = 0     // share of pixels already sitting on the floor
        var highlightClip: Double = 0
    }

    /// Samples the frame with a soft weight toward the middle: the subject of a
    /// portrait is there, and a bright sky or a black wall at the edge is not
    /// what the exposure was set for.
    static func readTones(_ buffer: PixelBuffer) -> TonalReadout {
        var readout = TonalReadout()
        let stepX = max(1, buffer.width / 256)
        let stepY = max(1, buffer.height / 256)

        var histogram = [Double](repeating: 0, count: 256)
        var weightTotal = 0.0
        var saturation = 0.0, detail = 0.0, detailSamples = 0.0
        var clippedShadows = 0.0, clippedHighlights = 0.0
        var neutral = SIMD3<Double>(repeating: 0), neutralWeight = 0.0

        var y = 0
        while y < buffer.height {
            let ny = (Double(y) + 0.5) / Double(buffer.height)
            var x = 0
            while x < buffer.width {
                let nx = (Double(x) + 0.5) / Double(buffer.width)
                // 1 at the centre, 0.3 in the corners.
                let d = (nx - 0.5) * (nx - 0.5) + (ny - 0.5) * (ny - 0.5)
                let weight = 1 - 0.7 * min(1, d / 0.5)

                let (r, g, b) = buffer.rgb(x: x, y: y)
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                histogram[min(255, max(0, Int(luma * 255)))] += weight
                weightTotal += weight
                if luma < 0.008 { clippedShadows += weight }
                if luma > 0.992 { clippedHighlights += weight }

                let maxChannel = max(r, max(g, b))
                let minChannel = min(r, min(g, b))
                let sat = maxChannel > 0.0001 ? (maxChannel - minChannel) / maxChannel : 0
                saturation += sat * weight

                // Grey-world on the near-neutral mid-tones only. Skin, foliage
                // and sky are chromatic by nature, and averaging them in is what
                // pulls a whole frame toward orange or blue.
                if luma > 0.22 && luma < 0.9 && sat < 0.16 {
                    neutral += SIMD3(r, g, b) * weight
                    neutralWeight += weight
                }

                if x + stepX < buffer.width {
                    detail += abs(luma - buffer.luminance(x: x + stepX, y: y)) * weight
                    detailSamples += weight
                }
                x += stepX
            }
            y += stepY
        }

        guard weightTotal > 0 else { return readout }
        readout.black = weightedPercentile(histogram, fraction: 0.005, total: weightTotal)
        readout.white = weightedPercentile(histogram, fraction: 0.995, total: weightTotal)
        readout.median = weightedPercentile(histogram, fraction: 0.50, total: weightTotal)
        readout.interQuartile = weightedPercentile(histogram, fraction: 0.75, total: weightTotal)
            - weightedPercentile(histogram, fraction: 0.25, total: weightTotal)
        readout.saturation = saturation / weightTotal
        readout.detail = detailSamples > 0 ? detail / detailSamples : 0
        readout.shadowClip = clippedShadows / weightTotal
        readout.highlightClip = clippedHighlights / weightTotal
        if neutralWeight > 0 {
            readout.neutral = neutral / neutralWeight
            readout.neutralShare = neutralWeight / weightTotal
        }
        return readout
    }

    /// تنظیمات «رنگ و نور» را از روی خوانش بالا حساب می‌کند.
    /// هیچ فیلد مربوط به پوست/چهره را دست نمی‌زند.
    static func autoColorLight(_ buffer: PixelBuffer) -> Adjustments {
        let t = readTones(buffer)
        var a = Adjustments()

        // 1) Endpoints. A faded picture is one whose darkest and brightest
        //    pixels stop short of the ends of the range, so the fix is to move
        //    the ends to meet them. Pulling the median toward mid-grey — what
        //    this function used to do — lifts the blacks instead and makes the
        //    fade worse. The levels pass that applies this only touches the two
        //    ends, so recovering a bright wall cannot brighten a face. The
        //    stretch backs off wherever the frame is already clipped, because
        //    there is nothing left to recover there.
        let black = min(0.30, max(0, t.black))
        let white = max(0.70, min(1, t.white))
        let roomAtBottom = t.shadowClip < 0.01
        let roomAtTop = t.highlightClip < 0.01
        if roomAtBottom, black > 0.03 { a.blacks = clamp(black / 0.30 * 100, 0, 100) }
        if roomAtTop, white < 0.97 { a.whites = clamp((1 - white) / 0.30 * 100, 0, 100) }

        // 2) Mid-tone slope. The endpoints set the range; this sets how steep
        //    the picture is through the middle, and it is deliberately
        //    one-directional — flattening a frame automatically is a taste call.
        a.contrast = clamp((0.17 - t.interQuartile) * 220, 0, 26)

        // 3) Exposure, and only outside a dead band. A frame whose mid-tones
        //    already sit in the comfortable range is left exactly where the
        //    photographer put it; a high-key or low-key picture is an intention,
        //    not an error, and dragging it to grey is the failure this whole
        //    function used to have. Underexposure is corrected harder than
        //    overexposure because it is almost never on purpose.
        let lowerBand = 0.32, upperBand = 0.62
        if t.median < lowerBand {
            a.exposure = clamp((lowerBand - t.median) * 90, 0, 30)
        } else if t.median > upperBand {
            a.exposure = -clamp((t.median - upperBand) * 45, 0, 14)
        }

        // 4) White balance from the near-neutral mid-tones. Needs at least two
        //    percent of the frame to be genuinely grey; a saturated scene has no
        //    neutral reference, and inventing one is worse than not balancing.
        if t.neutralShare > 0.02, t.neutral.x > 0.02, t.neutral.z > 0.02 {
            // Positive warmth takes a blue cast out — checked against the
            // filter, not assumed.
            a.warmth = clamp(log(t.neutral.z / t.neutral.x) * 130, -20, 20)
        }

        // 5) Colour. Vibrance raises the dull colours and leaves the strong ones
        //    alone, which is what keeps skin from going orange. Saturation only
        //    ever comes down, and only from a garish frame.
        a.vibrance = clamp((0.30 - t.saturation) * 70 + 4, 0, 22)
        a.saturation = t.saturation > 0.62 ? clamp((0.62 - t.saturation) * 60, -18, 0) : 0

        // 6) A soft frame gets a little local contrast back; a detailed one is
        //    left as it is.
        a.clarity = t.detail < 0.012 ? clamp((0.012 - t.detail) * 900, 0, 12) : 0

        // وینیت سلیقه‌ای است؛ دست نمی‌خورد.
        a.vignette = 0

        // «همین الان متوازن است» یک جواب واقعی است. وقتی همهٔ اسلایدرها دو-سه
        // واحد تکان می‌خورند، نتیجه فقط جابه‌جا شدن بی‌دلیلِ عکس است.
        let movement = abs(a.exposure) + abs(a.contrast) + abs(a.blacks) + abs(a.whites)
            + abs(a.saturation) + abs(a.vibrance) + abs(a.warmth) + abs(a.clarity)
        return movement < 12 ? Adjustments() : a
    }

    private static func weightedPercentile(_ histogram: [Double], fraction: Double,
                                           total: Double) -> Double {
        guard total > 0 else { return 0 }
        let target = (total - 1) * fraction
        var cumulative = 0.0
        for (index, weight) in histogram.enumerated() {
            cumulative += weight
            if cumulative > target { return Double(index) / 255.0 }
        }
        return 1
    }

    // MARK: - خودکار ۲: رتوش چهره

    /// Derives skin, eye and teeth values from the detected face. `skinMask`
    /// must be the *skin* mask (face minus eyes, brows and lips), not the whole
    /// face silhouette: lashes, lips and hair are not skin and would otherwise
    /// skew the texture and brightness measurements. No color/light field is
    /// touched.
    static func autoRetouch(_ buffer: PixelBuffer,
                            skinMask: PixelBuffer?,
                            faces: [FaceGeometry],
                            globalMedianLuminance: Double) -> Adjustments {
        var a = Adjustments()
        guard !faces.isEmpty else { return a }

        // An eye outline alone is not enough: a face seen from behind, an eye
        // closed, or an eye too small to measure all still report landmarks.
        // Eye work is gated on the same pixel measurement that sets the sclera
        // split, so it only ever runs where there is a real eye to brighten.
        let hasEyes = faces.contains { $0.hasUsableEyes }
        let hasVisibleTeeth = faces.contains { $0.hasVisibleTeeth }

        let roughness = skinRoughness(buffer, mask: skinMask) ?? 0.012

        // Smoothing from measured skin roughness, capped low: heavy smoothing is
        // the main reason retouches look plastic, so the automatic value stays
        // conservative and always keeps a high texture-preserve setting.
        a.smooth = clamp((roughness - 0.004) * 2200, 10, 34)
        a.texturePreserve = clamp(92 - a.smooth * 0.6, 58, 92)

        // Spots: milder than smoothing, since a median already removes the
        // obvious ones and over-doing it erases freckles.
        a.blemish = clamp((roughness - 0.003) * 1700, 8, 42)

        // Wrinkles: present mainly in older or higher-detail skin.
        a.wrinkle = clamp((roughness - 0.005) * 900, 0, 28)

        // Tone evening and dark circles: presence-based, better safe than
        // blotchy.
        a.skinToneEvens = clamp(18 + (roughness - 0.008) * 900, 10, 34)
        a.darkCircles = clamp(14 + (roughness - 0.008) * 700, 8, 30)

        // Brightness: only lift if the face is darker than the frame (backlit).
        if let skinMedian = skinMedianLuminance(buffer, mask: skinMask) {
            a.skinBrighten = clamp((globalMedianLuminance - skinMedian) * 200, -16, 20)
        }

        // Whitening is meaningless when the mouth is closed: the teeth mask
        // would cover the lips instead, so it is gated on visible teeth.
        a.teethWhiten = hasVisibleTeeth ? 16 : 0
        a.eyeBrighten = hasEyes ? 12 : 0
        a.eyeSharpen = hasEyes ? 16 : 0
        return a
    }

    // MARK: - Skin tone

    /// Mean luminance of bare cheek skin, used to open the makeup palette on
    /// the colour family mixed for this face.
    ///
    /// The blush rects sit on cheek, away from lips, eyes and hair, and both
    /// sides are averaged so a light coming from one direction does not decide
    /// the family. Reads the same 8-bit sRGB pixels the palettes were written
    /// against.
    static func cheekLuminance(_ image: CGImage, face: FaceGeometry) -> Double? {
        guard let buffer = PixelBuffer(cgImage: image) else { return nil }
        var sum = 0.0
        var samples = 0.0
        for rect in [face.leftBlushRect, face.rightBlushRect] {
            // Face geometry is bottom-left; the bitmap starts at the top row.
            let x0 = Int((rect.minX * CGFloat(buffer.width)).rounded())
            let x1 = Int((rect.maxX * CGFloat(buffer.width)).rounded())
            let y0 = Int(((1 - rect.maxY) * CGFloat(buffer.height)).rounded())
            let y1 = Int(((1 - rect.minY) * CGFloat(buffer.height)).rounded())
            guard x1 > x0, y1 > y0 else { continue }
            let stepX = max(1, (x1 - x0) / 12)
            let stepY = max(1, (y1 - y0) / 12)
            var y = max(0, y0)
            while y < min(buffer.height, y1) {
                var x = max(0, x0)
                while x < min(buffer.width, x1) {
                    sum += buffer.luminance(x: x, y: y)
                    samples += 1
                    x += stepX
                }
                y += stepY
            }
        }
        guard samples >= 20 else { return nil }
        return sum / samples
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(high, max(low, value))
    }
}

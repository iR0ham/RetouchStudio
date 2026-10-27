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

    // MARK: - خودکار ۱: رنگ و نور

    /// تنظیمات «رنگ و نور» را از روی آماره‌های خود تصویر حساب می‌کند.
    /// هیچ فیلد مربوط به پوست/چهره را دست نمی‌زند.
    static func autoColorLight(_ buffer: PixelBuffer) -> Adjustments {
        let s = stats(buffer)
        var a = Adjustments()

        // Exposure: bring the median toward 0.5, but only part of the way so
        // very dark or very bright photos are not destroyed.
        // Scale: 100 units = 0.30 EV.
        if s.medianLuminance > 0.001 {
            let evNeeded = log2(0.5 / max(0.02, s.medianLuminance))
            a.exposure = clamp(evNeeded / 0.30 * 100 * 0.65, -45, 45)
        }

        // کنتراست: انحراف معیار کم = تصویر تخت = کنتراست بیشتر لازم دارد.
        a.contrast = clamp((0.21 - s.contrastSigma) * 380, -45, 55)

        // اشباع رنگ: رنگ‌پریده‌ها را تقویت کن.
        a.saturation = clamp((0.34 - s.meanSaturation) * 190, -40, 55)

        // شادابی: همیشه کمی، بدون اغراق.
        a.vibrance = clamp((0.34 - s.meanSaturation) * 90 + 6, 0, 35)

        // گرمی رنگ: اگر آبی از قرمز بیشتر باشد عکس سرد است.
        a.warmth = clamp((s.meanBlue - s.meanRed) * 170, -40, 40)

        // شفافیت: عکس‌های نرم کمی وضوح می‌خواهند، عکس‌های پرجزئیات نه.
        a.clarity = clamp((0.045 - s.detail) * 700, -10, 30)

        // وینیت دست نمی‌خورد؛ سلیقه‌ای است.
        a.vignette = 0
        return a
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

        let hasEyes = faces.contains { !$0.eyePolygons.isEmpty }
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

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(high, max(low, value))
    }
}

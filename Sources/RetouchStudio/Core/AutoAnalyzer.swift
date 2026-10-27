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

/// آماره‌های سراسری تصویر که برای «خودکار رنگ و نور» لازم است.
struct ImageStats {
    var meanLuminance: Double = 0
    var contrastSigma: Double = 0
    var meanSaturation: Double = 0
    var meanRed: Double = 0
    var meanBlue: Double = 0
    /// انرژی فرکانس بالا؛ عدد بزرگ‌تر = تصویر واضح‌تر.
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

        var y = 0
        while y < buffer.height {
            var x = 0
            while x < buffer.width {
                let (r, g, b) = buffer.rgb(x: x, y: y)
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                luminanceSum += luma
                luminanceSquareSum += luma * luma
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

    /// میانگین روشنایی داخل نواحی پوست.
    static func skinMeanLuminance(_ buffer: PixelBuffer, mask: PixelBuffer?) -> Double? {
        guard let mask, mask.width == buffer.width, mask.height == buffer.height else { return nil }
        let step = max(1, buffer.width / 200)
        var total = 0.0
        var samples = 0.0
        var y = 0
        while y < buffer.height {
            var x = 0
            while x < buffer.width {
                if mask.luminance(x: x, y: y) > 0.5 {
                    total += buffer.luminance(x: x, y: y)
                    samples += 1
                }
                x += step
            }
            y += step
        }
        guard samples > 0 else { return nil }
        return total / samples
    }

    // MARK: - خودکار ۱: رنگ و نور

    /// تنظیمات «رنگ و نور» را از روی آماره‌های خود تصویر حساب می‌کند.
    /// هیچ فیلد مربوط به پوست/چهره را دست نمی‌زند.
    static func autoColorLight(_ buffer: PixelBuffer) -> Adjustments {
        let s = stats(buffer)
        var a = Adjustments()

        // نوردهی: میانگین روشنایی را به سمت ۰٫۵ ببر، ولی فقط بخشی از راه
        // تا عکس‌های خیلی تاریک یا روشن خراب نشوند.
        // مقیاس: ۱۰۰ واحد = ۰٫۳۰ EV
        if s.meanLuminance > 0.001 {
            let evNeeded = log2(0.5 / max(0.02, s.meanLuminance))
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

    /// تنظیمات مربوط به پوست، دندان و چشم را از روی چهره‌ی شناسایی‌شده حساب می‌کند.
    /// هیچ فیلد رنگ/نوری را دست نمی‌زند.
    static func autoRetouch(_ buffer: PixelBuffer,
                            faceMask: PixelBuffer?,
                            faces: [FaceGeometry],
                            globalMeanLuminance: Double) -> Adjustments {
        var a = Adjustments()
        guard !faces.isEmpty else { return a }

        let hasEyes = faces.contains { !$0.eyePolygons.isEmpty }
        let hasLips = faces.contains { $0.lipPolygon.count >= 3 }

        let roughness = skinRoughness(buffer, mask: faceMask) ?? 0.012

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
        if let skinMean = skinMeanLuminance(buffer, mask: faceMask) {
            a.skinBrighten = clamp((globalMeanLuminance - skinMean) * 200, -16, 20)
        }

        a.teethWhiten = hasLips ? 16 : 0
        a.eyeBrighten = hasEyes ? 12 : 0
        a.eyeSharpen = hasEyes ? 16 : 0
        return a
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(high, max(low, value))
    }
}

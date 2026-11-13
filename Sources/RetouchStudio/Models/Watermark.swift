import CoreGraphics
import CoreImage
import CoreText
import Foundation
import StudioCore

/// Draws the watermark tile once, at the export's own pixel size, and
/// composites it over the finished photo. Core Text keeps the work off the main
/// thread: exports run detached, and AppKit text drawing does not.
enum WatermarkRenderer {

    static func apply(_ settings: WatermarkSettings, to image: CIImage) -> CIImage {
        let text = settings.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.isActive else { return image }
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return image }

        let shortSide = min(extent.width, extent.height)
        let pointSize = max(8, shortSide * CGFloat(settings.sizePercent) / 100)
        let font = makeFont(size: pointSize)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            ]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard width > 0 else { return image }

        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        let padding = max(2, pointSize * 0.22)
        let tileWidth = Int(ceil(width + padding * 2))
        let tileHeight = Int(ceil(ascent + descent + leading + padding * 2))
        guard tileWidth > 0, tileHeight > 0,
              let tile = drawTile(line, width: tileWidth, height: tileHeight,
                                  baseline: padding + descent,
                                  pointSize: pointSize,
                                  opacity: CGFloat(min(1, max(0, settings.opacity))),
                                  padding: padding)
        else { return image }

        let margin = shortSide * 0.035
        let tileSize = CGSize(width: CGFloat(tileWidth), height: CGFloat(tileHeight))
        let origin: CGPoint
        switch settings.position {
        case .topLeft:
            origin = CGPoint(x: extent.minX + margin,
                             y: extent.maxY - margin - tileSize.height)
        case .topRight:
            origin = CGPoint(x: extent.maxX - margin - tileSize.width,
                             y: extent.maxY - margin - tileSize.height)
        case .bottomLeft:
            origin = CGPoint(x: extent.minX + margin, y: extent.minY + margin)
        case .bottomRight:
            origin = CGPoint(x: extent.maxX - margin - tileSize.width,
                             y: extent.minY + margin)
        case .center:
            origin = CGPoint(x: extent.midX - tileSize.width / 2,
                             y: extent.midY - tileSize.height / 2)
        }
        let placed = CIImage(cgImage: tile)
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
        return placed.composited(over: image)
    }

    /// The system UI font keeps Latin and Persian watermarks shaped by Core
    /// Text's cascade, and falls back to a bundled face if it is unavailable.
    private static func makeFont(size: CGFloat) -> CTFont {
        if let system = CTFontCreateUIFontForLanguage(.system, size, nil) {
            return CTFontCreateCopyWithSymbolicTraits(system, size, nil, .boldTrait, .boldTrait)
                ?? system
        }
        return CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private static func drawTile(_ line: CTLine, width: Int, height: Int,
                                 baseline: CGFloat, pointSize: CGFloat,
                                 opacity: CGFloat, padding: CGFloat) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let image: CGImage? = pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            // A soft dark edge keeps white text readable on light backgrounds.
            context.setShadow(offset: CGSize(width: 0, height: -max(1, pointSize * 0.05)),
                              blur: max(2, pointSize * 0.10),
                              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55 * opacity))
            context.setAlpha(opacity)
            context.textPosition = CGPoint(x: padding, y: baseline)
            CTLineDraw(line, context)
            return context.makeImage()
        }
        return image
    }
}

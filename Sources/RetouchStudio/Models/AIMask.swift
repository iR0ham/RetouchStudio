import CoreGraphics
import CoreImage
import Foundation

/// How the owner marks the region a Quick Edit may touch.
enum AIMaskTool: String, CaseIterable, Identifiable {
    case point
    case brush
    case box

    var id: String { rawValue }

    var title: String {
        switch self {
        case .point: return L10n.current.aiMaskPoint
        case .brush: return L10n.current.aiMaskBrush
        case .box: return L10n.current.aiMaskBox
        }
    }

    var icon: String {
        switch self {
        case .point: return "scope"
        case .brush: return "paintbrush.pointed"
        case .box: return "rectangle.dashed"
        }
    }
}

/// One brush stroke in normalized photo coordinates, top-left origin.
/// `width` is a fraction of the photo width so a stroke keeps its size when the
/// mask is rendered at working or export resolution.
struct AIMaskStroke: Equatable {
    var points: [CGPoint]
    var width: CGFloat
    var erase: Bool
}

/// Everything the owner drew, in one value so the runner can render it at the
/// working size without reaching back into the editor.
struct AIMaskSelection {
    var strokes: [AIMaskStroke] = []
    var box: CGRect?
    var refined: CGImage?
    var inverted: Bool = false

    var hasContent: Bool {
        refined != nil || box != nil || !strokes.isEmpty
    }
}

/// Turns a selection into the two forms the app needs: an opaque grayscale
/// plane for the worker (white = may change) and an alpha plane for the tinted
/// canvas preview.
enum AIMaskRenderer {
    static func mask(size: CGSize, strokes: [AIMaskStroke], box: CGRect?,
                     refined: CGImage?, inverted: Bool) -> CGImage? {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }

        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        if let refined {
            context.interpolationQuality = .high
            context.draw(refined, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        if let box {
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(contextRect(box, width: width, height: height))
        }
        for stroke in strokes {
            draw(stroke, in: context, width: width, height: height)
        }

        guard let image = context.makeImage() else { return nil }
        guard inverted else { return image }

        // CIColorInvert would hand back an RGBA plane; the worker expects the
        // same 8-bit gray plane either way, so invert in place with a
        // difference blend against white.
        guard let invertedContext = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return image }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        invertedContext.setFillColor(gray: 1, alpha: 1)
        invertedContext.fill(full)
        invertedContext.setBlendMode(.difference)
        invertedContext.draw(image, in: full)
        return invertedContext.makeImage() ?? image
    }

    /// White pixels with an alpha channel, so SwiftUI can tint the selection
    /// with the theme accent and nothing else in the photo changes.
    static func alphaMask(_ mask: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: mask).applyingFilter("CIMaskToAlpha")
        return CIContext(options: nil).createCGImage(ci, from: ci.extent)
    }

    private static func contextRect(_ box: CGRect, width: Int, height: Int) -> CGRect {
        // Normalized coordinates are top-left origin; CGContext is bottom-left.
        CGRect(x: box.minX * CGFloat(width),
               y: (1 - box.maxY) * CGFloat(height),
               width: box.width * CGFloat(width),
               height: box.height * CGFloat(height))
    }

    private static func draw(_ stroke: AIMaskStroke, in context: CGContext,
                             width: Int, height: Int) {
        guard !stroke.points.isEmpty else { return }
        let line = max(1, stroke.width * CGFloat(width))
        let level: CGFloat = stroke.erase ? 0 : 1
        context.setStrokeColor(gray: level, alpha: 1)
        context.setFillColor(gray: level, alpha: 1)
        context.setLineWidth(line)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let points = stroke.points.map {
            CGPoint(x: $0.x * CGFloat(width), y: (1 - $0.y) * CGFloat(height))
        }
        if points.count == 1 {
            let point = points[0]
            context.fillEllipse(in: CGRect(x: point.x - line / 2, y: point.y - line / 2,
                                           width: line, height: line))
            return
        }
        context.move(to: points[0])
        for point in points.dropFirst() {
            context.addLine(to: point)
        }
        context.strokePath()
    }
}

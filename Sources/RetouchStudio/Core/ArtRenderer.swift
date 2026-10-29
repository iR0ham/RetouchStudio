import AppKit
import CoreGraphics
import CoreImage
import Foundation

/// Draws the art tool's stickers. Everything is procedural Core Graphics: no
/// bundled assets, no downloads, and the same path is used for the canvas
/// preview and for the full-resolution export so what is placed is what is
/// written.
enum ArtRenderer {

    private static let cache = NSCache<NSString, NSImage>()

    /// Composites every sticker over the photo. Order is placement order, so a
    /// later sticker sits on top of an earlier one.
    static func apply(_ image: CIImage, stickers: [Sticker]) -> CIImage {
        guard !stickers.isEmpty,
              let overlay = render(stickers: stickers, extent: image.extent) else { return image }
        return overlay.composited(over: image).cropped(to: image.extent)
    }

    static func render(stickers: [Sticker], extent: CGRect) -> CIImage? {
        guard !stickers.isEmpty, extent.width >= 1, extent.height >= 1 else { return nil }
        let width = Int(extent.width.rounded())
        let height = Int(extent.height.rounded())
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.setShouldAntialias(true)
        let shortSide = min(extent.width, extent.height)
        for sticker in stickers {
            let center = CGPoint(x: sticker.center.x * extent.width,
                                 y: (1 - sticker.center.y) * extent.height)
            let radius = CGFloat(sticker.size) * shortSide / 2
            guard radius >= 0.5 else { continue }
            draw(sticker, in: context, center: center, radius: radius)
        }

        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage).cropped(to: CGRect(x: 0, y: 0,
                                                            width: width, height: height))
    }

    /// A square preview of one sticker, for the canvas overlay. Its colour,
    /// shape and rotation are baked in, so the ghost on the photo matches the
    /// pixels that will be written.
    static func glyph(_ sticker: Sticker, side: CGFloat = 256) -> NSImage? {
        let key = "\(sticker.kind.rawValue)-\(Int(sticker.color.hue.rounded()))-\(Int(sticker.color.saturation * 100))-\(Int(sticker.color.value * 100))-\(Int(side))" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let pixels = Int(max(32, side))
        guard let context = CGContext(data: nil, width: pixels, height: pixels,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setShouldAntialias(true)
        var flat = sticker
        flat.rotation = 0
        flat.opacity = 1
        draw(flat, in: context,
             center: CGPoint(x: CGFloat(pixels) / 2, y: CGFloat(pixels) / 2),
             radius: CGFloat(pixels) * 0.46)

        guard let cgImage = context.makeImage() else { return nil }
        let image = NSImage(cgImage: cgImage,
                            size: NSSize(width: pixels, height: pixels))
        cache.setObject(image, forKey: key)
        return image
    }

    private static func draw(_ sticker: Sticker,
                             in context: CGContext,
                             center: CGPoint,
                             radius: CGFloat) {
        let color = sticker.color.rgb
        context.saveGState()
        context.setAlpha(CGFloat(min(1, max(0, sticker.opacity))))
        context.setFillColor(CGColor(red: color.r, green: color.g, blue: color.b, alpha: 1))
        context.translateBy(x: center.x, y: center.y)
        // CG rotates counter-clockwise; the stored angle is clockwise on screen.
        context.rotate(by: -CGFloat(sticker.rotation) * .pi / 180)
        context.addPath(path(for: sticker.kind, radius: radius))
        context.fillPath()
        context.restoreGState()
    }

    /// Each shape in unit radius, y up, before the context applies rotation.
    private static func path(for kind: StickerKind, radius r: CGFloat) -> CGPath {
        let path = CGMutablePath()
        switch kind {
        case .star:
            polygon(path, points: 5, radius: r, inner: 0.42)
        case .sparkle:
            polygon(path, points: 4, radius: r, inner: 0.22)
        case .heart:
            path.move(to: CGPoint(x: 0, y: -0.95 * r))
            path.addCurve(to: CGPoint(x: -0.9 * r, y: 0.1 * r),
                          control1: CGPoint(x: -0.45 * r, y: -0.6 * r),
                          control2: CGPoint(x: -0.95 * r, y: -0.25 * r))
            path.addCurve(to: CGPoint(x: 0, y: 0.45 * r),
                          control1: CGPoint(x: -0.85 * r, y: 0.55 * r),
                          control2: CGPoint(x: -0.35 * r, y: 0.55 * r))
            path.addCurve(to: CGPoint(x: 0.9 * r, y: 0.1 * r),
                          control1: CGPoint(x: 0.35 * r, y: 0.55 * r),
                          control2: CGPoint(x: 0.85 * r, y: 0.55 * r))
            path.addCurve(to: CGPoint(x: 0, y: -0.95 * r),
                          control1: CGPoint(x: 0.95 * r, y: -0.25 * r),
                          control2: CGPoint(x: 0.45 * r, y: -0.6 * r))
            path.closeSubpath()
        case .flower:
            // Five petals around a small center: a compound path, filled with
            // the non-zero rule so the overlaps merge into one flower.
            for index in 0..<5 {
                let angle = CGFloat(index) * 2 * .pi / 5 - .pi / 2
                let petalCenter = CGPoint(x: cos(angle) * 0.52 * r,
                                          y: sin(angle) * 0.52 * r)
                let petalRadius = 0.42 * r
                path.addEllipse(in: CGRect(x: petalCenter.x - petalRadius,
                                           y: petalCenter.y - petalRadius,
                                           width: petalRadius * 2,
                                           height: petalRadius * 2))
            }
            path.addEllipse(in: CGRect(x: -0.24 * r, y: -0.24 * r,
                                       width: 0.48 * r, height: 0.48 * r))
        case .butterfly:
            // Upper and lower wings mirrored, then a slim body. Rotation is
            // baked into each ellipse with a small transform.
            let wings: [(center: CGPoint, size: CGSize, angle: CGFloat)] = [
                (CGPoint(x: -0.42 * r, y: 0.28 * r), CGSize(width: 0.78 * r, height: 0.62 * r), 28),
                (CGPoint(x: 0.42 * r, y: 0.28 * r), CGSize(width: 0.78 * r, height: 0.62 * r), -28),
                (CGPoint(x: -0.34 * r, y: -0.34 * r), CGSize(width: 0.56 * r, height: 0.48 * r), -22),
                (CGPoint(x: 0.34 * r, y: -0.34 * r), CGSize(width: 0.56 * r, height: 0.48 * r), 22),
            ]
            for wing in wings {
                let transform = CGAffineTransform(translationX: wing.center.x, y: wing.center.y)
                    .rotated(by: wing.angle * .pi / 180)
                let rect = CGRect(x: -wing.size.width / 2, y: -wing.size.height / 2,
                                  width: wing.size.width, height: wing.size.height)
                path.addEllipse(in: rect, transform: transform)
            }
            path.addEllipse(in: CGRect(x: -0.09 * r, y: -0.5 * r,
                                       width: 0.18 * r, height: 1.0 * r))
        case .lightning:
            let points: [CGPoint] = [
                CGPoint(x: 0.15 * r, y: 1.0 * r),
                CGPoint(x: -0.55 * r, y: 0.12 * r),
                CGPoint(x: -0.08 * r, y: 0.12 * r),
                CGPoint(x: -0.30 * r, y: -1.0 * r),
                CGPoint(x: 0.60 * r, y: -0.18 * r),
                CGPoint(x: 0.10 * r, y: -0.18 * r),
            ]
            path.addLines(between: points)
            path.closeSubpath()
        }
        return path
    }

    private static func polygon(_ path: CGMutablePath,
                                points: Int,
                                radius: CGFloat,
                                inner: CGFloat) {
        for index in 0..<(points * 2) {
            let r = index % 2 == 0 ? radius : radius * inner
            let angle = -CGFloat.pi / 2 + CGFloat(index) * .pi / CGFloat(points)
            let point = CGPoint(x: cos(angle) * r, y: sin(angle) * r)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
    }
}

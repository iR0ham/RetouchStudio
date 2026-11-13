import CoreGraphics
import CoreImage
import Foundation
import StudioCore

/// The frame value itself (`DocumentOrientation`) lives in StudioCore, because
/// a document carries it on every platform. Applying the turn to pixels and
/// mapping stored coordinates through it are the host's job, and they stay
/// here beside Core Graphics and Core Image.
///
/// Because a change of orientation re-renders the source, the editor rewrites
/// the stored edit coordinates from the old frame into the new one and lets
/// undo restore both the coordinates and the orientation together.

extension DocumentOrientation {
    /// Size of the frame after the quarter turns, in host pixels.
    func outputSize(base: CGSize) -> CGSize {
        quarterTurns % 2 == 0 ? base : CGSize(width: base.height, height: base.width)
    }

    /// Extra scale needed so a straightened photo still covers its frame
    /// instead of showing transparent corners.
    func coverScale(base: CGSize) -> CGFloat {
        guard abs(angle) > 0.0001 else { return 1 }
        let turned = outputSize(base: base)
        guard turned.width > 0, turned.height > 0 else { return 1 }
        let radians = angle * .pi / 180
        let c = abs(cos(radians))
        let s = abs(sin(radians))
        let coverWidth = (turned.width * c + turned.height * s) / turned.width
        let coverHeight = (turned.width * s + turned.height * c) / turned.height
        // A hair over the exact value keeps float rounding from leaving a
        // one-pixel transparent seam on an edge.
        return max(1, coverWidth, coverHeight) * 1.001
    }

    /// Old frame (top-left pixels) → new frame (top-left pixels).
    func transform(base: CGSize) -> CGAffineTransform {
        let turned = outputSize(base: base)
        var result: CGAffineTransform
        switch quarterTurns {
        case 1:
            result = CGAffineTransform(a: 0, b: 1, c: -1, d: 0,
                                       tx: base.height, ty: 0)
        case 2:
            result = CGAffineTransform(a: -1, b: 0, c: 0, d: -1,
                                       tx: base.width, ty: base.height)
        case 3:
            result = CGAffineTransform(a: 0, b: -1, c: 1, d: 0,
                                       tx: 0, ty: base.width)
        default:
            result = .identity
        }

        if abs(angle) > 0.0001 {
            let scale = coverScale(base: base)
            let center = CGPoint(x: turned.width / 2, y: turned.height / 2)
            let straighten = CGAffineTransform(translationX: -center.x, y: -center.y)
                .concatenating(CGAffineTransform(rotationAngle: CGFloat(angle * .pi / 180)))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
            result = result.concatenating(straighten)
        }

        if flipped {
            result = result.concatenating(
                CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: turned.width, ty: 0))
        }
        return result
    }

    /// The same mapping expressed in Core Image's bottom-left space.
    func ciTransform(base: CGSize) -> CGAffineTransform {
        let out = outputSize(base: base)
        let intoTopLeft = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: base.height)
        let outOfTopLeft = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: out.height)
        return intoTopLeft
            .concatenating(transform(base: base))
            .concatenating(outOfTopLeft)
    }

    /// Renders the turn into the pixels. The result is zero-based and exactly
    /// `outputSize`; a straighten is covered by the scale computed above.
    func applied(to image: CIImage) -> CIImage {
        guard !isIdentity else { return image }
        let base = image.extent.size
        let out = outputSize(base: base)
        guard out.width >= 1, out.height >= 1 else { return image }
        return image.transformed(by: ciTransform(base: base))
            .cropped(to: CGRect(origin: .zero, size: out))
    }

    // MARK: - Stored coordinates

    /// Normalized top-left point in the old frame → the same point in the new
    /// frame. Straighten is pixel-space, so the conversion goes through pixels.
    func mapPoint(_ point: CGPoint, base: CGSize) -> CGPoint {
        let out = outputSize(base: base)
        guard out.width > 0, out.height > 0 else { return point }
        let mapped = CGPoint(x: point.x * base.width, y: point.y * base.height)
            .applying(transform(base: base))
        return CGPoint(x: mapped.x / out.width, y: mapped.y / out.height)
    }

    /// A size stored as a fraction of the short side stays the same physical
    /// size on the photo. Quarter turns keep the short side; a straighten
    /// enlarges the source so its rotated corners still cover the frame.
    func mapShortSideFraction(_ fraction: CGFloat, base: CGSize) -> CGFloat {
        let out = outputSize(base: base)
        let oldShort = max(1, min(base.width, base.height))
        let newShort = max(1, min(out.width, out.height))
        return fraction * oldShort * coverScale(base: base) / newShort
    }

    /// Axis-aligned rectangle in, axis-aligned bounding rectangle out. Quarter
    /// turns and flips are exact; a straighten is bounded, which is the only
    /// honest axis-aligned answer and never cuts the chosen area.
    func mapRect(_ rect: CGRect, base: CGSize) -> CGRect {
        let out = outputSize(base: base)
        guard out.width > 0, out.height > 0 else { return rect }
        let t = transform(base: base)
        let corners = [
            CGPoint(x: rect.minX * base.width, y: rect.minY * base.height),
            CGPoint(x: rect.maxX * base.width, y: rect.minY * base.height),
            CGPoint(x: rect.maxX * base.width, y: rect.maxY * base.height),
            CGPoint(x: rect.minX * base.width, y: rect.maxY * base.height)
        ].map { $0.applying(t) }
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 0
        return CGRect(x: minX / out.width, y: minY / out.height,
                      width: (maxX - minX) / out.width,
                      height: (maxY - minY) / out.height)
    }

    /// The document-value overloads: a stored point, rectangle or short-side
    /// fraction is portable, so the caller does not convert by hand.
    func mapPoint(_ point: StudioPoint, base: CGSize) -> StudioPoint {
        StudioPoint(mapPoint(point.cgPoint, base: base))
    }

    func mapRect(_ rect: StudioRect, base: CGSize) -> StudioRect {
        StudioRect(mapRect(rect.cgRect, base: base))
    }

    func mapShortSideFraction(_ fraction: Double, base: CGSize) -> Double {
        Double(mapShortSideFraction(CGFloat(fraction), base: base))
    }
}

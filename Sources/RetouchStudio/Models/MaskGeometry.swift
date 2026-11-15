import CoreGraphics
import Foundation
import StudioCore

/// Maps what the owner drew on the cropped working frame into the source space
/// a `MaskRecord` is stored in, and back.
///
/// The canvas marks in the cropped frame, top-left normalized, with a stroke
/// width that is a fraction of that frame's width. The record uses the whole
/// upright photo, top-left normalized, with the width as a fraction of that
/// photo's width — the same space `crop`, `healSpots` and an AI edit's box use.
enum MaskGeometry {

    static func sourcePoint(_ point: CGPoint, crop: CGRect?) -> StudioPoint {
        guard let crop, crop.width > 0, crop.height > 0 else {
            return StudioPoint(x: Double(point.x), y: Double(point.y))
        }
        return StudioPoint(x: Double(crop.minX + point.x * crop.width),
                           y: Double(crop.minY + point.y * crop.height))
    }

    static func workingPoint(_ point: StudioPoint, crop: CGRect?) -> CGPoint {
        guard let crop, crop.width > 0, crop.height > 0 else {
            return CGPoint(x: point.x, y: point.y)
        }
        return CGPoint(x: CGFloat((point.x - Double(crop.minX)) / Double(crop.width)),
                       y: CGFloat((point.y - Double(crop.minY)) / Double(crop.height)))
    }

    static func sourceRect(_ rect: CGRect, crop: CGRect?) -> StudioRect {
        let origin = sourcePoint(CGPoint(x: rect.minX, y: rect.minY), crop: crop)
        let scaleX = crop.map { Double($0.width) } ?? 1
        let scaleY = crop.map { Double($0.height) } ?? 1
        return StudioRect(x: origin.x, y: origin.y,
                          width: Double(rect.width) * scaleX,
                          height: Double(rect.height) * scaleY)
    }

    static func workingRect(_ box: StudioRect, crop: CGRect?) -> CGRect {
        let origin = workingPoint(box.origin, crop: crop)
        let scaleX = crop.map { 1 / Double($0.width) } ?? 1
        let scaleY = crop.map { 1 / Double($0.height) } ?? 1
        return CGRect(x: origin.x, y: origin.y,
                      width: CGFloat(box.width * scaleX),
                      height: CGFloat(box.height * scaleY))
    }

    /// A brush width is a fraction of the frame's width, so it scales with the
    /// crop the same way its points do.
    static func sourceWidth(_ width: Double, crop: CGRect?) -> Double {
        guard let crop, crop.width > 0 else { return width }
        return width * Double(crop.width)
    }

    static func workingWidth(_ width: Double, crop: CGRect?) -> Double {
        guard let crop, crop.width > 0 else { return width }
        return width / Double(crop.width)
    }

    /// The area a record covers, from its box or from its strokes. Used to ask
    /// whether a mask belongs to the chosen face.
    static func bounds(of record: MaskRecord) -> StudioRect? {
        if let box = record.box { return box }
        let points = record.strokes.flatMap(\.points)
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let half = record.strokes.map(\.width).max().map { $0 / 2 } ?? 0
        return StudioRect(x: minX - half, y: minY - half,
                          width: maxX - minX + half * 2,
                          height: maxY - minY + half * 2)
    }
}

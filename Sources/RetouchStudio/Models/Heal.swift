import CoreGraphics
import Foundation

/// One manual healing stamp: a disc the user placed on the photo. Coordinates
/// are normalized with a top-left origin, the same convention the crop overlay
/// uses, and the radius is a fraction of the image's short side.
///
/// Stamps are stored against the *original* photo, so applying a crop keeps
/// them attached to the same fleck of skin instead of leaving them behind.
struct HealSpot: Codable, Equatable {
    var center: CGPoint
    var radius: CGFloat
}

enum HealGeometry {

    /// Radius a stamp needs to cover the same pixels after a crop. Fractions of
    /// the short side are relative to that frame, so the ratio of the two short
    /// sides converts one into the other; in normalized coordinates the source
    /// short side is 1, which leaves the crop's own shorter span.
    static func workingRadius(_ radius: CGFloat, crop: CGRect?) -> CGFloat {
        guard let crop else { return radius }
        return radius / max(0.0001, min(crop.width, crop.height))
    }

    /// Center of a stamp in the working frame after a crop.
    static func workingCenter(_ center: CGPoint, crop: CGRect?) -> CGPoint {
        guard let crop, crop.width > 0, crop.height > 0 else { return center }
        return CGPoint(x: (center.x - crop.minX) / crop.width,
                       y: (center.y - crop.minY) / crop.height)
    }

    /// The same map backwards: the canvas works in the cropped frame, but a
    /// stamp has to be stored against the original photo so a later crop, or a
    /// reset crop, keeps it on the blemish it was placed on.
    static func originalCenter(_ center: CGPoint, crop: CGRect?) -> CGPoint {
        guard let crop else { return center }
        return CGPoint(x: crop.minX + center.x * crop.width,
                       y: crop.minY + center.y * crop.height)
    }

    static func originalRadius(_ radius: CGFloat, crop: CGRect?) -> CGFloat {
        guard let crop else { return radius }
        return radius * min(crop.width, crop.height)
    }

    /// Stamps mapped into the working frame, dropping those fully outside it.
    static func workingSpots(_ spots: [HealSpot], crop: CGRect?) -> [HealSpot] {
        indexed(spots, crop: crop).map(\.spot)
    }

    /// Same mapping, keeping each stamp's index in the stored array so a stamp
    /// the user clicks on in the cropped view addresses the right entry.
    static func indexed(_ spots: [HealSpot], crop: CGRect?) -> [(index: Int, spot: HealSpot)] {
        spots.enumerated().compactMap { offset, spot in
            let center = workingCenter(spot.center, crop: crop)
            let radius = workingRadius(spot.radius, crop: crop)
            guard center.x + radius > 0, center.y + radius > 0,
                  center.x - radius < 1, center.y - radius < 1 else { return nil }
            return (offset, HealSpot(center: center, radius: radius))
        }
    }

    /// Distance between two normalized points measured in short-side units,
    /// which is the unit a stamp radius is expressed in. On a non-square frame
    /// the same normalized step spans more pixels across than down (or the
    /// other way around), so a plain `hypot` would test an ellipse footprint
    /// against a point.
    static func shortSideDistance(_ first: CGPoint, _ second: CGPoint,
                                  aspect: CGFloat) -> CGFloat {
        let ratio = max(0.0001, aspect)
        let dx = (first.x - second.x) * max(1, ratio)
        let dy = (first.y - second.y) * max(1, 1 / ratio)
        return hypot(dx, dy)
    }

    /// Mask shapes for a set of stamps. `MaskShape` uses a bottom-left origin,
    /// so the y of each disc flips. The radius is a fraction of the frame's
    /// short side, so on a non-square photo the normalized width and height
    /// differ: dividing by the pixel aspect keeps the repair footprint a circle
    /// in pixels instead of an ellipse the shape of the photo, and the export
    /// gets the same circle as the preview.
    static func shapes(for spots: [HealSpot], aspect: CGFloat) -> [MaskShape] {
        let ratio = max(0.0001, aspect)
        let radiusX = ratio >= 1 ? 1 / ratio : 1
        let radiusY = ratio >= 1 ? 1 : ratio
        return spots.map { spot in
            let rx = spot.radius * radiusX
            let ry = spot.radius * radiusY
            let rect = CGRect(x: spot.center.x - rx,
                              y: 1 - spot.center.y - ry,
                              width: rx * 2, height: ry * 2)
            return MaskShape(mode: .add, ellipse: rect)
        }
    }
}

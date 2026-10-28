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

    /// Mask shapes for a set of stamps. `MaskShape` uses a bottom-left origin,
    /// so the y of each disc flips.
    static func shapes(for spots: [HealSpot]) -> [MaskShape] {
        spots.map { spot in
            let diameter = spot.radius * 2
            let rect = CGRect(x: spot.center.x - spot.radius,
                              y: 1 - spot.center.y - spot.radius,
                              width: diameter, height: diameter)
            return MaskShape(mode: .add, ellipse: rect)
        }
    }

    /// One healing pass serves every stamp, sized by the largest of them: the
    /// median window only has to be wide enough to clear the biggest spot, and
    /// smaller stamps sit inside that patch anyway.
    static func largestRadius(_ spots: [HealSpot]) -> CGFloat {
        spots.map(\.radius).max() ?? 0
    }
}

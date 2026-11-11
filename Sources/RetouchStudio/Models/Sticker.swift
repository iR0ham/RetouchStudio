import CoreGraphics
import Foundation
import StudioCore

/// The shapes the art tool can stamp on a portrait. Each one is drawn
/// procedurally by `ArtRenderer`, so there is no image asset to ship and every
/// sticker stays sharp at export size.
enum StickerKind: String, CaseIterable, Identifiable, Codable {
    case star, heart, sparkle, flower, butterfly, lightning

    var id: String { rawValue }

    var title: String { L10n.current.stickerKindTitle(self) }
}

/// One placed sticker. Coordinates follow the healing brush exactly: the center
/// is normalized against the *original* photo with a top-left origin and the
/// size is a fraction of that photo's short side, so a crop keeps the sticker on
/// the spot it was placed on and an export scales it with the pixels.
struct Sticker: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var kind: StickerKind = .star
    var center: CGPoint
    var size: Double            // fraction of the short side
    var rotation: Double = 0    // degrees, clockwise
    var opacity: Double = 1     // 0...1
    var color: MakeupColor = Sticker.defaultColor

    static let defaultColor = MakeupColor(hue: 45, saturation: 0.80, value: 1.0)
    static let defaultSize: Double = 0.14
}

enum ArtGeometry {

    /// A sticker's size is a fraction of the photo's short *pixel* side, so it
    /// keeps the same physical size for any crop. A normalized crop spans a
    /// different number of pixels across and down unless the photo is square,
    /// so converting to the working frame needs the photo's pixel aspect ratio.
    private static func shortSides(crop: CGRect?, aspect: CGFloat) -> (working: Double, photo: Double) {
        let rect = crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let a = max(0.0001, Double(aspect))
        return (min(rect.width * a, rect.height), min(a, 1))
    }

    static func workingSize(_ size: Double, crop: CGRect?, aspect: CGFloat = 1) -> Double {
        let sides = shortSides(crop: crop, aspect: aspect)
        return size * sides.photo / max(0.0001, sides.working)
    }

    static func workingCenter(_ center: CGPoint, crop: CGRect?) -> CGPoint {
        guard let crop, crop.width > 0, crop.height > 0 else { return center }
        return CGPoint(x: (center.x - crop.minX) / crop.width,
                       y: (center.y - crop.minY) / crop.height)
    }

    static func originalCenter(_ center: CGPoint, crop: CGRect?) -> CGPoint {
        guard let crop else { return center }
        return CGPoint(x: crop.minX + center.x * crop.width,
                       y: crop.minY + center.y * crop.height)
    }

    static func originalSize(_ size: Double, crop: CGRect?, aspect: CGFloat = 1) -> Double {
        let sides = shortSides(crop: crop, aspect: aspect)
        return size * sides.working / max(0.0001, sides.photo)
    }

    /// Stickers mapped into the working frame, keeping each one's index so a
    /// click on the canvas addresses the stored entry.
    static func indexed(_ stickers: [Sticker],
                        crop: CGRect?,
                        aspect: CGFloat = 1) -> [(index: Int, sticker: Sticker)] {
        stickers.enumerated().map { offset, sticker in
            var mapped = sticker
            mapped.center = workingCenter(sticker.center, crop: crop)
            mapped.size = workingSize(sticker.size, crop: crop, aspect: aspect)
            return (offset, mapped)
        }
    }

    static func workingStickers(_ stickers: [Sticker],
                                crop: CGRect?,
                                aspect: CGFloat = 1) -> [Sticker] {
        indexed(stickers, crop: crop, aspect: aspect).map(\.sticker)
    }
}

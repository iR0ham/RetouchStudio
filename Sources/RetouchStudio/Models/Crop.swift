import CoreGraphics
import Foundation

/// Aspect presets offered in the crop inspector. The crop rect itself is stored
/// normalized with a top-left origin, which is how the overlay draws it.
enum CropAspect: String, CaseIterable, Identifiable {
    case free
    case original
    case square
    case portrait
    case wide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "Free"
        case .original: return "Original"
        case .square: return "1:1"
        case .portrait: return "4:5"
        case .wide: return "16:9"
        }
    }

    /// Target width ÷ height in pixels. `nil` leaves both edges free.
    func ratio(originalAspect: CGFloat) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return originalAspect
        case .square: return 1
        case .portrait: return 4.0 / 5.0
        case .wide: return 16.0 / 9.0
        }
    }
}

enum CropGeometry {
    /// No crop: the whole working image.
    static let full = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Smallest crop, as a fraction of the image. Keeps a handle from collapsing
    /// to a few pixels when the pointer runs past the frame.
    static let minimumSize: CGFloat = 0.03

    static func isFull(_ rect: CGRect) -> Bool {
        abs(rect.minX) < 0.0005 && abs(rect.minY) < 0.0005
            && abs(rect.width - 1) < 0.0005 && abs(rect.height - 1) < 0.0005
    }

    static func viewRect(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: rect.minX * size.width,
               y: rect.minY * size.height,
               width: rect.width * size.width,
               height: rect.height * size.height)
    }

    static func normalized(_ rect: CGRect, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return full }
        return CGRect(x: rect.minX / size.width,
                      y: rect.minY / size.height,
                      width: rect.width / size.width,
                      height: rect.height / size.height)
    }

    /// Rewrites a draft, which is relative to the image currently on screen, into
    /// a crop relative to the original photo. Crops therefore stack: cropping a
    /// cropped image narrows the absolute region instead of starting over.
    static func composed(_ draft: CGRect, over base: CGRect?) -> CGRect {
        let base = base ?? full
        return CGRect(x: base.minX + draft.minX * base.width,
                      y: base.minY + draft.minY * base.height,
                      width: draft.width * base.width,
                      height: draft.height * base.height)
    }

    static func clamped(_ rect: CGRect) -> CGRect {
        let width = min(max(minimumSize, rect.width), 1)
        let height = min(max(minimumSize, rect.height), 1)
        return CGRect(x: min(max(0, rect.minX), 1 - width),
                      y: min(max(0, rect.minY), 1 - height),
                      width: width,
                      height: height)
    }

    /// Largest rect with the requested pixel aspect ratio, centered in `bounds`.
    /// `imageAspect` is the width ÷ height of the working image in pixels.
    static func aspectFit(_ targetRatio: CGFloat, imageAspect: CGFloat, in bounds: CGRect) -> CGRect {
        guard targetRatio > 0, imageAspect > 0 else { return bounds }
        var width = bounds.width
        var height = width * imageAspect / targetRatio
        if height > bounds.height {
            height = bounds.height
            width = height * targetRatio / imageAspect
        }
        return CGRect(x: bounds.midX - width / 2,
                      y: bounds.midY - height / 2,
                      width: width,
                      height: height)
    }
}

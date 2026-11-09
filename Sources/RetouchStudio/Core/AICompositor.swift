import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// One resolved AI edit, ready to composite: the pixels, the alpha that says
/// where they may be used, and the rectangle they occupy in working
/// coordinates (normalized, top-left, after any crop).
struct AILayer {
    let box: CGRect
    let patch: CIImage
    let alpha: CIImage
    /// Turn the patch needs so it faces the same way as the photo. The files on
    /// disk are never rewritten; the document records the turn instead.
    let orientation: DocumentOrientation
}

/// Composites AI edits into the pipeline as strict layers.
///
/// The contract is the one the worker proved: every pixel outside an edit's
/// authorized rectangle is the original pixel. A layer is rebuilt at whatever
/// size the caller renders, so the preview and the export cannot disagree about
/// what an edit covers.
enum AICompositor {

    /// Decoded edit pixels, kept per file so a slider drag does not re-decode
    /// the same two PNGs dozens of times.
    private static let lock = NSLock()
    private static let cache: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.countLimit = 24
        return cache
    }()

    /// The edit's rectangle in normalized working coordinates. `box` is
    /// normalized against the original photo; the working image may be cropped.
    static func workingBox(_ box: CGRect, crop: CGRect?) -> CGRect {
        let frame = crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return CGRect(x: (box.minX - frame.minX) / frame.width,
                      y: (box.minY - frame.minY) / frame.height,
                      width: box.width / frame.width,
                      height: box.height / frame.height)
    }

    /// Loads every edit whose files are still on disk. Missing ones are skipped
    /// here and reported by `missing(_:)`, so a cleaned cache never becomes a
    /// silent change to the picture.
    static func layers(_ edits: [AIEdit], crop: CGRect?) -> [AILayer] {
        edits.compactMap { edit in
            guard AIEditStore.isAvailable(edit),
                  let patch = image(AIEditStore.patchURL(edit)),
                  let alpha = image(AIEditStore.alphaURL(edit)) else { return nil }
            let box = workingBox(edit.box, crop: crop)
            guard box.width > 0, box.height > 0 else { return nil }
            return AILayer(box: box, patch: patch, alpha: alpha,
                           orientation: edit.patchOrientation ?? .identity)
        }
    }

    /// Layers every edit over `image` at `extent`.
    static func apply(_ layers: [AILayer], to image: CIImage, extent: CGRect) -> CIImage {
        var result = image
        for layer in layers {
            let rect = pixelRect(layer.box, extent: extent)
            guard rect.width >= 1, rect.height >= 1 else { continue }
            let patch = scaled(oriented(layer.patch, by: layer.orientation), to: rect)
            let alpha = scaled(oriented(layer.alpha, by: layer.orientation), to: rect)
            let blended: CIImage
            if let filter = CIFilter(name: "CIBlendWithMask") {
                filter.setValue(patch, forKey: kCIInputImageKey)
                filter.setValue(result, forKey: kCIInputBackgroundImageKey)
                filter.setValue(alpha, forKey: kCIInputMaskImageKey)
                blended = filter.outputImage ?? result
            } else {
                blended = result
            }
            // Only the rectangle comes from the blend; the rest of the canvas is
            // the input image itself, so nothing outside can move by a byte.
            result = blended.cropped(to: rect).composited(over: result)
        }
        return result
    }

    static func missing(_ edits: [AIEdit]) -> [AIEdit] {
        edits.filter { !AIEditStore.isAvailable($0) }
    }

    /// Normalized top-left box → Core Image rectangle (bottom-left origin).
    static func pixelRect(_ box: CGRect, extent: CGRect) -> CGRect {
        CGRect(x: box.minX * extent.width,
               y: extent.height - (box.minY + box.height) * extent.height,
               width: box.width * extent.width,
               height: box.height * extent.height)
    }

    // MARK: - Images

    static func image(_ url: URL) -> CIImage? {
        let key = url.path as NSString
        lock.lock()
        let hit = cache.object(forKey: key)
        lock.unlock()
        if let hit { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let image = CIImage(cgImage: cgImage)
        lock.lock()
        cache.setObject(image, forKey: key)
        lock.unlock()
        return image
    }

    static func clearCache() {
        lock.lock()
        cache.removeAllObjects()
        lock.unlock()
    }

    /// Turns the patch into the document's frame. Core Image's y-axis points
    /// up, so a clockwise visual turn is a negative mathematical angle.
    static func oriented(_ image: CIImage, by orientation: DocumentOrientation) -> CIImage {
        guard !orientation.isIdentity else { return image }
        let radians = CGFloat(orientation.rotationDegrees * .pi / 180)
        var transform = CGAffineTransform(rotationAngle: -radians)
        if orientation.flipped {
            transform = transform.concatenating(CGAffineTransform(scaleX: -1, y: 1))
        }
        let turned = image.transformed(by: transform)
        let bounds = turned.extent
        return turned.transformed(by: CGAffineTransform(translationX: -bounds.minX,
                                                        y: -bounds.minY))
    }

    private static func scaled(_ image: CIImage, to rect: CGRect) -> CIImage {
        let size = image.extent.size
        guard size.width > 0, size.height > 0 else { return image }
        let base = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,
                                                           y: -image.extent.minY))
        let scale = CGAffineTransform(scaleX: rect.width / size.width,
                                      y: rect.height / size.height)
        let move = CGAffineTransform(translationX: rect.minX, y: rect.minY)
        return base.transformed(by: scale.concatenating(move))
    }
}

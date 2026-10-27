import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case jpeg, png, tiff

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .tiff: return "TIFF"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .tiff: return "tif"
        }
    }

    var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .tiff: return .tiff
        }
    }

    var supportsQuality: Bool { self == .jpeg }
}

/// Every mask the pipeline needs, for one image size. Each mask is
/// white-on-transparent and overlays the image extent exactly, so it can be fed
/// straight into the blend helpers.
struct MaskSet {
    var skin: CIImage?          // skin only: face minus eyes, brows, lips
    var face: CIImage?          // whole face silhouette
    var eyes: CIImage?          // both eyes including lashes
    var leftEye: CIImage?
    var rightEye: CIImage?
    var lips: CIImage?          // outer lip shape
    var teeth: CIImage?         // inner-mouth region
    var underEyes: CIImage?     // tear-trough bands
    var forehead: CIImage?
    var nose: CIImage?
    var skinTexture: CIImage?   // skin, softer edge, for texture work
}

struct LoadResult {
    var sourceFull: CIImage
    var sourcePreview: CIImage
    var faces: [FaceGeometry]
    var masksFull: MaskSet?
    var masksPreview: MaskSet?
    var originalPreview: CGImage
    var preview: CGImage
    var pixelSize: CGSize
    var fileName: String
}

/// Retouch engine on Core Image.
///
/// Pipeline order follows how retouchers actually work:
///   1. geometry (reshape) first, so later masks line up with final feature
///      positions;
///   2. texture: blemish → wrinkle → tone evening → smoothing;
///   3. local tone: under-eye, brightness;
///   4. eyes and teeth;
///   5. global color and light last.
final class ImageProcessor {

    static let shared = ImageProcessor()

    let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private init() {
        context = CIContext(options: [.cacheIntermediates: true, .useSoftwareRenderer: false])
    }

    // MARK: - Loading

    func load(from url: URL, previewMaxDimension: CGFloat) -> LoadResult? {
        guard let image = loadCGImage(url: url) else { return nil }

        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let full = CIImage(cgImage: image).cropped(to: extent)
        let faces = FaceAnalyzer.analyze(image)

        let scale = Self.previewScale(for: extent, maxDimension: previewMaxDimension)
        let previewExtent = CGRect(x: 0, y: 0,
                                   width: (extent.width * scale).rounded(),
                                   height: (extent.height * scale).rounded())
        let previewSource = scale >= 1
            ? full
            : full.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).cropped(to: previewExtent)

        let masksFull = buildMasks(extent: full.extent, faces: faces)
        let masksPreview = buildMasks(extent: previewSource.extent, faces: faces)

        guard let originalPreview = renderCGImage(previewSource, scale: 1) else { return nil }
        reshapeFaces = faces
        let processed = process(previewSource, adjustments: .zero, masks: masksPreview)
        guard let preview = renderCGImage(processed, scale: 1) else { return nil }

        return LoadResult(sourceFull: full,
                          sourcePreview: previewSource,
                          faces: faces,
                          masksFull: masksFull,
                          masksPreview: masksPreview,
                          originalPreview: originalPreview,
                          preview: preview,
                          pixelSize: extent.size,
                          fileName: url.lastPathComponent)
    }

    func loadCGImage(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
        else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let raw = (properties?[kCGImagePropertyOrientation] as? UInt32)
            ?? UInt32((properties?[kCGImagePropertyOrientation] as? Int) ?? 1)
        let orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
        guard orientation != .up else { return cgImage }

        let oriented = CIImage(cgImage: cgImage).oriented(forExifOrientation: Int32(orientation.rawValue))
        let zeroed = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.origin.x,
                                                               y: -oriented.extent.origin.y))
        return renderCGImage(zeroed, scale: 1)
    }

    // MARK: - Faces (needed by the reshape stage)

    /// Faces detected for the currently loaded image, set during `load`.
    /// The reshape stage reads this because it needs the feature positions that
    /// match the image being processed.
    var reshapeFaces: [FaceGeometry]?

    // MARK: - Masks

    /// Builds the full per-region mask set. Feathering is proportional to image
    /// size so the preview and the full-resolution export match visually.
    func buildMasks(extent: CGRect, faces: [FaceGeometry]) -> MaskSet? {
        guard !faces.isEmpty else { return nil }

        let shortSide = min(extent.width, extent.height)
        let feather = max(3, 0.006 * shortSide)
        let softFeather = max(6, 0.014 * shortSide)
        let tightFeather = max(2, 0.003 * shortSide)

        var skinShapes: [MaskShape] = []
        var faceShapes: [MaskShape] = []
        var eyeShapes: [MaskShape] = []
        var leftEyeShapes: [MaskShape] = []
        var rightEyeShapes: [MaskShape] = []
        var lipShapes: [MaskShape] = []
        var teethShapes: [MaskShape] = []
        var underEyeShapes: [MaskShape] = []
        var foreheadShapes: [MaskShape] = []
        var noseShapes: [MaskShape] = []

        for face in faces {
            // Face silhouette: contour plus a soft band over forehead/cheeks.
            if face.faceContour.count >= 3 {
                faceShapes.append(MaskShape(points: face.faceContour))
                skinShapes.append(MaskShape(points: face.faceContour))
            }
            faceShapes.append(MaskShape(rect: face.upperFaceRectForMask, cornerRadius: 0.34))
            skinShapes.append(MaskShape(ellipse: face.foreheadRect))
            skinShapes.append(MaskShape(ellipse: face.leftCheekRect))
            skinShapes.append(MaskShape(ellipse: face.rightCheekRect))
            noseShapes.append(MaskShape(rect: face.noseRect, cornerRadius: 0.35))

            if face.leftEye.count >= 3 {
                eyeShapes.append(MaskShape(points: face.leftEye))
                leftEyeShapes.append(MaskShape(points: face.leftEye))
            }
            if face.rightEye.count >= 3 {
                eyeShapes.append(MaskShape(points: face.rightEye))
                rightEyeShapes.append(MaskShape(points: face.rightEye))
            }

            // Eyes, brows and lips never get smoothed.
            for eye in face.eyePolygons { skinShapes.append(MaskShape(mode: .erase, points: eye)) }
            for brow in face.eyebrowPolygons { skinShapes.append(MaskShape(mode: .erase, points: brow)) }
            if face.lipPolygon.count >= 3 {
                skinShapes.append(MaskShape(mode: .erase, points: face.lipPolygon))
                lipShapes.append(MaskShape(points: face.lipPolygon))
            }

            if let teeth = face.teethRect {
                teethShapes.append(MaskShape(ellipse: teeth))
            }

            underEyeShapes.append(MaskShape(ellipse: face.leftUnderEyeRect))
            underEyeShapes.append(MaskShape(ellipse: face.rightUnderEyeRect))
            if face.leftEye.count >= 3 { underEyeShapes.append(MaskShape(mode: .erase, points: face.leftEye)) }
            if face.rightEye.count >= 3 { underEyeShapes.append(MaskShape(mode: .erase, points: face.rightEye)) }

            foreheadShapes.append(MaskShape(ellipse: face.foreheadRect))
        }

        return MaskSet(
            skin: MaskBuilder.makeMask(extent: extent, shapes: skinShapes, feather: feather),
            face: MaskBuilder.makeMask(extent: extent, shapes: faceShapes, feather: feather),
            eyes: MaskBuilder.makeMask(extent: extent, shapes: eyeShapes, feather: tightFeather),
            leftEye: MaskBuilder.makeMask(extent: extent, shapes: leftEyeShapes, feather: tightFeather),
            rightEye: MaskBuilder.makeMask(extent: extent, shapes: rightEyeShapes, feather: tightFeather),
            lips: MaskBuilder.makeMask(extent: extent, shapes: lipShapes, feather: tightFeather),
            teeth: MaskBuilder.makeMask(extent: extent, shapes: teethShapes, feather: tightFeather),
            underEyes: MaskBuilder.makeMask(extent: extent, shapes: underEyeShapes, feather: softFeather),
            forehead: MaskBuilder.makeMask(extent: extent, shapes: foreheadShapes, feather: softFeather),
            nose: MaskBuilder.makeMask(extent: extent, shapes: noseShapes, feather: softFeather),
            skinTexture: MaskBuilder.makeMask(extent: extent, shapes: skinShapes, feather: softFeather)
        )
    }

    // MARK: - Processing

    func process(_ source: CIImage, adjustments a: Adjustments, masks: MaskSet?) -> CIImage {
        let extent = source.extent
        // Every radius is expressed relative to image size so the preview and
        // the full-resolution export look the same.
        let scale = max(0.5, min(3.0, min(extent.width, extent.height) / 1400))

        var image = source

        // 1) Geometry first, so the masks below line up with the moved features.
        //    The caller supplies the faces for the image being processed (the
        //    preview and the full-resolution source have different extents).
        if a.hasReshape, let reshapeFaces = reshapeFaces, !reshapeFaces.isEmpty {
            let controls = reshapeFaces.flatMap { FeatureReshaper.controls(for: $0, adjustments: a) }
            image = FeatureReshaper.apply(image, controls: controls)
        }

        // 2) Skin texture and tone.
        if let skinMask = masks?.skin, let textureMask = masks?.skinTexture {
            // Blemish size scales with the face, not the image: a spot is a
            // roughly constant fraction of a face's width. Deriving the median
            // radius this way keeps the slider behaving the same on the preview
            // and on the full-resolution export.
            let faceWidthPx = (reshapeFaces?.first.map { $0.boundingBox.width * extent.width })
                ?? (extent.width * 0.30)
            // Factor chosen by measurement, not taste. The median can only heal
            // a blemish smaller than its own kernel (about 2.3x the radius), so
            // the factor decides the largest removable spot:
            //
            //   factor  kernel   typical blemishes cleared   clean texture
            //   0.022   13.6 px  2 of 3                     1.00x
            //   0.030   18.5 px  3 of 3                     1.00x   <- chosen
            //   0.038   23.5 px  3 of 3                     1.00x
            //   0.046   28.4 px  2 of 3 (kernel skips them)  1.00x
            //
            // 0.030 clears the real blemishes on the test face while leaving
            // clean skin and the background untouched, with the flatter optimum
            // on either side. The upper clamp keeps the median affordable on
            // large images.
            let spotRadius = max(1.5, min(24.0, faceWidthPx * 0.030))

            if a.blemish > 0 {
                image = SkinEngine.removeBlemishes(image, strength: a.blemish,
                                                   mask: textureMask, spotRadius: spotRadius)
            }
            if a.wrinkle > 0 {
                image = SkinEngine.reduceWrinkles(image, strength: a.wrinkle,
                                                  mask: textureMask, scale: scale)
            }
            if a.skinToneEvens > 0 {
                image = SkinEngine.evenSkinTone(image, strength: a.skinToneEvens,
                                                mask: textureMask, scale: scale)
            }
            if a.smooth > 0 {
                image = SkinEngine.smoothSkin(image, strength: a.smooth,
                                              texturePreserve: a.texturePreserve,
                                              mask: skinMask, scale: scale)
            }
            if a.skinBrighten != 0 {
                image = SkinEngine.brightenSkin(image, strength: a.skinBrighten, mask: skinMask)
            }
        }

        // 3) Under-eye correction.
        if a.darkCircles > 0, let underEyeMask = masks?.underEyes {
            image = SkinEngine.correctDarkCircles(image, strength: a.darkCircles,
                                                  mask: underEyeMask, scale: scale)
        }

        // 4) Teeth and eyes.
        if a.teethWhiten > 0, let teethMask = masks?.teeth {
            image = SkinEngine.whitenTeeth(image, strength: a.teethWhiten, mask: teethMask)
        }
        if (a.eyeBrighten > 0 || a.eyeSharpen > 0), let eyeMask = masks?.eyes {
            image = SkinEngine.enhanceEyes(image, brighten: a.eyeBrighten,
                                           sharpen: a.eyeSharpen,
                                           mask: eyeMask, scale: scale)
        }

        // 5) Global color and light.
        image = applyGlobal(image, a)

        return image.cropped(to: extent)
    }

    private func applyGlobal(_ source: CIImage, _ a: Adjustments) -> CIImage {
        var image = source
        let extent = source.extent
        let shortSide = min(extent.width, extent.height)
        let scale = max(0.5, min(3.0, shortSide / 1400))

        if a.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.30 * a.exposure / 100])
        }
        if a.contrast != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 + 0.45 * a.contrast / 100])
        }
        if a.saturation != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + 0.6 * a.saturation / 100])
        }
        if a.vibrance != 0 {
            image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.9 * a.vibrance / 100])
        }
        if a.warmth != 0 {
            let amount = a.warmth / 100
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - 1500 * amount, y: 6 * amount)
            ])
        }
        if a.clarity > 0 {
            image = image.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: max(1.5, shortSide * 0.004),
                kCIInputIntensityKey: 0.75 * a.clarity / 100
            ])
        } else if a.clarity < 0 {
            image = image.applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: max(0.5, shortSide * 0.0015 * (-a.clarity / 100) * scale)
            ])
        }
        if a.vignette > 0 {
            image = image.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: 1.4 * a.vignette / 100,
                kCIInputRadiusKey: shortSide * 0.78
            ])
        }
        return image.cropped(to: extent)
    }

    static func previewScale(for extent: CGRect, maxDimension: CGFloat) -> CGFloat {
        let longest = max(extent.width, extent.height)
        guard longest > 0 else { return 1 }
        return min(1, maxDimension / longest)
    }

    // MARK: - Render and export

    func renderCGImage(_ image: CIImage, scale: CGFloat) -> CGImage? {
        var working = image
        if scale != 1 {
            working = working.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let extent = working.extent
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        let rect = CGRect(x: extent.origin.x, y: extent.origin.y,
                          width: extent.width.rounded(), height: extent.height.rounded())
        return context.createCGImage(working, from: rect, format: .RGBA8, colorSpace: colorSpace)
    }

    func renderNSImage(_ image: CIImage, scale: CGFloat) -> NSImage? {
        guard let cgImage = renderCGImage(image, scale: scale) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    func write(_ image: CIImage, to url: URL, format: ExportFormat, quality: Double) -> Bool {
        guard let cgImage = renderCGImage(image, scale: 1) else { return false }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                              format.utType.identifier as CFString,
                                                              1,
                                                              nil) else { return false }
        var properties: [CFString: Any] = [:]
        if format.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}

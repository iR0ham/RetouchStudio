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
    var sclera: CIImage?        // white of the eye, measured from pixels
    var iris: CIImage?          // iris and pupil
    var lashes: CIImage?        // lash line around the opening
    var eyeDetail: CIImage?     // iris + lashes, the target for sharpening
    var lips: CIImage?          // outer lip shape
    var teeth: CIImage?         // enamel pixels inside the mouth
    var brows: CIImage?         // brow hair band, widened for cosmetics
    var cheeks: CIImage?        // cheekbones, where blush belongs
    var underEyes: CIImage?     // tear-trough bands
    var forehead: CIImage?
    var nose: CIImage?
    var skinTexture: CIImage?   // skin, softer edge, for texture work
}

/// Where the manual healing brush stamped, ready for a single repair pass.
struct SpotHealing {
    var mask: CIImage
    /// Repair radius in pixels of the image this mask was built for.
    var radius: CGFloat
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
    var url: URL
    /// Working color space of the source. Previews and exports are rendered in
    /// this space so a Display P3 photo keeps its gamut instead of being clipped
    /// through sRGB.
    var colorSpace: CGColorSpace
    /// Source metadata (EXIF, TIFF, IPTC, GPS), carried into exports so camera,
    /// lens, date and copyright survive a retouch.
    var metadata: [CFString: Any]
}

/// Retouch engine on Core Image.
///
/// Pipeline order follows how retouchers actually work:
///   1. skin texture and tone, under-eye, eyes and teeth — using masks built for
///      the original feature positions;
///   2. geometry (reshape), so the local edits are warped together with the
///      features they were applied to and no mask can drift out of alignment;
///   3. global color and light last.
final class ImageProcessor {

    static let shared = ImageProcessor()

    let context: CIContext
    let defaultColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private init() {
        context = CIContext(options: [.cacheIntermediates: true, .useSoftwareRenderer: false])
    }

    // MARK: - Loading

    /// `crop` is normalized with a top-left origin, matching the crop overlay.
    /// The crop is applied to the pixels before analysis, so faces, masks and
    /// the preview all describe the cropped image.
    func load(from url: URL, previewMaxDimension: CGFloat, crop: CGRect? = nil) -> LoadResult? {
        guard let (image, colorSpace, metadata) = loadCGImageWithColorSpace(url: url) else { return nil }

        let imageExtent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var full = CIImage(cgImage: image).cropped(to: imageExtent)

        if let crop, !CropGeometry.isFull(crop) {
            // Convert top-left view coordinates into Core Image's bottom-left
            // space, then shift the crop to the origin so every downstream
            // stage sees a zero-based extent.
            let pixelRect = CGRect(x: crop.minX * imageExtent.width,
                                   y: (1 - crop.maxY) * imageExtent.height,
                                   width: crop.width * imageExtent.width,
                                   height: crop.height * imageExtent.height)
                .integral
                .intersection(imageExtent)
            if !pixelRect.isEmpty {
                full = full.cropped(to: pixelRect)
                    .transformed(by: CGAffineTransform(translationX: -pixelRect.minX,
                                                       y: -pixelRect.minY))
                    .cropped(to: CGRect(origin: .zero, size: pixelRect.size))
            }
        }

        let extent = full.extent
        let scale = Self.previewScale(for: extent, maxDimension: previewMaxDimension)
        let previewExtent = CGRect(x: 0, y: 0,
                                   width: (extent.width * scale).rounded(),
                                   height: (extent.height * scale).rounded())
        let previewSource = scale >= 1
            ? full
            : full.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).cropped(to: previewExtent)

        // Teeth and eye splits are pixel measurements, not geometry, and the
        // mask builder needs the answers, so annotation happens before masks.
        // Vision reports landmarks normalized to the face box, so the preview
        // render gives the same geometry as the full-resolution photo while
        // being far cheaper to analyze.
        guard let originalPreview = renderCGImage(previewSource, scale: 1, colorSpace: colorSpace) else { return nil }
        var faces = FaceAnalyzer.analyze(originalPreview)
        if !faces.isEmpty, let buffer = AutoAnalyzer.analysisBuffer(previewSource) {
            faces = AutoAnalyzer.annotateTeeth(faces: faces, buffer: buffer)
            faces = AutoAnalyzer.annotateEyes(faces: faces, buffer: buffer)
        }

        let masksFull = buildMasks(extent: full.extent, faces: faces, image: full)
        let masksPreview = buildMasks(extent: previewSource.extent, faces: faces, image: previewSource)

        let processed = process(previewSource, adjustments: .zero, masks: masksPreview, faces: faces)
        guard let preview = renderCGImage(processed, scale: 1, colorSpace: colorSpace) else { return nil }

        return LoadResult(sourceFull: full,
                          sourcePreview: previewSource,
                          faces: faces,
                          masksFull: masksFull,
                          masksPreview: masksPreview,
                          originalPreview: originalPreview,
                          preview: preview,
                          pixelSize: extent.size,
                          fileName: url.lastPathComponent,
                          url: url,
                          colorSpace: colorSpace,
                          metadata: metadata)
    }

    private func loadCGImageWithColorSpace(url: URL) -> (CGImage, CGColorSpace, [CFString: Any])? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
        else { return nil }

        let colorSpace = cgImage.colorSpace ?? defaultColorSpace
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let raw = (properties[kCGImagePropertyOrientation] as? UInt32)
            ?? UInt32((properties[kCGImagePropertyOrientation] as? Int) ?? 1)
        let orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
        guard orientation != .up else { return (cgImage, colorSpace, properties) }

        let oriented = CIImage(cgImage: cgImage).oriented(forExifOrientation: Int32(orientation.rawValue))
        let zeroed = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.origin.x,
                                                               y: -oriented.extent.origin.y))
        guard let normalized = renderCGImage(zeroed, scale: 1, colorSpace: colorSpace) else { return nil }
        return (normalized, colorSpace, properties)
    }

    // MARK: - Masks

    /// Builds the full per-region mask set. Feathering is proportional to image
    /// size so the preview and the full-resolution export match visually.
    ///
    /// Passing `image` turns on pixel gates for regions whose true boundary is
    /// not geometric: enamel stops at the gum line, sclera stops at the iris.
    /// Without it the masks fall back to their geometric shapes, which is what
    /// synthetic fixtures and tests without pixels use.
    func buildMasks(extent: CGRect, faces: [FaceGeometry], image: CIImage? = nil) -> MaskSet? {
        guard !faces.isEmpty else { return nil }

        let shortSide = min(extent.width, extent.height)
        let feather = max(3, 0.006 * shortSide)
        let softFeather = max(6, 0.014 * shortSide)
        let tightFeather = max(2, 0.003 * shortSide)

        var skinShapes: [MaskShape] = []
        var faceShapes: [MaskShape] = []
        var shieldShapes: [MaskShape] = []
        var eyeShapes: [MaskShape] = []
        var leftEyeShapes: [MaskShape] = []
        var rightEyeShapes: [MaskShape] = []
        var lipShapes: [MaskShape] = []
        var browShapes: [MaskShape] = []
        var cheekShapes: [MaskShape] = []
        var teethShapes: [MaskShape] = []
        var underEyeShapes: [MaskShape] = []
        var foreheadShapes: [MaskShape] = []
        var noseShapes: [MaskShape] = []

        var scleraParts: [CIImage] = []
        var irisParts: [CIImage] = []
        var lashParts: [CIImage] = []

        for face in faces {
            // Face silhouette: contour plus a soft band over forehead/cheeks.
            if face.faceContour.count >= 3 {
                faceShapes.append(MaskShape(points: face.faceContour))
                // Pull the skin edge slightly inside the silhouette: the
                // contour runs along the hairline and jaw, where smoothing the
                // background would read as a halo.
                skinShapes.append(MaskShape(points: FaceGeometry.scaled(face.faceContour, by: 0.985)))
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

            // Eyes, brows and lips never get smoothed. The shield is subtracted
            // from the finished skin mask instead of punched into it as an erase
            // shape: a hole drawn before the feather is half refilled by the very
            // blur that softens the silhouette, which is what put smoothing onto
            // the lashes.
            for rect in face.eyeShieldRects {
                shieldShapes.append(MaskShape(rect: rect, cornerRadius: 0.5))
            }
            if face.lipPolygon.count >= 3 {
                shieldShapes.append(MaskShape(points: face.lipPolygon))
                lipShapes.append(MaskShape(points: face.lipPolygon))
            }
            for brow in face.eyebrowPolygons {
                // Vision traces the brow as a thin outline; cosmetics need the
                // whole hair band, which is a few pixels wider on each side.
                browShapes.append(MaskShape(points: FaceGeometry.scaled(brow, by: 1.06)))
            }
            cheekShapes.append(MaskShape(ellipse: face.leftBlushRect))
            cheekShapes.append(MaskShape(ellipse: face.rightBlushRect))

            // Whitening a closed mouth would lighten lips, not teeth, so the
            // mask only exists when teeth were measured as visible. The shape
            // comes from the outer lips because the inner-lip outline stops
            // short of the smile corners; a rounded rect keeps the diagonal
            // tooth band intact where an ellipse would clip its ends.
            if face.hasVisibleTeeth, let teeth = face.enamelRect {
                teethShapes.append(MaskShape(rect: teeth, cornerRadius: 0.30))
            }

            underEyeShapes.append(MaskShape(ellipse: face.leftUnderEyeRect))
            underEyeShapes.append(MaskShape(ellipse: face.rightUnderEyeRect))

            foreheadShapes.append(MaskShape(ellipse: face.foreheadRect))

            // Per-eye splits. The geometric shapes are only approximate; the
            // gates decide the real boundary from the pixels.
            for eye in face.eyePolygons {
                let box = FaceGeometry.boundingBox(of: eye)
                guard box.width > 0.004, box.height > 0.002 else { continue }

                let scleraGeometry = MaskBuilder.makeMask(
                    extent: extent,
                    shapes: [MaskShape(points: FaceGeometry.scaled(eye, by: 0.88))],
                    feather: tightFeather)
                if let part = gatedMask(geometry: scleraGeometry, image: image,
                                        lumaMin: face.eyeScleraLuminance,
                                        saturationMax: 0.45) {
                    scleraParts.append(part)
                }

                let irisRect = CGRect(x: box.midX - box.width * 0.32,
                                      y: box.midY - box.height * 0.44,
                                      width: box.width * 0.64,
                                      height: box.height * 0.88)
                let irisGeometry = MaskBuilder.makeMask(
                    extent: extent,
                    shapes: [MaskShape(ellipse: irisRect)],
                    feather: tightFeather)
                if let part = gatedMask(geometry: irisGeometry, image: image,
                                        lumaMin: 0,
                                        lumaMax: face.eyeScleraLuminance,
                                        saturationMax: 1) {
                    irisParts.append(part)
                }

                let lashGeometry = MaskBuilder.makeMask(
                    extent: extent,
                    shapes: [
                        MaskShape(points: FaceGeometry.scaled(eye, by: 1.06)),
                        MaskShape(mode: .erase, ellipse: irisRect.insetBy(dx: irisRect.width * 0.18,
                                                                          dy: irisRect.height * 0.10))
                    ],
                    feather: tightFeather)
                if let part = gatedMask(geometry: lashGeometry, image: image,
                                        lumaMin: 0,
                                        lumaMax: face.eyeScleraLuminance * 0.95,
                                        saturationMax: 1) {
                    lashParts.append(part)
                }
            }
        }

        let teethGeometry = MaskBuilder.makeMask(extent: extent, shapes: teethShapes, feather: tightFeather)
        // Enamel only: bright and low-saturation. This is the same test the
        // visibility annotation uses, so whitening cannot land on gums or the
        // dark gap between teeth.
        let teethMask = gatedMask(geometry: teethGeometry, image: image,
                                  lumaMin: 0.45, saturationMax: 0.30)

        let scleraMask = unionAll(scleraParts)
        let irisMask = unionAll(irisParts)
        let lashMask = unionAll(lashParts)
        var eyeDetail = irisMask
        if let lashMask {
            eyeDetail = eyeDetail.map { MaskBuilder.union($0, lashMask) } ?? lashMask
        }

        // Brows are cosmetics targets, not skin: Vision traces the brow as a
        // narrow outline, so the band is dilated outward before it is softened.
        // The feather is deliberately wider than the other tight masks — a brow
        // band is only a few pixels tall, and a hard edge reads as a drawn-on
        // stripe instead of thicker hair.
        let browGeometry = MaskBuilder.makeMask(extent: extent, shapes: browShapes, feather: tightFeather)
        let browFeather = max(3, 0.007 * shortSide)
        let brows = browGeometry.map { grown($0, by: max(1.2, 0.0025 * shortSide), feather: browFeather) }
        let cheeks = MaskBuilder.makeMask(extent: extent, shapes: cheekShapes, feather: softFeather)

        // Everything the skin work must not touch: the eye and lip bands, plus
        // the brow hair itself. Subtracted from the *finished* masks, so the
        // silhouette's own feather can no longer bleed smoothing into the hole.
        var protected = MaskBuilder.makeMask(extent: extent, shapes: shieldShapes,
                                             feather: max(2, 0.004 * shortSide))
        if let brows {
            protected = protected.map { MaskBuilder.union($0, brows) } ?? brows
        }
        func shielded(_ base: CIImage?) -> CIImage? {
            guard let base, let protected else { return base }
            return MaskBuilder.subtract(protected, from: base)
        }

        return MaskSet(
            skin: shielded(MaskBuilder.makeMask(extent: extent, shapes: skinShapes, feather: feather)),
            face: MaskBuilder.makeMask(extent: extent, shapes: faceShapes, feather: feather),
            eyes: MaskBuilder.makeMask(extent: extent, shapes: eyeShapes, feather: tightFeather),
            leftEye: MaskBuilder.makeMask(extent: extent, shapes: leftEyeShapes, feather: tightFeather),
            rightEye: MaskBuilder.makeMask(extent: extent, shapes: rightEyeShapes, feather: tightFeather),
            sclera: scleraMask,
            iris: irisMask,
            lashes: lashMask,
            eyeDetail: eyeDetail,
            lips: MaskBuilder.makeMask(extent: extent, shapes: lipShapes, feather: tightFeather),
            teeth: teethMask,
            brows: brows,
            cheeks: cheeks,
            underEyes: shielded(MaskBuilder.makeMask(extent: extent, shapes: underEyeShapes, feather: softFeather)),
            forehead: MaskBuilder.makeMask(extent: extent, shapes: foreheadShapes, feather: softFeather),
            nose: MaskBuilder.makeMask(extent: extent, shapes: noseShapes, feather: softFeather),
            skinTexture: shielded(MaskBuilder.makeMask(extent: extent, shapes: skinShapes, feather: softFeather))
        )
    }

    /// Intersects a geometric mask with a pixel gate. Returns nil when the gate
    /// would leave almost nothing, so callers can fall back to the geometry
    /// instead of silently doing nothing.
    private func gatedMask(geometry: CIImage?,
                           image: CIImage?,
                           lumaMin: Double,
                           lumaMax: Double = 1,
                           saturationMax: Double,
                           minimumCoverage: Double = 0.02) -> CIImage? {
        guard let geometry else { return nil }
        guard let image, MaskBuilder.isColorGateAvailable,
              let gate = MaskBuilder.colorGate(image, lumaMin: lumaMin, lumaMax: lumaMax,
                                               saturationMax: saturationMax) else {
            return geometry
        }
        let combined = MaskBuilder.intersect(geometry, gate).cropped(to: geometry.extent)
        if let partial = meanMaskValue(combined), let whole = meanMaskValue(geometry),
           whole > 0.0001, partial / whole < minimumCoverage {
            return nil
        }
        return combined
    }

    /// Widen an opaque-grayscale mask and soften its new edge. Used for the
    /// brows, where the traced outline sits inside the hair band.
    private func grown(_ mask: CIImage, by radius: CGFloat, feather: CGFloat) -> CIImage {
        var grown = mask
        if CIFilter(name: "CIMorphologyMaximum") != nil {
            grown = grown.clampedToExtent()
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: mask.extent)
        }
        return grown.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0.8, feather)])
            .cropped(to: mask.extent)
    }

    private func unionAll(_ parts: [CIImage]) -> CIImage? {
        parts.dropFirst().reduce(parts.first) { accumulated, next in
            accumulated.map { MaskBuilder.union($0, next) } ?? next
        }
    }

    /// Mean gray level of a mask, used to judge gate coverage without reading
    /// the whole image back.
    private func meanMaskValue(_ image: CIImage) -> Double? {
        let average = image.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: image.extent)
        ])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(average, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        return Double(pixel[0]) / 255.0
    }

    // MARK: - Processing

    /// Builds the one-pass mask for the manual healing brush. Stamps arrive in
    /// the coordinates of the image being processed, so a crop or a different
    /// working resolution needs a fresh mask.
    func spotsMask(extent: CGRect, spots: [HealSpot]) -> SpotHealing? {
        guard !spots.isEmpty else { return nil }
        let shortSide = min(extent.width, extent.height)
        guard let mask = MaskBuilder.makeMask(extent: extent,
                                              shapes: HealGeometry.shapes(for: spots),
                                              feather: max(2, 0.004 * shortSide)) else { return nil }
        return SpotHealing(mask: mask, radius: max(2, HealGeometry.largestRadius(spots) * shortSide))
    }

    func process(_ source: CIImage,
                 adjustments a: Adjustments,
                 masks: MaskSet?,
                 faces: [FaceGeometry] = [],
                 spots: SpotHealing? = nil) -> CIImage {
        let extent = source.extent
        // Every radius is expressed relative to image size so the preview and
        // the full-resolution export look the same.
        let scale = max(0.5, min(3.0, min(extent.width, extent.height) / 1400))

        var image = source

        // 0) Manual healing runs before anything else: the repaired patch is
        //    what the automatic skin passes should then work over, and it is
        //    not limited to the face masks because the user can stamp anywhere.
        if let spots {
            image = SkinEngine.healSpots(image, mask: spots.mask, radius: spots.radius)
        }

        // 1) Local retouch runs first, while the masks still line up with the
        //    feature positions they were built from. Warping first would move
        //    eyes and lips out from under their own masks.
        if let skinMask = masks?.skin, let textureMask = masks?.skinTexture {
            // Blemish size scales with the face, not the image: a spot is a
            // roughly constant fraction of a face's width. Deriving the median
            // radius this way keeps the slider behaving the same on the preview
            // and on the full-resolution export.
            let faceWidthPx = faces.first.map { $0.boundingBox.width * extent.width }
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

        // 2) Under-eye correction.
        if a.darkCircles > 0, let underEyeMask = masks?.underEyes {
            image = SkinEngine.correctDarkCircles(image, strength: a.darkCircles,
                                                  mask: underEyeMask, scale: scale)
        }

        // 3) Teeth and eyes.
        if a.teethWhiten > 0, let teethMask = masks?.teeth {
            image = SkinEngine.whitenTeeth(image, strength: a.teethWhiten, mask: teethMask)
        }
        if a.eyeBrighten > 0, let scleraMask = masks?.sclera ?? masks?.eyes {
            image = SkinEngine.brightenSclera(image, strength: a.eyeBrighten, mask: scleraMask)
        }
        if a.eyeSharpen > 0, let detailMask = masks?.eyeDetail ?? masks?.eyes {
            image = SkinEngine.sharpenEyeDetail(image, strength: a.eyeSharpen,
                                                mask: detailMask, scale: scale)
        }

        // 3b) Makeup, after the skin work: smoothing first would dilute the
        //     colour and blur its edge, and a flush laid on finished skin keeps
        //     both. Still ahead of the warp, so it travels with the features.
        if a.lipTint > 0, let lipMask = masks?.lips {
            image = MakeupEngine.tintLips(image, strength: a.lipTint,
                                          mask: lipMask, shade: a.lipShade)
        }
        if a.blush > 0, let cheekMask = masks?.cheeks {
            image = MakeupEngine.applyBlush(image, strength: a.blush,
                                            mask: cheekMask, shade: a.blushShade)
        }
        if a.browDefine > 0, let browMask = masks?.brows {
            image = MakeupEngine.defineBrows(image, strength: a.browDefine,
                                             mask: browMask, scale: scale)
        }

        // 4) Geometry after the local edits: the warp then carries the
        //    retouched pixels with the features, and every mask stays aligned.
        if a.hasReshape, !faces.isEmpty {
            let controls = faces.flatMap { FeatureReshaper.controls(for: $0, adjustments: a) }
            image = FeatureReshaper.apply(image, controls: controls)
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

        // Levels first: exposure and contrast are tuned around the endpoints, so
        // stretching them afterwards would move the anchors the analysis used.
        image = LookEngine.applyLevels(image, black: a.blackLevel, white: a.whiteLevel)

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
        // 6) The look sits after the tonal sliders so the grade reshapes the
        //    image the user already balanced, and grain goes last because it
        //    belongs on top of the finished picture, not under a blur.
        image = LookEngine.applyLook(image, look: a.look, strength: a.lookStrength / 100)
        if a.grain > 0 {
            image = LookEngine.addGrain(image, amount: a.grain / 100, extent: extent)
        }
        return image.cropped(to: extent)
    }

    static func previewScale(for extent: CGRect, maxDimension: CGFloat) -> CGFloat {
        let longest = max(extent.width, extent.height)
        guard longest > 0 else { return 1 }
        return min(1, maxDimension / longest)
    }

    // MARK: - Render and export

    func renderCGImage(_ image: CIImage,
                       scale: CGFloat,
                       colorSpace: CGColorSpace? = nil,
                       format: CIFormat = .RGBA8) -> CGImage? {
        var working = image
        if scale != 1 {
            working = working.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let extent = working.extent
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        let rect = CGRect(x: extent.origin.x, y: extent.origin.y,
                          width: extent.width.rounded(), height: extent.height.rounded())
        return context.createCGImage(working, from: rect, format: format,
                                     colorSpace: colorSpace ?? defaultColorSpace)
    }

    func renderNSImage(_ image: CIImage, scale: CGFloat, colorSpace: CGColorSpace? = nil) -> NSImage? {
        guard let cgImage = renderCGImage(image, scale: scale, colorSpace: colorSpace) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Writes the image; PNG and TIFF keep 16 bits per channel, JPEG stays at 8
    /// because the format defines no deeper container. Source metadata is
    /// carried over, with orientation normalized to 1 since the pixels have
    /// already been rotated upright.
    func write(_ image: CIImage,
               to url: URL,
               format: ExportFormat,
               quality: Double,
               colorSpace: CGColorSpace? = nil,
               metadata: [CFString: Any] = [:]) -> Bool {
        let ciFormat: CIFormat = format == .jpeg ? .RGBA8 : .RGBA16
        guard let cgImage = renderCGImage(image, scale: 1, colorSpace: colorSpace, format: ciFormat) else {
            return false
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                              format.utType.identifier as CFString,
                                                              1,
                                                              nil) else { return false }
        var properties = metadata
        // These describe the source pixels, not the exported ones.
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight,
                    kCGImagePropertyDepth, kCGImagePropertyColorModel,
                    kCGImagePropertyProfileName, kCGImagePropertyHasAlpha] {
            properties.removeValue(forKey: key)
        }
        properties[kCGImagePropertyOrientation] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if format.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}

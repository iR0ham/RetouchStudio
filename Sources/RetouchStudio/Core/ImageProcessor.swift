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
    var lids: CIImage?          // lid skin above each eye, for eyeshadow
    var liners: CIImage?        // narrow band along the upper lash line
    var hair: CIImage?          // crown and side hair, for dye and shine
    var contours: CIImage?      // cheekbone-to-jaw hollows, for contour makeup
    /// Subject silhouette from Vision. Built lazily the first time a Body or
    /// Background control moves, because segmentation is the one expensive
    /// analysis a fresh photo does not need.
    var person: CIImage? = nil
    /// Joints from Vision's body-pose pass, carried with the same lazy analysis
    /// as the silhouette. Nil on a portrait where only the face is in frame.
    var pose: BodyPose? = nil

    /// A set that carries only the person mask. Body and Background work on
    /// photos with no face at all, where `buildMasks` returns nil but the
    /// pipeline still has to receive the silhouette.
    static func personOnly(_ person: CIImage, pose: BodyPose? = nil) -> MaskSet {
        MaskSet(skin: nil, face: nil, eyes: nil, leftEye: nil, rightEye: nil,
                sclera: nil, iris: nil, lashes: nil, eyeDetail: nil, lips: nil,
                teeth: nil, brows: nil, cheeks: nil, underEyes: nil, forehead: nil,
                nose: nil, skinTexture: nil, lids: nil, liners: nil, hair: nil,
                contours: nil, person: person, pose: pose)
    }
}

/// Where the healing brush stamped, grouped into repairs. Each pass carries the
/// stamps of one size class, because the repair kernel is sized by the stamp:
/// one pass sized for the largest stamp would over-smooth every small one and
/// take its donor texture from too far away.
struct SpotHealing {
    struct Pass {
        var mask: CIImage
        /// Repair radius in pixels of the image this mask was built for.
        var radius: CGFloat
    }

    var passes: [Pass]
}

struct LoadResult {
    var sourceFull: CIImage
    var sourcePreview: CIImage
    var faces: [FaceGeometry]
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

        // One retained set, at the preview target. The export builds its own
        // set at export resolution (see `ExportService.render`), so no
        // full-resolution rasters sit idle between edits.
        let masksPreview = buildMasks(extent: previewSource.extent, faces: faces,
                                      image: previewSource,
                                      maskDimension: MaskBuilder.previewMaskDimension)

        let processed = process(previewSource, adjustments: .zero, masks: masksPreview, faces: faces)
        guard let preview = renderCGImage(processed, scale: 1, colorSpace: colorSpace) else { return nil }

        return LoadResult(sourceFull: full,
                          sourcePreview: previewSource,
                          faces: faces,
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

    /// Width of the face that sets feature sizes, in pixels. The selected face
    /// wins; with no selection the median over every accepted face wins, so a
    /// single spurious small face cannot shrink the blemish radius. `nil` only
    /// when there are no faces at all.
    static func faceWidthPixels(faces: [FaceGeometry], focus: FaceGeometry?,
                                extent: CGRect) -> CGFloat? {
        if let focus, focus.boundingBox.width > 0 {
            return focus.boundingBox.width * extent.width
        }
        let widths = faces.map(\.boundingBox.width).filter { $0 > 0 }.sorted()
        guard !widths.isEmpty else { return nil }
        return widths[widths.count / 2] * extent.width
    }

    /// Blemish radius as a fraction of the render's short side. The preview
    /// and the export describe the same face with different pixel widths, so
    /// only a fraction survives the resolution change unchanged. Measured on
    /// the test face: 0.030 clears the real spots while leaving clean skin
    /// alone; larger factors make the median skip spots instead of healing
    /// them.
    static func blemishRadiusFraction(faces: [FaceGeometry], focus: FaceGeometry?,
                                      extent: CGRect) -> CGFloat {
        let faceWidthPx = faceWidthPixels(faces: faces, focus: focus, extent: extent)
            ?? (extent.width * 0.30)
        let shortSide = max(min(extent.width, extent.height), 1)
        return faceWidthPx / shortSide * 0.030
    }

    /// The skin masks of a face without landmarks still have to be usable:
    /// feature rectangles derived from missing outlines come out null or
    /// infinite, so only boxes that are finite and non-empty get a shape.
    private func validRect(_ rect: CGRect) -> CGRect? {
        guard !rect.isNull, !rect.isInfinite, !rect.isEmpty,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return nil }
        return rect
    }

    /// Builds the full per-region mask set. Feathering is proportional to image
    /// size so the preview and the full-resolution export match visually.
    ///
    /// Passing `image` turns on pixel gates for regions whose true boundary is
    /// not geometric: enamel stops at the gum line, sclera stops at the iris.
    /// Without it the masks fall back to their geometric shapes, which is what
    /// synthetic fixtures and tests without pixels use.
    func buildMasks(extent: CGRect, faces: [FaceGeometry], image: CIImage? = nil,
                    maskDimension: CGFloat = MaskBuilder.maxMaskDimension) -> MaskSet? {
        guard !faces.isEmpty else { return nil }

        func make(_ shapes: [MaskShape], _ feather: CGFloat) -> CIImage? {
            MaskBuilder.makeMask(extent: extent, shapes: shapes, feather: feather,
                                 maxDimension: maskDimension)
        }

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
        var lidShapes: [MaskShape] = []
        var lashLineShapes: [MaskShape] = []
        var hairShapes: [MaskShape] = []
        var hairSideShapes: [MaskShape] = []
        var contourShapes: [MaskShape] = []

        var scleraParts: [CIImage] = []
        var irisParts: [CIImage] = []
        var lashParts: [CIImage] = []

        for face in faces {
            guard validRect(face.boundingBox) != nil else { continue }
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
            if face.hasLandmarks {
                if let cheek = validRect(face.leftCheekRect) {
                    skinShapes.append(MaskShape(ellipse: cheek))
                }
                if let cheek = validRect(face.rightCheekRect) {
                    skinShapes.append(MaskShape(ellipse: cheek))
                }
                if let nose = validRect(face.noseRect) {
                    noseShapes.append(MaskShape(rect: nose, cornerRadius: 0.35))
                }
            }

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
            lidShapes.append(contentsOf: face.eyelidRects.map { MaskShape(ellipse: $0) })
            // The liner follows the traced upper lid when the outline is rich
            // enough; the level rectangle is only a fallback.
            if face.lashLinePolygons.count == face.eyePolygons.count {
                lashLineShapes.append(contentsOf: face.lashLinePolygons.map { MaskShape(points: $0) })
            } else {
                lashLineShapes.append(contentsOf: face.lashLineRects.map { MaskShape(rect: $0, cornerRadius: 0.5) })
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
            if face.hasLandmarks {
                if let blush = validRect(face.leftBlushRect) {
                    cheekShapes.append(MaskShape(ellipse: blush))
                }
                if let blush = validRect(face.rightBlushRect) {
                    cheekShapes.append(MaskShape(ellipse: blush))
                }
            }

            hairShapes.append(MaskShape(rect: face.hairRect, cornerRadius: 0.42))
            hairSideShapes.append(contentsOf: face.hairSideRects.map { MaskShape(ellipse: $0) })
            contourShapes.append(contentsOf: face.contourPolygons.map { MaskShape(points: $0) })

            // Whitening a closed mouth would lighten lips, not teeth, so the
            // mask only exists when teeth were measured as visible. The shape
            // comes from the outer lips because the inner-lip outline stops
            // short of the smile corners; a rounded rect keeps the diagonal
            // tooth band intact where an ellipse would clip its ends.
            if face.hasVisibleTeeth, let teeth = face.enamelRect {
                teethShapes.append(MaskShape(rect: teeth, cornerRadius: 0.30))
            }

            if face.hasLandmarks {
                if let underEye = validRect(face.leftUnderEyeRect) {
                    underEyeShapes.append(MaskShape(ellipse: underEye))
                }
                if let underEye = validRect(face.rightUnderEyeRect) {
                    underEyeShapes.append(MaskShape(ellipse: underEye))
                }
            }

            foreheadShapes.append(MaskShape(ellipse: face.foreheadRect))

            // Per-eye splits. The geometric shapes are only approximate; the
            // gates decide the real boundary from the pixels.
            let eyes: [(outline: [CGPoint], pupil: [CGPoint])] = [
                (face.leftEye, face.leftPupil),
                (face.rightEye, face.rightPupil)
            ]
            for eye in eyes {
                let box = FaceGeometry.boundingBox(of: eye.outline)
                guard box.width > 0.004, box.height > 0.002 else { continue }

                let scleraGeometry = make(
                    [MaskShape(points: FaceGeometry.scaled(eye.outline, by: 0.88))],
                    tightFeather)
                if let part = gatedMask(geometry: scleraGeometry, image: image,
                                        lumaMin: face.eyeScleraLuminance,
                                        saturationMax: 0.45) {
                    scleraParts.append(part)
                }

                let irisRect = FaceGeometry.irisRect(eye: eye.outline, pupil: eye.pupil)
                if irisRect.isNull { continue }
                let irisGeometry = make([MaskShape(ellipse: irisRect)], tightFeather)
                if let part = gatedMask(geometry: irisGeometry, image: image,
                                        lumaMin: 0,
                                        lumaMax: face.eyeScleraLuminance,
                                        saturationMax: 1) {
                    irisParts.append(part)
                }

                let lashGeometry = make(
                    [
                        MaskShape(points: FaceGeometry.scaled(eye.outline, by: 1.06)),
                        MaskShape(mode: .erase, ellipse: irisRect.insetBy(dx: irisRect.width * 0.18,
                                                                          dy: irisRect.height * 0.10))
                    ],
                    tightFeather)
                if let part = gatedMask(geometry: lashGeometry, image: image,
                                        lumaMin: 0,
                                        lumaMax: face.eyeScleraLuminance * 0.95,
                                        saturationMax: 1) {
                    lashParts.append(part)
                }
            }
        }

        let teethGeometry = make(teethShapes, tightFeather)
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
        let browGeometry = make(browShapes, tightFeather)
        let browFeather = max(3, 0.007 * shortSide)
        let brows = browGeometry.map { grown($0, by: max(1.2, 0.0025 * shortSide), feather: browFeather) }
        let cheeks = make(cheekShapes, softFeather)

        // Lids are soft like a powder, and the brow hair is taken out of them so
        // eyeshadow never turns into a second eyebrow. The liner band is the
        // opposite: a narrow, hard-edged line that follows the lashes.
        var lids = make(lidShapes, max(2.5, 0.006 * shortSide))
        if let browMask = brows, let lidMask = lids {
            lids = MaskBuilder.subtract(browMask, from: lidMask)
        }
        let linerFeather = max(1.5, 0.002 * shortSide)
        let liners = make(lashLineShapes, linerFeather)

        // Hair is a colour target, so it gets a soft edge. The pixel gate keeps
        // a bright wall out of the band; the person mask (when Body, Background
        // or Hair has loaded one) finishes the job in the pipeline.
        let faceSilhouette = make(faceShapes, feather)
        let hairTop = make(hairShapes, softFeather)
        // The side panels sit where hair falls past the ears — and where the
        // cheek is. Skin is inside the same luma gate as brown hair, so the
        // face silhouette is cut out of the side panels only; the head band
        // above the hairline must keep its pixels.
        var hairSides = make(hairSideShapes, softFeather)
        if let faceSilhouette, let sides = hairSides {
            hairSides = MaskBuilder.subtract(faceSilhouette, from: sides)
        }
        var hairGeometry = hairTop
        if let sides = hairSides {
            hairGeometry = hairTop.map { MaskBuilder.union($0, sides) } ?? sides
        }
        let hair = gatedMask(geometry: hairGeometry, image: image,
                             lumaMin: 0, lumaMax: 0.82, saturationMax: 1)

        let contours = make(contourShapes, softFeather)

        // Everything the skin work must not touch: the eye and lip bands, plus
        // the brow hair itself. Subtracted from the *finished* masks, so the
        // silhouette's own feather can no longer bleed smoothing into the hole.
        var protected = make(shieldShapes, max(2, 0.004 * shortSide))
        if let brows {
            protected = protected.map { MaskBuilder.union($0, brows) } ?? brows
        }
        func shielded(_ base: CIImage?) -> CIImage? {
            guard let base, let protected else { return base }
            return MaskBuilder.subtract(protected, from: base)
        }

        return MaskSet(
            skin: shielded(make(skinShapes, feather)),
            face: faceSilhouette,
            eyes: make(eyeShapes, tightFeather),
            leftEye: make(leftEyeShapes, tightFeather),
            rightEye: make(rightEyeShapes, tightFeather),
            sclera: scleraMask,
            iris: irisMask,
            lashes: lashMask,
            eyeDetail: eyeDetail,
            lips: make(lipShapes, tightFeather),
            teeth: teethMask,
            brows: brows,
            cheeks: cheeks,
            underEyes: shielded(make(underEyeShapes, softFeather)),
            forehead: make(foreheadShapes, softFeather),
            nose: make(noseShapes, softFeather),
            skinTexture: shielded(make(skinShapes, softFeather)),
            lids: lids,
            liners: liners,
            hair: hair,
            contours: contours
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

    // MARK: - Detail analysis

    /// A face-centred crop at (near) its own resolution, for the blemish finder.
    /// The 512 px analysis buffer is the right size for global statistics but
    /// too coarse to tell an acne spot from a JPEG block: in a full-body photo
    /// a face is about 90 px wide there.
    ///
    /// `maxDimension` keeps the crop affordable. Past a few hundred pixels of
    /// face, a larger render adds no information about a blemish, only cost.
    func faceCrop(for face: FaceGeometry,
                  in source: CIImage,
                  skinMask: CIImage?,
                  maxDimension: CGFloat = 420) -> SmartAnalyzer.FaceCrop? {
        let extent = source.extent
        let box = face.boundingBox
        let margin: CGFloat = 0.14
        let raw = CGRect(x: (box.minX - box.width * margin) * extent.width,
                         y: (box.minY - box.height * margin) * extent.height,
                         width: box.width * (1 + 2 * margin) * extent.width,
                         height: box.height * (1 + 2 * margin) * extent.height)
            .integral
            .intersection(extent)
        guard raw.width >= 24, raw.height >= 24 else { return nil }

        let scale = min(1, maxDimension / max(raw.width, raw.height))
        let width = max(1, Int((raw.width * scale).rounded()))
        let height = max(1, Int((raw.height * scale).rounded()))
        let target = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))

        func prepared(_ image: CIImage) -> CIImage {
            image.cropped(to: raw)
                .transformed(by: CGAffineTransform(translationX: -raw.minX, y: -raw.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .cropped(to: target)
        }

        guard let rendered = renderCGImage(prepared(source), scale: 1),
              let buffer = PixelBuffer(cgImage: rendered) else { return nil }

        let skin = skinMask.flatMap { mask -> PixelBuffer? in
            guard let cg = renderCGImage(prepared(mask), scale: 1) else { return nil }
            return PixelBuffer(cgImage: cg)
        }

        // FaceGeometry is bottom-left normalized; the crop buffer is top-left
        // pixels. One conversion serves the face box and every exclusion.
        func toBuffer(_ rect: CGRect) -> CGRect {
            CGRect(x: (rect.minX * extent.width - raw.minX) * scale,
                   y: (raw.maxY - rect.maxY * extent.height) * scale,
                   width: rect.width * extent.width * scale,
                   height: rect.height * extent.height * scale)
        }

        let frame = CGRect(x: raw.minX / extent.width,
                           y: (extent.height - raw.maxY) / extent.height,
                           width: raw.width / extent.width,
                           height: raw.height / extent.height)

        return SmartAnalyzer.FaceCrop(
            buffer: buffer,
            skin: skin,
            faceRect: toBuffer(box),
            faceBox: box,
            exclusions: SmartAnalyzer.exclusionRects(for: face).map(toBuffer),
            frame: frame,
            workingSize: extent.size,
            image: rendered)
    }

    // MARK: - Processing

    /// Builds the mask passes for the healing brush. Stamps arrive in the
    /// coordinates of the image being processed, so a crop or a different
    /// working resolution needs a fresh mask.
    func spotsMask(extent: CGRect, spots: [HealSpot]) -> SpotHealing? {
        guard !spots.isEmpty else { return nil }
        let shortSide = min(extent.width, extent.height)
        guard shortSide >= 1 else { return nil }

        // The repair kernel only has to be wide enough for the stamps it
        // serves. Sorting big to small and starting a new class when a stamp is
        // less than half the current size keeps a small blemish from inheriting
        // the smear of a large stamp. Four classes is plenty for a real photo.
        let sorted = spots.sorted { $0.radius > $1.radius }
        var anchors: [CGFloat] = []
        for spot in sorted where anchors.count < 4 {
            if anchors.contains(where: { spot.radius >= $0 * 0.5 }) { continue }
            anchors.append(spot.radius)
        }
        guard !anchors.isEmpty else { return nil }

        var buckets = [[HealSpot]](repeating: [], count: anchors.count)
        for spot in sorted {
            let index = anchors.indices.min {
                abs(log(Double(spot.radius / anchors[$0])))
                    < abs(log(Double(spot.radius / anchors[$1])))
            } ?? 0
            buckets[index].append(spot)
        }

        let passes: [SpotHealing.Pass] = buckets.compactMap { bucket in
            guard let largest = bucket.map(\.radius).max() else { return nil }
            let radius = max(1.5, largest * shortSide)
            // The mask edge is feathered inside the stamp instead of with the
            // image-wide default: a 3 px stamp must not bleed 7 px into clean
            // skin around it.
            let feather = max(1.2, min(0.004 * shortSide, radius * 0.35))
            guard let mask = MaskBuilder.makeMask(
                extent: extent,
                shapes: HealGeometry.shapes(for: bucket,
                                            aspect: extent.width / max(1, extent.height)),
                feather: feather) else { return nil }
            return SpotHealing.Pass(mask: mask, radius: radius)
        }
        guard !passes.isEmpty else { return nil }
        return SpotHealing(passes: passes)
    }

    func process(_ source: CIImage,
                 adjustments a: Adjustments,
                 masks: MaskSet?,
                 faces: [FaceGeometry] = [],
                 spots: SpotHealing? = nil,
                 art: [Sticker] = [],
                 focus: FaceGeometry? = nil) -> CIImage {
        let extent = source.extent
        // Every radius is expressed relative to image size so the preview and
        // the full-resolution export look the same.
        let scale = max(0.5, min(3.0, min(extent.width, extent.height) / 1400))

        var image = source

        // 0) Manual healing runs before anything else: the repaired patch is
        //    what the automatic skin passes should then work over, and it is
        //    not limited to the face masks because the user can stamp anywhere.
        if let spots {
            for pass in spots.passes {
                image = SkinEngine.healSpots(image, mask: pass.mask, radius: pass.radius)
            }
        }

        // 1) Local retouch runs first, while the masks still line up with the
        //    feature positions they were built from. Warping first would move
        //    eyes and lips out from under their own masks.
        if let skinMask = masks?.skin, let textureMask = masks?.skinTexture {
            // Blemish size scales with the face, not the image: a spot is a
            // roughly constant fraction of a face's width. A selected face is
            // what its owner is working on, so it sets the class; otherwise
            // the median of every accepted face does, so a group photo is not
            // tuned to whoever happens to be first. The fraction, not a pixel
            // radius, crosses the preview/export boundary.
            if a.blemish > 0 {
                let fraction = Self.blemishRadiusFraction(faces: faces, focus: focus,
                                                          extent: extent)
                image = SkinEngine.removeBlemishes(image, strength: a.blemish,
                                                   mask: textureMask, radiusFraction: fraction)
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
            if a.skinFinish != 0 {
                image = SkinEngine.applySkinFinish(image, strength: a.skinFinish,
                                                   mask: skinMask, scale: scale)
            }
            if a.shine > 0 {
                image = SkinEngine.reduceShine(image, strength: a.shine,
                                               mask: skinMask, scale: scale)
            }
        }

        // 1b) Body skin. Uses the person mask rather than face landmarks, so a
        //     full-length portrait is treated as a body rather than a face with
        //     a lot of background around it.
        if (a.bodySmooth > 0 || a.bodyTone != 0), let person = masks?.person {
            let bodyMask = SceneEngine.bodySkinMask(person: person, image: image)
            if a.bodySmooth > 0 {
                image = SkinEngine.smoothSkin(image, strength: a.bodySmooth,
                                              texturePreserve: max(a.texturePreserve, 65),
                                              mask: bodyMask, scale: scale)
            }
            if a.bodyTone != 0 {
                image = SkinEngine.brightenSkin(image, strength: a.bodyTone, mask: bodyMask)
            }
        }

        // 2) Under-eye correction.
        if a.darkCircles > 0, let underEyeMask = masks?.underEyes {
            image = SkinEngine.correctDarkCircles(image, strength: a.darkCircles,
                                                  mask: underEyeMask, scale: scale)
        }

        // 3) Teeth and eyes. Alignment runs first: it closes the gaps between
        //    teeth, and whitening then treats the straightened enamel as one
        //    surface instead of brightening both sides of a dark line.
        if a.teethAlign > 0, let teethMask = masks?.teeth {
            let gapRadius = (focus ?? faces.first)?.enamelRect.map { $0.height * extent.height * 0.45 }
                ?? (min(extent.width, extent.height) * 0.006)
            let grownMask = grown(teethMask,
                                  by: max(1, gapRadius * 0.8),
                                  feather: max(1.5, gapRadius * 0.35))
            // Growing the gated enamel is what reaches the dark gaps, but it
            // also reaches the lips, and filling a lip with enamel colour is
            // what tinted them. The mouth regions stop at the lip line; their
            // feather lets the fill fade instead of ending on a seam. They are
            // kept tight because the only pixels the kernel changes are gaps
            // inside the band, so nothing needs to blend across the lip.
            let mouthRegions = faces.compactMap { face -> CIImage? in
                guard face.hasVisibleTeeth,
                      let rect = face.enamelRect.flatMap({ validRect($0) }) else { return nil }
                return MaskBuilder.makeMask(extent: extent,
                                            shapes: [MaskShape(rect: rect, cornerRadius: 0.30)],
                                            feather: max(1.5, gapRadius * 0.2))
            }
            let searchMask = unionAll(mouthRegions).map { MaskBuilder.intersect(grownMask, $0) }
                ?? grownMask
            image = SkinEngine.alignTeeth(image, strength: a.teethAlign,
                                          mask: searchMask, radius: gapRadius)
        }
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
        if a.irisEnhance > 0, let irisMask = masks?.iris {
            image = SkinEngine.enhanceIris(image, strength: a.irisEnhance,
                                           mask: irisMask, scale: scale)
        }
        if a.lashDarken > 0, let lashMask = masks?.lashes {
            image = SkinEngine.darkenLashes(image, strength: a.lashDarken, mask: lashMask)
        }
        if a.lensTint > 0, let irisMask = masks?.iris {
            image = MakeupEngine.applyLens(image, strength: a.lensTint,
                                           mask: irisMask, color: a.lensColor)
        }

        // 3b) Makeup, after the skin work: smoothing first would dilute the
        //     colour and blur its edge, and a flush laid on finished skin keeps
        //     both. Still ahead of the warp, so it travels with the features.
        if a.eyeshadow > 0, let lidMask = masks?.lids {
            image = MakeupEngine.applyShadow(image, strength: a.eyeshadow,
                                             mask: lidMask, color: a.shadowColor)
        }
        if a.eyeliner > 0, let linerMask = masks?.liners {
            image = MakeupEngine.applyLiner(image, strength: a.eyeliner,
                                            mask: linerMask, color: a.linerColor)
        }
        if a.lipTint > 0, let lipMask = masks?.lips {
            image = MakeupEngine.tintLips(image, strength: a.lipTint,
                                          mask: lipMask, color: a.lipColor)
        }
        if a.lipGloss > 0, let lipMask = masks?.lips {
            image = MakeupEngine.addGloss(image, strength: a.lipGloss,
                                          mask: lipMask, scale: scale)
        }
        if a.blush > 0, let cheekMask = masks?.cheeks {
            image = MakeupEngine.applyBlush(image, strength: a.blush,
                                            mask: cheekMask, color: a.blushColor)
        }
        if a.browDefine > 0, let browMask = masks?.brows {
            image = MakeupEngine.defineBrows(image, strength: a.browDefine,
                                             mask: browMask, color: a.browColor, scale: scale)
        }
        if a.contour > 0, let contourMask = masks?.contours {
            image = MakeupEngine.applyContour(image, strength: a.contour,
                                              mask: contourMask, color: a.contourColor)
        }
        if a.hairColor > 0 || a.hairShine > 0 || a.hairVolume > 0,
           let hairGeometry = masks?.hair {
            // The head band is geometric; the subject silhouette trims it so a
            // wall, curtain or sky behind the head cannot be dyed.
            let hairMask = masks?.person.map { MaskBuilder.intersect(hairGeometry, $0) }
                ?? hairGeometry
            if a.hairColor > 0 {
                image = MakeupEngine.dyeHair(image, strength: a.hairColor,
                                             mask: hairMask, color: a.hairTint)
            }
            if a.hairShine > 0 {
                image = MakeupEngine.addHairShine(image, strength: a.hairShine,
                                                  mask: hairMask, scale: scale)
            }
            if a.hairVolume > 0, let face = focus ?? faces.first {
                // The crown is the head band around the hairline; the bulge is
                // centred there, and the mask is grown by a fraction of its own
                // radius so the new volume is not blended away at the old edge.
                let box = face.hairRect
                let center = CGPoint(x: box.midX * extent.width,
                                     y: box.midY * extent.height)
                let radius = max(box.width * extent.width,
                                 box.height * extent.height) * 0.62
                let volumeMask = grown(hairMask,
                                       by: max(1, radius * 0.16),
                                       feather: max(2, radius * 0.10))
                image = SceneEngine.addHairVolume(image, mask: volumeMask,
                                                  center: center, radius: radius,
                                                  amount: a.hairVolume)
            }
        }

        // 4) Geometry after the local edits: the warp then carries the
        //    retouched pixels with the features, and every mask stays aligned.
        //
        //    Feature moves run first with only the brows held back; silhouette
        //    moves run second with the eyes, lips and brows held back, so a
        //    slimmer jaw never drags the mouth sideways.
        if a.hasReshape, !faces.isEmpty {
            let controls = faces.flatMap { FeatureReshaper.controls(for: $0, adjustments: a) }
            let featureMoves = controls.filter { !$0.protectFeatures }
            let shapeMoves = controls.filter { $0.protectFeatures }
            if !featureMoves.isEmpty {
                image = FeatureReshaper.apply(image, controls: featureMoves,
                                              protection: masks?.brows)
            }
            if !shapeMoves.isEmpty {
                image = FeatureReshaper.apply(image, controls: shapeMoves,
                                              protection: featureProtection(masks))
            }
        }
        if a.bodySlim != 0, let person = masks?.person {
            image = FeatureReshaper.applyBodySlim(image, mask: person, amount: a.bodySlim)
        }
        // Pose shaping runs after the overall slim: the landmarks describe the
        // body as it was, and the displacements are small enough that the
        // order is visually identical — but this way the waist band follows
        // the subject's own hips and shoulders rather than the frame centre.
        if a.bodyWaist != 0 || a.bodyArms != 0 || a.bodyLegs != 0,
           let pose = masks?.pose, let person = masks?.person {
            let bodyControls = FeatureReshaper.bodyControls(for: pose, adjustments: a,
                                                            extent: extent)
            image = FeatureReshaper.applyBodyShape(image, controls: bodyControls, mask: person)
        }

        // 5) Global color and light.
        image = applyGlobal(image, a)

        // 6) Background last: everything in front of it has already been
        //    retouched, so the falloff never blurs work that was meant to stay
        //    sharp on the subject.
        if (a.backgroundBlur != 0 || a.backgroundTone != 0 || a.backgroundSaturation != 0),
           let person = masks?.person {
            image = SceneEngine.applyBackground(image, person: person,
                                                blur: a.backgroundBlur,
                                                tone: a.backgroundTone,
                                                saturation: a.backgroundSaturation,
                                                scale: scale)
        }
        // A solid backdrop is graded like the blurred one — behind the subject
        // and before removal — so compositing order stays predictable.
        if a.backgroundFill > 0, let person = masks?.person {
            image = SceneEngine.fillBackground(image, person: person,
                                               color: a.backgroundFillColor,
                                               amount: a.backgroundFill)
        }
        if a.backgroundRemove, let person = masks?.person {
            image = SceneEngine.removeBackground(image, person: person)
        }

        // 7) Art sits on top of everything, including a replaced background:
        //    a sticker is placed on the finished picture, not under its grade.
        if !art.isEmpty {
            image = ArtRenderer.apply(image, stickers: art)
        }

        return image.cropped(to: extent)
    }

    /// Eyes, lips and brows as one mask, used to hold the features in place
    /// while the face around them is reshaped.
    private func featureProtection(_ masks: MaskSet?) -> CIImage? {
        guard let masks else { return nil }
        let parts = [masks.eyes, masks.lips, masks.brows].compactMap { $0 }
        guard var combined = parts.first else { return nil }
        for part in parts.dropFirst() {
            combined = MaskBuilder.union(combined, part)
        }
        return combined
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
        // The curve shapes the tonal balance the sliders above just set; HSL
        // then goes after the split tone so a targeted band is the last colour
        // decision, not something the global warm/cool pass can undo.
        if a.curveShadows != 0 || a.curveMidtones != 0 || a.curveHighlights != 0 {
            image = LookEngine.applyToneCurve(image,
                                              shadows: a.curveShadows,
                                              midtones: a.curveMidtones,
                                              highlights: a.curveHighlights)
        }
        if a.splitTone != 0 {
            image = LookEngine.applySplitTone(image, strength: a.splitTone)
        }
        let hslActive = a.hslHue.contains { $0 != 0 }
            || a.hslSaturation.contains { $0 != 0 }
            || a.hslLuminance.contains { $0 != 0 }
        if hslActive {
            image = LookEngine.applyHSL(image,
                                        hue: a.hslHue,
                                        saturation: a.hslSaturation,
                                        luminance: a.hslLuminance)
        }
        if a.clarity > 0 {
            // Luminance-only: sharpening the colour channels is what puts
            // orange/cyan fringes on high-contrast edges such as lashes and
            // jewellery.
            let sharpened = image.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: max(1.5, shortSide * 0.004),
                kCIInputIntensityKey: 0.75 * a.clarity / 100
            ])
            image = SkinEngine.keepLuminance(sharpened, over: image)
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
    ///
    /// `maxDimension` downscales the longest edge with a Lanczos pass; it never
    /// enlarges, so a target larger than the photo writes the photo as-is.
    func write(_ image: CIImage,
               to url: URL,
               format: ExportFormat,
               quality: Double,
               colorSpace: CGColorSpace? = nil,
               metadata: [CFString: Any] = [:],
               stripPrivacyMetadata: Bool = true,
               maxDimension: CGFloat? = nil) -> Bool {
        let ciFormat: CIFormat = format == .jpeg ? .RGBA8 : .RGBA16
        var output = image
        if let maxDimension, maxDimension > 0 {
            let longest = max(image.extent.width, image.extent.height)
            if longest > maxDimension, let scaled = Self.scaled(image, by: maxDimension / longest) {
                output = scaled
            }
        }
        // A removed background is transparent, and JPEG has no alpha channel:
        // flatten onto white so the file has a real backdrop instead of the
        // black pixels an ignored alpha channel would leave behind.
        var flattened = output
        if format == .jpeg {
            let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
                .cropped(to: output.extent)
            flattened = output.composited(over: white)
        }
        guard let cgImage = renderCGImage(flattened, scale: 1, colorSpace: colorSpace, format: ciFormat) else {
            return false
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                              format.utType.identifier as CFString,
                                                              1,
                                                              nil) else { return false }
        var properties = metadata
        if stripPrivacyMetadata {
            properties = Self.strippedPrivacyMetadata(properties)
        }
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

    /// Removes the keys that say where a photo was taken or who owns the gear.
    /// Only these keys: the rest of EXIF still describes how the picture was
    /// taken, which an edit has no reason to discard. The artist lives in TIFF;
    /// the serials and comments live in EXIF; the location is its own
    /// dictionary.
    static func strippedPrivacyMetadata(_ metadata: [CFString: Any]) -> [CFString: Any] {
        var properties = metadata
        properties.removeValue(forKey: kCGImagePropertyGPSDictionary)
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            for key in [kCGImagePropertyExifUserComment,
                        kCGImagePropertyExifCameraOwnerName,
                        kCGImagePropertyExifBodySerialNumber,
                        kCGImagePropertyExifLensSerialNumber,
                        kCGImagePropertyExifImageUniqueID] {
                exif.removeValue(forKey: key)
            }
            properties[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFArtist)
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        return properties
    }

    /// Lanczos resample, moved back to a zero origin so the writer sees the
    /// same extent as an unscaled export.
    private static func scaled(_ image: CIImage, by scale: CGFloat) -> CIImage? {
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1, forKey: kCIInputAspectRatioKey)
        guard let out = filter.outputImage else { return nil }
        let extent = out.extent
        return out.transformed(by: CGAffineTransform(translationX: -extent.origin.x,
                                                     y: -extent.origin.y))
    }
}

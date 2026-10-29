import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

/// Joints from Vision's body-pose pass, in normalized image coordinates with a
/// bottom-left origin, matching `FaceGeometry`.
///
/// Body shaping needs the subject's own hips, shoulders and knees: a waist that
/// is found from the frame centre squeezes whatever happens to be in the middle,
/// while a waist found from these joints squeezes the person. Only the joints the
/// shaper uses are carried.
struct BodyPose {
    struct Joint {
        var point: CGPoint
        var confidence: Double

        var isUsable: Bool { confidence >= 0.3 }
    }

    var leftShoulder: Joint?
    var rightShoulder: Joint?
    var leftElbow: Joint?
    var rightElbow: Joint?
    var leftHip: Joint?
    var rightHip: Joint?
    var leftKnee: Joint?
    var rightKnee: Joint?

    /// A pose is usable when it has something to anchor the torso — both hips,
    /// or failing that both shoulders. A lone confident elbow is not a body.
    var isUsable: Bool {
        (leftHip?.isUsable == true && rightHip?.isUsable == true)
            || (leftShoulder?.isUsable == true && rightShoulder?.isUsable == true)
    }

    /// Which body groups this pose can actually drive. The UI reads these to
    /// say what a slider will and will not reach, instead of promising a waist
    /// when Vision only found the shoulders.
    var hasWaistJoints: Bool {
        BodyPose.midpoint(leftHip, rightHip) != nil
            && BodyPose.midpoint(leftShoulder, rightShoulder) != nil
    }

    var hasArmJoints: Bool {
        (leftShoulder?.isUsable == true && leftElbow?.isUsable == true)
            || (rightShoulder?.isUsable == true && rightElbow?.isUsable == true)
    }

    var hasLegJoints: Bool {
        (leftHip?.isUsable == true && leftKnee?.isUsable == true)
            || (rightHip?.isUsable == true && rightKnee?.isUsable == true)
    }

    static func midpoint(_ a: Joint?, _ b: Joint?) -> CGPoint? {
        guard let a, let b, a.isUsable, b.isUsable else { return nil }
        return CGPoint(x: (a.point.x + b.point.x) / 2, y: (a.point.y + b.point.y) / 2)
    }

    static func distance(_ a: Joint?, _ b: Joint?) -> CGFloat? {
        guard let a, let b, a.isUsable, b.isUsable else { return nil }
        return hypot(b.point.x - a.point.x, b.point.y - a.point.y)
    }

    /// How much of the body this pose pins down. A pose with hips and knees can
    /// drive a waist, an arm and a leg; one that guessed a neck and two
    /// shoulders can drive none of them.
    var usableJoints: Int {
        [leftShoulder, rightShoulder, leftElbow, rightElbow,
         leftHip, rightHip, leftKnee, rightKnee]
            .compactMap { $0 }
            .filter(\.isUsable)
            .count
    }

    private var confidenceSum: Double {
        [leftShoulder, rightShoulder, leftElbow, rightElbow,
         leftHip, rightHip, leftKnee, rightKnee]
            .compactMap { $0 }
            .filter(\.isUsable)
            .reduce(0) { $0 + $1.confidence }
    }

    /// The most complete pose Vision offered, with summed confidence as the
    /// tie-break so two equally complete skeletons resolve consistently.
    static func best(among poses: [BodyPose]) -> BodyPose? {
        poses.max { lhs, rhs in
            (lhs.usableJoints, lhs.confidenceSum) < (rhs.usableJoints, rhs.confidenceSum)
        }
    }
}

/// On-device person segmentation, and the two whole-scene tools built on it.
///
/// The face landmark pass describes a portrait's features, not the body or the
/// room behind it. Vision's person segmentation answers exactly that question
/// — which pixels belong to the subject — so Body and Background can work on a
/// full-length photo without a new model or an upload.
enum PersonAnalyzer {

    /// A soft mask where the subject is white and the scene behind is black,
    /// scaled to `image.extent`. Nil when nobody was found or Vision could not
    /// answer, which is the honest state for a landscape or a close-up object.
    ///
    /// Segmentation runs on a bounded copy: `.balanced` at 1600 px is enough to
    /// separate a silhouette, and it keeps a slider drag from paying for a full
    /// resolution pass. The mask is scaled back up, and every consumer feathers
    /// it, so the soft edge stays soft at any output size.
    static func mask(for image: CIImage, maxDimension: CGFloat = 1600) -> CIImage? {
        guard let prepared = prepare(image, maxDimension: maxDimension),
              let mask = segmentation(of: prepared, extent: image.extent)
        else { return nil }
        return mask
    }

    /// The silhouette plus the body joints from one prepared copy. Both tools
    /// that need the subject share one render and one analysis task, so asking
    /// for a waist slim does not pay for segmentation twice.
    static func analysis(for image: CIImage,
                         maxDimension: CGFloat = 1600) -> (mask: CIImage, pose: BodyPose?)? {
        guard let prepared = prepare(image, maxDimension: maxDimension),
              let mask = segmentation(of: prepared, extent: image.extent)
        else { return nil }
        return (mask, pose(in: prepared))
    }

    private static func prepare(_ image: CIImage,
                                maxDimension: CGFloat) -> CGImage? {
        let extent = image.extent
        guard extent.width > 8, extent.height > 8 else { return nil }

        let scale = min(1, maxDimension / max(extent.width, extent.height))
        let width = max(1, (extent.width * scale).rounded())
        let height = max(1, (extent.height * scale).rounded())
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        let prepared = scale >= 1
            ? image.cropped(to: extent)
            : image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .cropped(to: target)

        return ImageProcessor.shared.renderCGImage(prepared, scale: 1, format: .RGBA8)
    }

    private static func segmentation(of cgImage: CGImage, extent: CGRect) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }

        let raw = CIImage(cvPixelBuffer: observation.pixelBuffer)
        let rawExtent = raw.extent
        guard rawExtent.width > 1, rawExtent.height > 1 else { return nil }

        let sx = extent.width / rawExtent.width
        let sy = extent.height / rawExtent.height
        let scaled = raw
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: extent.minX - rawExtent.minX * sx,
                                               y: extent.minY - rawExtent.minY * sy))
            .cropped(to: extent)

        // A mask that is almost entirely black means Vision picked out a few
        // pixels at the frame edge, not a subject. Treat it as "no person".
        guard coverage(of: scaled) > 0.01 else { return nil }
        return scaled
    }

    /// Joints from Vision's body-pose pass on the same prepared copy.
    ///
    /// Vision returns one observation per person it recognises and puts the
    /// nearest one first, which is not always the subject: a shelf of posters
    /// can outrank the woman standing in front of it. An observation that only
    /// found her head and shoulders is still "usable" for a torso, yet it has
    /// no hips, elbows or knees, so every waist, arm and leg move would quietly
    /// do nothing. Pick the skeleton that pins down the most joints instead.
    private static func pose(in cgImage: CGImage) -> BodyPose? {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observations = request.results, !observations.isEmpty else { return nil }

        var candidates: [BodyPose] = []
        for observation in observations {
            guard let points = try? observation.recognizedPoints(.all) else { continue }

            func joint(_ name: VNHumanBodyPoseObservation.JointName) -> BodyPose.Joint? {
                guard let recognized = points[name], recognized.confidence > 0.2 else { return nil }
                return BodyPose.Joint(point: recognized.location,
                                      confidence: Double(recognized.confidence))
            }

            let pose = BodyPose(leftShoulder: joint(.leftShoulder),
                                rightShoulder: joint(.rightShoulder),
                                leftElbow: joint(.leftElbow),
                                rightElbow: joint(.rightElbow),
                                leftHip: joint(.leftHip),
                                rightHip: joint(.rightHip),
                                leftKnee: joint(.leftKnee),
                                rightKnee: joint(.rightKnee))
            if pose.isUsable { candidates.append(pose) }
        }
        return BodyPose.best(among: candidates)
    }

    /// Mean coverage of an opaque grayscale mask, read from a 1×1 average.
    static func coverage(of mask: CIImage) -> Double {
        let average = mask.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: mask.extent)
        ])
        var pixel = [UInt8](repeating: 0, count: 4)
        ImageProcessor.shared.context.render(average, toBitmap: &pixel, rowBytes: 4,
                                            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                            format: .RGBA8, colorSpace: nil)
        return Double(pixel[0]) / 255.0
    }
}

enum SceneEngine {

    /// The body's skin: the person mask intersected with a real skin-colour
    /// gate. Brightness and saturation alone cannot tell skin from cloth — a
    /// black dress encodes almost as bright as shadowed skin — so the gate
    /// also constrains chroma to the YCbCr skin box. Fabric that merely looks
    /// skin-ish (the red shirt in the self-test scene) fails the chroma bands
    /// and keeps its texture.
    static func bodySkinMask(person: CIImage, image: CIImage) -> CIImage {
        let extent = image.extent
        guard let gate = MaskBuilder.colorGate(image, lumaMin: 0.02,
                                               lumaMax: 0.99, saturationMax: 0.70,
                                               saturationMin: 0.10, softness: 0.045,
                                               cbRange: -0.22...0.02,
                                               crRange: 0.0...0.19)
        else { return person }
        let skin = MaskBuilder.intersect(person, gate)
        let shortSide = min(extent.width, extent.height)
        return skin.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: max(1.5, shortSide * 0.006)
            ])
            .cropped(to: extent)
    }

    /// Blur and feather radii for the background pass, shared by preview and
    /// export. The feather has to keep up with the blur: a fixed-radius
    /// feather over a heavily blurred background lets the subject edge read
    /// as a cut-out, and a radius that scales at the preview but not at export
    /// shows a wider halo there. Both radii grow together, so the seam looks
    /// the same at any size.
    static func backgroundRadii(shortSide: CGFloat,
                                blur: Double,
                                scale: CGFloat) -> (blur: CGFloat, feather: CGFloat) {
        let blurRadius = blur > 0.001
            ? max(2, shortSide * 0.013 * min(1, blur / 100) * max(0.5, scale))
            : 0
        let feather = max(2, max(shortSide * 0.007, blurRadius * 1.15))
        return (blurRadius, feather)
    }

    /// Blur, tone and saturation applied to everything the subject does not
    /// occupy. One mask pass does all three so the subject edge is feathered
    /// once, at the same radius, and cannot show a different seam per slider.
    static func applyBackground(_ image: CIImage,
                                person: CIImage,
                                blur: Double,
                                tone: Double,
                                saturation: Double,
                                scale: CGFloat) -> CIImage {
        let extent = image.extent
        let shortSide = min(extent.width, extent.height)
        guard shortSide > 8 else { return image }

        let radii = backgroundRadii(shortSide: shortSide, blur: blur, scale: scale)

        let background = person.applyingFilter("CIColorInvert").cropped(to: extent)
        let feathered = background.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: radii.feather
            ])
            .cropped(to: extent)

        var processed = image
        if abs(tone) > 0.001 || abs(saturation) > 0.001 {
            processed = processed.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: 0.22 * min(1, max(-1, tone / 100)),
                kCIInputSaturationKey: max(0, 1 + min(1, max(-1, saturation / 100)))
            ]).cropped(to: extent)
        }
        if radii.blur > 0.001 {
            processed = processed.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radii.blur])
                .cropped(to: extent)
        }
        guard processed !== image else { return image }

        return SkinEngine.blend(processed, over: image, mask: feathered, strength: 1)
    }
}

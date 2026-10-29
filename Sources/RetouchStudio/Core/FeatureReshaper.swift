import CoreGraphics
import CoreImage
import Foundation

/// Localized geometric reshaping of facial features.
///
/// Why a warp kernel rather than scaling the image region:
///   resizing a rectangle would move the feature's edges and tear the
///   surrounding skin. A warp kernel applies a *local* transform whose effect
///   decays smoothly to zero at the edge of an influence ellipse, so the skin
///   around the eye/nose/lip blends continuously and the rest of the photo is
///   bit-for-bit unchanged.
///
/// Each control scales a feature about its own centre. `scale > 1` enlarges,
/// `scale < 1` shrinks. It works in the normalized (0...1, bottom-left origin)
/// space the FaceGeometry uses, and converts to pixels internally, so the same
/// values produce the same result at preview and at full resolution.
struct ReshapeControl {
    var center: CGPoint       // normalized
    var radius: CGSize        // normalized; influence ellipse semi-axes
    var scale: CGSize         // >1 enlarges, <1 shrinks (x and y independently)
    /// True when the control moves the face around a feature rather than the
    /// feature itself, so eyes, lips and brows must stay put. A jawline or
    /// cheek warp that drags the mouth with it reads as a different person.
    var protectFeatures: Bool = false

    static let inactive = ReshapeControl(
        center: CGPoint(x: 0, y: 0),
        radius: CGSize(width: 0.0001, height: 0.0001),
        scale: CGSize(width: 1, height: 1)
    )

    var isActive: Bool {
        abs(scale.width - 1) > 0.0005 || abs(scale.height - 1) > 0.0005
    }
}

public enum FeatureReshaper {

    /// Up to 8 controls per kernel pass. More than that (e.g. both eyes plus
    /// both cheeks plus jaw plus chin plus nose plus lips) is split across
    /// sequential passes, which composes correctly because each pass only
    /// affects its own influence region.
    static let controlsPerPass = 8

    private static let kernel: CIWarpKernel? = makeReshapeKernel()

    private static func makeReshapeKernel() -> CIWarpKernel? {
        let source = """
        vec2 applyLocal(vec2 p, vec2 c, vec2 r, vec2 sc) {
            float d = length((p - c) / r);
            if (d >= 1.0) { return p; }
            if (abs(sc.x - 1.0) < 0.001 && abs(sc.y - 1.0) < 0.001) { return p; }
            // Smoothstep falloff: full strength at the centre, zero at r.
            float t = 1.0 - d;
            float w = t * t * (3.0 - 2.0 * t);
            vec2 invS = vec2(1.0 / max(sc.x, 0.01), 1.0 / max(sc.y, 0.01));
            vec2 scale = mix(vec2(1.0), invS, w);
            return c + (p - c) * scale;
        }

        kernel vec2 reshape(vec2 c0, vec2 r0, vec2 s0,
                            vec2 c1, vec2 r1, vec2 s1,
                            vec2 c2, vec2 r2, vec2 s2,
                            vec2 c3, vec2 r3, vec2 s3,
                            vec2 c4, vec2 r4, vec2 s4,
                            vec2 c5, vec2 r5, vec2 s5,
                            vec2 c6, vec2 r6, vec2 s6,
                            vec2 c7, vec2 r7, vec2 s7)
        {
            vec2 p = destCoord();
            p = applyLocal(p, c0, r0, s0);
            p = applyLocal(p, c1, r1, s1);
            p = applyLocal(p, c2, r2, s2);
            p = applyLocal(p, c3, r3, s3);
            p = applyLocal(p, c4, r4, s4);
            p = applyLocal(p, c5, r5, s5);
            p = applyLocal(p, c6, r6, s6);
            p = applyLocal(p, c7, r7, s7);
            return p;
        }
        """
        return CIWarpKernel(source: source)
    }

    /// Blends `top` over `base` through a mask, white keeping `top`. A warp
    /// kernel cannot sample a second image — `__sample` parameters do not
    /// compile — so holding features still or confining a warp to the subject
    /// is a compositing step at the destination.
    private static func blend(_ top: CIImage, over base: CIImage, mask: CIImage) -> CIImage {
        top.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: base.cropped(to: top.extent),
            kCIInputMaskImageKey: mask.cropped(to: top.extent)
        ]).cropped(to: top.extent)
    }

    /// True when the kernel compiled; the caller can fall back gracefully.
    static var isAvailable: Bool { kernel != nil }

    /// Applies all controls to `image`. Controls are expressed in normalized
    /// image coordinates and converted using `image.extent`.
    ///
    /// `protection` holds the warp back where it is white. It is applied once
    /// after every pass, so a protected feature stays exactly on top of its
    /// original pixels no matter how many controls ran.
    static func apply(_ image: CIImage,
                      controls: [ReshapeControl],
                      protection: CIImage? = nil) -> CIImage {
        let active = controls.filter { $0.isActive }
        guard !active.isEmpty else { return image }

        guard let kernel = kernel else { return image }
        let extent = image.extent
        guard extent.width > 8, extent.height > 8 else { return image }

        // Pixel-space conversion. Note Core Image's origin is bottom-left, the
        // same as FaceGeometry's normalized space, so y maps directly.
        func pixelVector(_ control: ReshapeControl) -> (CIVector, CIVector, CIVector) {
            let cx = extent.origin.x + control.center.x * extent.width
            let cy = extent.origin.y + control.center.y * extent.height
            let rx = max(2.0, control.radius.width * extent.width)
            let ry = max(2.0, control.radius.height * extent.height)
            return (CIVector(x: cx, y: cy),
                    CIVector(x: rx, y: ry),
                    CIVector(x: control.scale.width, y: control.scale.height))
        }

        var result = image
        var index = 0
        while index < active.count {
            let slice = Array(active[index..<min(index + controlsPerPass, active.count)])
            index += controlsPerPass

            var arguments: [Any] = []
            for control in slice {
                let (c, r, s) = pixelVector(control)
                arguments.append(c); arguments.append(r); arguments.append(s)
            }
            let inactive = pixelVector(.inactive)
            for _ in slice.count..<controlsPerPass {
                arguments.append(inactive.0)
                arguments.append(inactive.1)
                arguments.append(inactive.2)
            }

            // The ROI must grow by the largest influence radius, otherwise the
            // kernel is handed a tile too small to sample from and the edge of
            // the effect shows a seam.
            let maxRadius = slice.reduce(CGFloat(0)) { partial, control in
                max(partial, max(control.radius.width * extent.width,
                                 control.radius.height * extent.height))
            }
            let margin = maxRadius + 4

            guard let warped = kernel.apply(extent: extent,
                                            roiCallback: { _, rect in
                                                rect.insetBy(dx: -margin, dy: -margin)
                                            },
                                            image: result,
                                            arguments: arguments) else { continue }
            result = warped.cropped(to: extent)
        }
        if let protection {
            result = blend(image, over: result, mask: protection)
        }
        return result
    }

    // MARK: - Body

    /// Horizontal slimming for a whole person, driven by the person mask.
    ///
    /// The frame is warped about the subject's own centre of mass, then blended
    /// back to the original where the person mask is black, so only the subject
    /// narrows and the background keeps its geometry. Anchoring at the frame
    /// centre instead drags an off-centre subject sideways. Positive values
    /// narrow.
    static func applyBodySlim(_ image: CIImage, mask: CIImage, amount: Double) -> CIImage {
        guard abs(amount) > 0.5, let kernel = bodyKernel else { return image }
        let extent = image.extent
        guard extent.width > 8 else { return image }
        let scaleX = 1 - 0.12 * min(1, max(-1, amount / 100))
        let center = CIVector(x: subjectCentre(of: mask) ?? extent.midX, y: extent.midY)
        let margin = extent.width * 0.15 + 4
        // The warp samples further from the anchor, which reaches past the
        // frame edge when the subject touches it; clamping repeats the edge
        // instead of reading transparent black.
        guard let warped = kernel.apply(extent: extent,
                                        roiCallback: { _, rect in
                                            rect.insetBy(dx: -margin, dy: -margin)
                                        },
                                        image: image.clampedToExtent(),
                                        arguments: [center, scaleX])
        else { return image }
        return blend(warped.cropped(to: extent), over: image, mask: mask)
    }

    private static let bodyKernel: CIWarpKernel? = {
        let source = """
        kernel vec2 bodySlim(vec2 center, float scaleX)
        {
            vec2 p = destCoord();
            // The kernel returns the SOURCE position for each destination
            // pixel, so narrowing content means reaching FURTHER from the
            // anchor. Multiplying by a factor below one samples inward and
            // widens the subject — the sign bug this line replaced.
            p.x = center.x + (p.x - center.x) / max(scaleX, 0.01);
            return p;
        }
        """
        return CIWarpKernel(source: source)
    }()

    /// The subject's horizontal centre of mass, in pixels, read from two 1×1
    /// averages with no CPU bitmap: a horizontal weight ramp times the mask,
    /// averaged, then divided by the mask's own average, gives the mask-weighted
    /// mean of x.
    static func subjectCentre(of mask: CIImage) -> CGFloat? {
        let extent = mask.extent
        guard extent.width > 8, extent.height > 8 else { return nil }
        guard let ramp = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: extent.minX, y: extent.midY),
            "inputPoint1": CIVector(x: extent.maxX, y: extent.midY),
            "inputColor0": CIColor(red: 0, green: 0, blue: 0),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1)
        ])?.outputImage?.cropped(to: extent) else { return nil }
        let weighted = ramp.applyingFilter("CIMultiplyBlendMode", parameters: [
            kCIInputBackgroundImageKey: mask
        ]).cropped(to: extent)

        func average(_ image: CIImage) -> Double? {
            let avg = image.applyingFilter("CIAreaAverage", parameters: [
                kCIInputExtentKey: CIVector(cgRect: extent)
            ])
            var pixel = [UInt8](repeating: 0, count: 4)
            ImageProcessor.shared.context.render(avg, toBitmap: &pixel, rowBytes: 4,
                                                 bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                                 format: .RGBA8, colorSpace: nil)
            return Double(pixel[0]) / 255.0
        }
        guard let meanMask = average(mask), meanMask > 0.001,
              let meanWeighted = average(weighted) else { return nil }
        return extent.minX + extent.width * CGFloat(meanWeighted / meanMask)
    }

    // MARK: - Pose shaping

    /// One axis-based narrowing of a body region, in pixels.
    ///
    /// Body shaping is not an ellipse about a joint: a waist is a band along
    /// the torso axis whose squeeze peaks between hips and chest, and an arm
    /// or a leg is a capsule that must taper off before the next joint. The
    /// warp displaces pixels along the perpendicular toward the axis, with a
    /// profile along the axis and a falloff across it, so the silhouette
    /// actually moves. The radial ellipse this replaced died out before it
    /// reached the outline, which is why its sliders could not narrow anything.
    struct BodyControl {
        var axisStart: CGPoint    // pixels
        var axisEnd: CGPoint      // pixels
        /// Half-width of the full-strength band, in pixels.
        var width: CGFloat
        /// Peak compression at the centre of the band; positive narrows.
        var amount: CGFloat
        /// Fraction of the axis where the squeeze reaches full strength.
        var riseEnd: CGFloat
        /// Fraction where it starts to fade back out.
        var fallStart: CGFloat

        var isActive: Bool { abs(amount) > 0.0005 }
    }

    private static let bodyWarpKernel: CIWarpKernel? = {
        let source = """
        kernel vec2 bodyWarp(vec2 a, vec2 b, float width, float amount,
                             float riseEnd, float fallStart)
        {
            vec2 p = destCoord();
            vec2 u = b - a;
            float len = length(u);
            if (len < 1.0) { return p; }
            u /= len;
            vec2 n = vec2(-u.y, u.x);
            vec2 rel = p - a;
            float s = dot(rel, u);
            float d = dot(rel, n);

            // Along the axis: ease in, hold, ease out, so the joints an
            // anchor was found on keep their shape.
            float rise = smoothstep(0.0, max(riseEnd * len, 1.0), s);
            float fall = 1.0 - smoothstep(fallStart * len, len, s);
            // Across the axis: full strength inside the band, gone by 2.2×,
            // so the influence always reaches past the silhouette.
            float across = 1.0 - smoothstep(width, 2.2 * width, abs(d));
            float w = rise * fall * across;
            if (w < 0.001) { return p; }

            // The kernel returns the source position: compressing content by
            // (1 − k) toward the axis means sampling further out by 1/(1 − k).
            // A negative amount inverts that and widens.
            float k = min(amount * w, 0.9);
            float factor = 1.0 / (1.0 - k);
            return p + n * d * (factor - 1.0);
        }
        """
        return CIWarpKernel(source: source)
    }()

    /// Builds the pixel-space body controls from the joints Vision found.
    /// Positive slider values narrow, matching Body Slim.
    static func bodyControls(for pose: BodyPose,
                             adjustments a: Adjustments,
                             extent: CGRect) -> [BodyControl] {
        func px(_ p: CGPoint) -> CGPoint {
            CGPoint(x: extent.minX + p.x * extent.width,
                    y: extent.minY + p.y * extent.height)
        }
        // Joints are normalized per axis, so distances are measured in pixels.
        func dist(_ a: BodyPose.Joint?, _ b: BodyPose.Joint?) -> CGFloat? {
            guard let a, let b, a.isUsable, b.isUsable else { return nil }
            return hypot((b.point.x - a.point.x) * extent.width,
                         (b.point.y - a.point.y) * extent.height)
        }

        var controls: [BodyControl] = []

        if a.bodyWaist != 0,
           let hips = BodyPose.midpoint(pose.leftHip, pose.rightHip),
           let shoulders = BodyPose.midpoint(pose.leftShoulder, pose.rightShoulder) {
            let hipPx = px(hips)
            let shoulderPx = px(shoulders)
            let torso = hypot(shoulderPx.x - hipPx.x, shoulderPx.y - hipPx.y)
            let hipWidth = dist(pose.leftHip, pose.rightHip) ?? torso * 0.6
            if torso > extent.height * 0.02 {
                let amount = min(1, max(-1, a.bodyWaist / 100))
                // Vision's hip joints sit well inside the silhouette — a body
                // reads about 1.5× wider than the joint distance — so the
                // full-strength band has to reach past the outline for the
                // edge itself to move.
                controls.append(BodyControl(
                    axisStart: hipPx,
                    axisEnd: shoulderPx,
                    width: max(hipWidth * 1.35, extent.width * 0.02),
                    amount: 0.16 * amount,
                    riseEnd: 0.42,
                    fallStart: 0.42))
            }
        }

        if a.bodyArms != 0 {
            let amount = min(1, max(-1, a.bodyArms / 100))
            let pairs: [(BodyPose.Joint?, BodyPose.Joint?)] = [
                (pose.leftShoulder, pose.leftElbow),
                (pose.rightShoulder, pose.rightElbow)
            ]
            for (shoulder, elbow) in pairs {
                guard let shoulder, let elbow, shoulder.isUsable, elbow.isUsable else { continue }
                let length = dist(shoulder, elbow) ?? 0
                guard length > extent.width * 0.015 else { continue }
                controls.append(BodyControl(
                    axisStart: px(shoulder.point),
                    axisEnd: px(elbow.point),
                    width: max(length * 0.25, extent.width * 0.012),
                    amount: 0.14 * amount,
                    riseEnd: 0.30,
                    fallStart: 0.70))
            }
        }

        if a.bodyLegs != 0 {
            let amount = min(1, max(-1, a.bodyLegs / 100))
            let pairs: [(BodyPose.Joint?, BodyPose.Joint?)] = [
                (pose.leftHip, pose.leftKnee),
                (pose.rightHip, pose.rightKnee)
            ]
            for (hip, knee) in pairs {
                guard let hip, let knee, hip.isUsable, knee.isUsable else { continue }
                let length = dist(hip, knee) ?? 0
                guard length > extent.width * 0.015 else { continue }
                controls.append(BodyControl(
                    axisStart: px(hip.point),
                    axisEnd: px(knee.point),
                    width: max(length * 0.28, extent.width * 0.012),
                    amount: 0.14 * amount,
                    riseEnd: 0.30,
                    fallStart: 0.70))
            }
        }

        return controls
    }

    /// Applies the pose controls, each in its own pass, and confines the result
    /// to the subject: the background keeps its geometry even where a control's
    /// band overlaps it.
    static func applyBodyShape(_ image: CIImage,
                               controls: [BodyControl],
                               mask: CIImage) -> CIImage {
        let active = controls.filter { $0.isActive }
        guard !active.isEmpty, let kernel = bodyWarpKernel else { return image }
        let extent = image.extent
        guard extent.width > 8, extent.height > 8 else { return image }

        var result = image.clampedToExtent()
        for control in active {
            let length = hypot(control.axisEnd.x - control.axisStart.x,
                               control.axisEnd.y - control.axisStart.y)
            guard length > 1 else { continue }
            // The ROI must reach past the outer falloff plus the largest
            // displacement it produces, or a tile boundary shows as a seam.
            let margin = control.width * 2.2
                * (1.0 / (1.0 - min(abs(control.amount), 0.9)) - 1.0) + 4
            guard let warped = kernel.apply(extent: extent,
                                            roiCallback: { _, rect in
                                                rect.insetBy(dx: -margin, dy: -margin)
                                            },
                                            image: result,
                                            arguments: [
                                                CIVector(cgPoint: control.axisStart),
                                                CIVector(cgPoint: control.axisEnd),
                                                control.width,
                                                control.amount,
                                                control.riseEnd,
                                                control.fallStart
                                            ])
            else { continue }
            result = warped.clampedToExtent()
        }
        return blend(result.cropped(to: extent), over: image, mask: mask)
    }

    // MARK: - Building controls from a face

    /// Turns slider values (all -100...100, where 0 = no change) into controls.
    ///
    /// The mapping is deliberately gentle: at full slider travel an eye grows
    /// about 18%, which is already a strong beauty-retouch move. Anything more
    /// starts to look like a caricature and breaks facial identity.
    static func controls(for face: FaceGeometry, adjustments a: Adjustments) -> [ReshapeControl] {
        var controls: [ReshapeControl] = []
        let box = face.boundingBox
        guard box.width > 0, box.height > 0 else { return [] }

        // --- Eyes ---
        if a.eyeSize != 0 {
            let amount = a.eyeSize / 100
            let scale = 1 + 0.18 * amount
            if let center = FaceGeometry.centroid(of: face.leftEye) {
                controls.append(ReshapeControl(
                    center: center,
                    radius: CGSize(width: face.leftEyeRect.width * 1.5,
                                   height: face.leftEyeRect.height * 2.2),
                    scale: CGSize(width: scale, height: scale)))
            }
            if let center = FaceGeometry.centroid(of: face.rightEye) {
                controls.append(ReshapeControl(
                    center: center,
                    radius: CGSize(width: face.rightEyeRect.width * 1.5,
                                   height: face.rightEyeRect.height * 2.2),
                    scale: CGSize(width: scale, height: scale)))
            }
        }

        // --- Nose: widen/narrow ---
        if a.noseSize != 0 {
            let amount = a.noseSize / 100
            let noseBox = face.noseRect
            if !noseBox.isNull, let center = FaceGeometry.centroid(of: face.nose) {
                // Horizontal only: scaling a nose vertically reads as a
                // different person, whereas width is the usual request.
                controls.append(ReshapeControl(
                    center: center,
                    radius: CGSize(width: noseBox.width * 1.25,
                                   height: noseBox.height * 1.15),
                    scale: CGSize(width: 1 + 0.16 * amount, height: 1 + 0.05 * amount),
                    protectFeatures: true))
            }
        }
        // Nose tip up/down.
        if a.noseTip != 0, let tip = face.noseCrest.min(by: { $0.y < $1.y }) {
            let amount = a.noseTip / 100
            let offset = -0.012 * amount   // negative y = downward in this space
            controls.append(ReshapeControl(
                center: CGPoint(x: tip.x, y: tip.y + offset),
                radius: CGSize(width: face.noseRect.width * 1.1,
                               height: face.noseRect.height * 0.9),
                scale: CGSize(width: 1 + 0.04 * amount, height: 1 + 0.10 * amount),
                protectFeatures: true))
        }

        // --- Lips: full lips = thicker, wider ---
        if a.lipSize != 0, let lipBox = face.lipRect {
            let amount = a.lipSize / 100
            if let center = FaceGeometry.centroid(of: face.lipPolygon) {
                controls.append(ReshapeControl(
                    center: center,
                    radius: CGSize(width: lipBox.width * 0.85,
                                   height: lipBox.height * 1.5),
                    // Vertical emphasis = plumper lips; horizontal is subtle.
                    scale: CGSize(width: 1 + 0.07 * amount, height: 1 + 0.20 * amount)))
            }
        }

        // --- Cheeks: high/rounded vs flat ---
        if a.cheekSize != 0 {
            let amount = a.cheekSize / 100
            for rect in [face.leftCheekRect, face.rightCheekRect] {
                controls.append(ReshapeControl(
                    center: CGPoint(x: rect.midX, y: rect.midY),
                    radius: CGSize(width: rect.width * 0.95, height: rect.height * 0.95),
                    scale: CGSize(width: 1 + 0.13 * amount, height: 1 + 0.13 * amount),
                    protectFeatures: true))
            }
        }

        // --- Jawline: narrow (slimming) or widen ---
        if a.jawWidth != 0 {
            let amount = a.jawWidth / 100
            let (left, right) = face.jawRects
            for rect in [left, right] {
                controls.append(ReshapeControl(
                    center: CGPoint(x: rect.midX, y: rect.midY),
                    radius: CGSize(width: rect.width * 1.1, height: rect.height * 1.1),
                    scale: CGSize(width: 1 + 0.17 * amount, height: 1 + 0.05 * amount),
                    protectFeatures: true))
            }
        }

        // --- Chin: longer / shorter ---
        if a.chinLength != 0 {
            let amount = a.chinLength / 100
            let rect = face.chinRect
            controls.append(ReshapeControl(
                center: CGPoint(x: rect.midX, y: rect.midY),
                radius: CGSize(width: rect.width * 1.1, height: rect.height * 1.3),
                scale: CGSize(width: 1 + 0.05 * amount, height: 1 + 0.16 * amount),
                protectFeatures: true))
        }

        // --- Face shape: overall widen/narrow, and vertical stretch ---
        if a.faceWidth != 0 || a.faceLength != 0 {
            let widthAmount = a.faceWidth / 100
            let lengthAmount = a.faceLength / 100
            let center = CGPoint(x: box.midX, y: box.midY)
            controls.append(ReshapeControl(
                center: center,
                // Extra headroom so the falloff reaches past the jaw and hairline.
                radius: CGSize(width: box.width * 0.78, height: box.height * 0.78),
                scale: CGSize(width: 1 + 0.14 * widthAmount, height: 1 + 0.12 * lengthAmount),
                protectFeatures: true))
        }

        return controls
    }
}

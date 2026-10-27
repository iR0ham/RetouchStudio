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

    private static let kernel: CIWarpKernel? = {
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
    }()

    /// True when the kernel compiled; the caller can fall back gracefully.
    static var isAvailable: Bool { kernel != nil }

    /// Applies all controls to `image`. Controls are expressed in normalized
    /// image coordinates and converted using `image.extent`.
    static func apply(_ image: CIImage, controls: [ReshapeControl]) -> CIImage {
        let active = controls.filter { $0.isActive }
        guard !active.isEmpty, let kernel else { return image }

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

            var arguments: [CIVector] = []
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
        return result
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
                    scale: CGSize(width: 1 + 0.16 * amount, height: 1 + 0.05 * amount)))
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
                scale: CGSize(width: 1 + 0.04 * amount, height: 1 + 0.10 * amount)))
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
                    scale: CGSize(width: 1 + 0.13 * amount, height: 1 + 0.13 * amount)))
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
                    scale: CGSize(width: 1 + 0.17 * amount, height: 1 + 0.05 * amount)))
            }
        }

        // --- Chin: longer / shorter ---
        if a.chinLength != 0 {
            let amount = a.chinLength / 100
            let rect = face.chinRect
            controls.append(ReshapeControl(
                center: CGPoint(x: rect.midX, y: rect.midY),
                radius: CGSize(width: rect.width * 1.1, height: rect.height * 1.3),
                scale: CGSize(width: 1 + 0.05 * amount, height: 1 + 0.16 * amount)))
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
                scale: CGSize(width: 1 + 0.14 * widthAmount, height: 1 + 0.12 * lengthAmount)))
        }

        return controls
    }
}

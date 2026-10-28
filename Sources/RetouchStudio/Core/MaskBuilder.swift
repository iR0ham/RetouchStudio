import CoreGraphics
import CoreImage
import Foundation

/// One shape used to compose a mask. Coordinates are normalized (0...1) with
/// the origin at the bottom-left, matching FaceGeometry and Core Image.
struct MaskShape {
    enum Mode {
        case add
        case erase
    }

    enum Kind {
        case polygon([CGPoint])
        case ellipse(CGRect)
        case roundedRect(CGRect, cornerRadius: CGFloat)
    }

    var mode: Mode = .add
    var kind: Kind

    init(mode: Mode = .add, points: [CGPoint]) {
        self.mode = mode
        self.kind = .polygon(points)
    }

    init(mode: Mode = .add, rect: CGRect, cornerRadius: CGFloat = 0.25) {
        self.mode = mode
        self.kind = .roundedRect(rect, cornerRadius: cornerRadius)
    }

    /// A soft ellipse, used for cheeks, under-eye areas and the chin.
    init(mode: Mode = .add, ellipse rect: CGRect) {
        self.mode = mode
        self.kind = .ellipse(rect)
    }
}

enum MaskBuilder {

    /// Masks are built small and scaled up: cheaper, and the upscale smooths
    /// the edges for free. Higher than before because feature masks (lips,
    /// eyes) need enough resolution to stay accurate after scaling.
    static let maxMaskDimension: CGFloat = 1600

    /// Builds a soft mask that exactly covers `extent`.
    /// White = apply the effect, transparent = leave alone.
    static func makeMask(extent: CGRect,
                         shapes: [MaskShape],
                         feather: CGFloat,
                         softness: CGFloat = 0) -> CIImage? {
        guard extent.width >= 2, extent.height >= 2, !shapes.isEmpty else { return nil }

        let scale = min(1, maxMaskDimension / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))

        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      // Masks are OPAQUE GRAYSCALE: alpha is always 1 and the
                                      // gray level is the coverage. This was measured, not
                                      // assumed. CIBlendWithMask reads the mask's premultiplied
                                      // RGB, so an opaque gray of 0.5 gives half coverage while
                                      // alpha-keyed masks behave inconsistently across filters.
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        context.setShouldAntialias(true)
        // Opaque black = "do not apply the effect here".
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let w = CGFloat(width)
        let h = CGFloat(height)

        for shape in shapes {
            // Opaque white = "apply the effect here".
            context.setFillColor(shape.mode == .add
                                 ? CGColor(red: 1, green: 1, blue: 1, alpha: 1)
                                 : CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.setBlendMode(.normal)

            let path = CGMutablePath()
            switch shape.kind {
            case .polygon(let points):
                guard points.count >= 3 else { continue }
                path.move(to: CGPoint(x: points[0].x * w, y: points[0].y * h))
                for point in points.dropFirst() {
                    path.addLine(to: CGPoint(x: point.x * w, y: point.y * h))
                }
                path.closeSubpath()

            case .ellipse(let rect):
                let mapped = CGRect(x: rect.minX * w, y: rect.minY * h,
                                    width: rect.width * w, height: rect.height * h)
                path.addEllipse(in: mapped)

            case .roundedRect(let rect, let cornerRadius):
                let mapped = CGRect(x: rect.minX * w, y: rect.minY * h,
                                    width: rect.width * w, height: rect.height * h)
                let radius = cornerRadius * min(mapped.width, mapped.height)
                if radius > 1 {
                    path.addRoundedRect(in: mapped, cornerWidth: radius, cornerHeight: radius)
                } else {
                    path.addRect(mapped)
                }
            }

            guard !path.isEmpty else { continue }
            context.addPath(path)
            context.fillPath()
        }

        guard let cgMask = context.makeImage() else { return nil }
        var mask = CIImage(cgImage: cgMask)

        let effectiveFeather = max(feather, softness)
        if effectiveFeather > 0.5 {
            mask = mask.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: effectiveFeather * scale])
                .cropped(to: mask.extent)
        }

        let scaleX = extent.width / w
        let scaleY = extent.height / h
        let scaled = mask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        return scaled
            .transformed(by: CGAffineTransform(translationX: extent.origin.x - scaled.extent.origin.x,
                                               y: extent.origin.y - scaled.extent.origin.y))
            .cropped(to: extent)
    }

    /// Subtracts `hole` from `base` (used to keep features out of the skin
    /// mask, or to cut the iris out of an eye ring).
    ///
    /// A kernel rather than `CIMultiplyBlendMode`, because Core Image blends in
    /// linear light: inverting a mask that is 98% white there leaves about 20%
    /// of the base behind, and that residue is exactly what put skin smoothing
    /// onto the lashes. Both operands are decoded to the values the bitmap holds
    /// before the arithmetic, the same way the pixel gates below do.
    static func subtract(_ hole: CIImage, from base: CIImage) -> CIImage {
        guard let kernel = maskSubtractKernel,
              let cut = kernel.apply(extent: base.extent, arguments: [base, hole]) else {
            let inverted = hole.applyingFilter("CIColorInvert").cropped(to: base.extent)
            return base.applyingFilter("CIMultiplyBlendMode", parameters: [
                kCIInputBackgroundImageKey: inverted
            ]).cropped(to: base.extent)
        }
        return cut.cropped(to: base.extent)
    }

    private static let maskSubtractKernel: CIColorKernel? = {
        let source = """
        kernel vec4 maskSubtract(__sample base, __sample hole)
        {
            vec3 b = pow(clamp(base.rgb, 0.0, 1.0), vec3(0.4545));
            vec3 h = pow(clamp(hole.rgb, 0.0, 1.0), vec3(0.4545));
            float v = b.r * (1.0 - h.r);
            return vec4(pow(vec3(v), vec3(2.2)), 1.0);
        }
        """
        return CIColorKernel(source: source)
    }()

    static func union(_ a: CIImage, _ b: CIImage) -> CIImage {
        a.applyingFilter("CIAdditionCompositing", parameters: [
            kCIInputBackgroundImageKey: b
        ]).cropped(to: a.extent)
    }

    /// Intersects two masks (coverage = product of both gray levels).
    ///
    /// CIMultiplyBlendMode is correct here and was verified numerically: two
    /// opaque grays of 0.3 and 0.5 give a mask value of 34, i.e. 0.15 coverage.
    /// (It only misbehaves on alpha-keyed images, where it multiplies
    /// premultiplied values and a zero-alpha operand silently wins.)
    static func intersect(_ a: CIImage, _ b: CIImage) -> CIImage {
        a.applyingFilter("CIMultiplyBlendMode", parameters: [
            kCIInputBackgroundImageKey: b
        ]).cropped(to: a.extent)
    }

    // MARK: - Pixel gates

    /// A real region is rarely a clean geometric shape: enamel stops where the
    /// gum starts and sclera stops at the iris. This kernel turns those
    /// decisions into a soft mask from luminance and saturation, so the
    /// geometric shape only has to be roughly right.
    ///
    /// A kernel is used instead of CIColorMatrix because saturation is a
    /// max/min ratio, which a linear matrix cannot express.
    private static let colorGateKernel: CIColorKernel? = {
        let source = """
        kernel vec4 colorGate(__sample s, float lumaMin, float lumaMax,
                              float satMax, float softness)
        {
            // Kernels sample the linear working space, but every threshold fed
            // here was measured on 8-bit pixels (AutoAnalyzer) and matches what
            // the eye sees. Encode back to sRGB so both sides of the comparison
            // describe the same values; otherwise only highlights clear the
            // luma floor and saturation reads far too high.
            vec3 c = clamp(s.rgb, 0.0, 1.0);
            c = pow(c, vec3(0.4545));
            float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
            float mx = max(c.r, max(c.g, c.b));
            float mn = min(c.r, min(c.g, c.b));
            float sat = mx > 0.0001 ? (mx - mn) / mx : 0.0;

            float lower = smoothstep(lumaMin - softness, lumaMin + softness, luma);
            float upper = 1.0 - smoothstep(lumaMax - softness, lumaMax + softness, luma);
            float color = 1.0 - smoothstep(satMax - 0.06, satMax + 0.06, sat);
            float v = lower * upper * color;
            return vec4(v, v, v, 1.0);
        }
        """
        return CIColorKernel(source: source)
    }()

    static var isColorGateAvailable: Bool { colorGateKernel != nil }

    /// White where the pixel luminance/saturation fall inside the band.
    /// `lumaMax` 1 and `saturationMax` 1 leave that half of the test open.
    static func colorGate(_ image: CIImage,
                          lumaMin: Double,
                          lumaMax: Double = 1,
                          saturationMax: Double = 1,
                          softness: Double = 0.03) -> CIImage? {
        guard let kernel = colorGateKernel else { return nil }
        let gate = kernel.apply(extent: image.extent, arguments: [
            image, lumaMin, lumaMax, saturationMax, softness
        ])
        return gate?.cropped(to: image.extent)
    }
}

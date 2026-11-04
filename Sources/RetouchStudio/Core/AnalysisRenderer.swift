import CoreGraphics
import CoreImage
import Foundation

/// Draws the face-analysis overlay. Everything is procedural Core Graphics, so
/// the editor preview and the full-resolution export are the same picture.
///
/// The overlay is only lines and dots: the labels and percentages belong to the
/// owner, who adds them after export. A leader line ends at an empty anchor
/// point where that text is meant to go.
enum AnalysisRenderer {

    // MARK: - Entry points

    static func apply(_ image: CIImage, faces: [FaceGeometry],
                      settings: AnalysisSettings) -> CIImage {
        guard settings.isEnabled else { return image }
        let extent = image.extent
        guard let overlay = render(size: extent.size, faces: faces, settings: settings,
                                   photoRect: CGRect(origin: .zero, size: extent.size))
        else { return image }
        return CIImage(cgImage: overlay)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .composited(over: image)
            .cropped(to: extent)
    }

    /// The overlay over a photo that fills the canvas.
    static func render(size: CGSize, faces: [FaceGeometry],
                       settings: AnalysisSettings) -> CGImage? {
        render(size: size, faces: faces, settings: settings,
               photoRect: CGRect(origin: .zero, size: size))
    }

    /// `photoRect` is where the photo sits on the canvas, in canvas pixels with
    /// the origin at the bottom-left. A poster export insets it, so the same
    /// callouts land on the photo while the leader lines run into the empty band.
    static func render(size: CGSize, faces: [FaceGeometry], settings: AnalysisSettings,
                       photoRect: CGRect) -> CGImage? {
        guard size.width >= 2, size.height >= 2, !faces.isEmpty else { return nil }
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high

        let metrics = Metrics(photo: photoRect, canvas: size,
                              weight: CGFloat(min(260, max(40, settings.lineWeight))) / 100)

        for face in faces {
            if settings.showsMesh {
                drawMesh(in: ctx, face: face, m: metrics, settings: settings)
            } else {
                if settings.showsFaceOutline {
                    drawFaceOutline(in: ctx, face: face, m: metrics, settings: settings)
                }
                for region in settings.primaryCallouts {
                    drawContour(in: ctx, region: region, face: face, m: metrics, settings: settings)
                }
            }
        }

        if let primary = primaryFace(faces) {
            drawCallouts(in: ctx, face: primary, m: metrics, settings: settings,
                         poster: photoRect.width < size.width - 0.5)
        }

        return ctx.makeImage()
    }

    static func primaryFace(_ faces: [FaceGeometry]) -> FaceGeometry? {
        faces.max {
            $0.boundingBox.width * $0.boundingBox.height
                < $1.boundingBox.width * $1.boundingBox.height
        }
    }

    /// The poster export: the photo sits on a larger canvas, and the band
    /// around it is the photo's own edge, clamped and blurred, so the leader
    /// lines end somewhere that belongs to the picture.
    static func poster(_ image: CIImage, faces: [FaceGeometry],
                       settings: AnalysisSettings) -> CIImage {
        let extent = image.extent
        let margin = CGFloat(max(0, settings.marginPercent)) / 100
            * min(extent.width, extent.height)
        guard margin >= 1 else {
            return apply(image, faces: faces, settings: settings)
        }
        let canvas = CGRect(x: 0, y: 0,
                            width: extent.width + margin * 2,
                            height: extent.height + margin * 2)
        let photoRect = CGRect(x: margin, y: margin,
                               width: extent.width, height: extent.height)

        let bleed = image
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: margin * 0.42])
            .cropped(to: canvas)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: -0.05,
                kCIInputSaturationKey: 0.82
            ])

        let photo = image.cropped(to: extent)
            .transformed(by: CGAffineTransform(translationX: margin, y: margin))
        let composed = photo.composited(over: bleed).cropped(to: canvas)

        guard settings.isEnabled,
              let overlay = render(size: canvas.size, faces: faces,
                                   settings: settings, photoRect: photoRect)
        else { return composed }
        return CIImage(cgImage: overlay)
            .composited(over: composed)
            .cropped(to: canvas)
    }

    // MARK: - Geometry shared with the canvas handles

    /// Where each leader's dot sits, before the owner drags it.
    static func defaultEnds(face: FaceGeometry,
                            regions: Set<AnalysisRegion>) -> [AnalysisRegion: CGPoint] {
        var buckets: [Bool: [(region: AnalysisRegion, y: CGFloat)]] = [:]
        for region in regions {
            let anchor = anchor(region, face: face)
            buckets[region.defaultsToRight, default: []].append((region, anchor.y))
        }

        var result: [AnalysisRegion: CGPoint] = [:]
        for (right, items) in buckets {
            let faceHeight = face.boundingBox.height
            // Labels sit beside the face, not at the frame edge: a line that
            // crosses the whole picture reads as a scratch.
            let gap = max(0.050, min(0.078, faceHeight * 1.05 / CGFloat(max(1, items.count))))
            let sorted = items.sorted { $0.y < $1.y }
            var ys = sorted.map { min(0.945, max(0.055, $0.y)) }
            for index in 1..<ys.count where ys[index] < ys[index - 1] + gap {
                ys[index] = ys[index - 1] + gap
            }
            if let last = ys.last, last > 0.945 {
                let overflow = last - 0.945
                for index in ys.indices { ys[index] -= overflow }
            }
            for index in stride(from: ys.count - 2, through: 0, by: -1)
            where ys[index] > ys[index + 1] - gap {
                ys[index] = ys[index + 1] - gap
            }
            if let first = ys.first, first < 0.055 {
                let under = 0.055 - first
                for index in ys.indices { ys[index] += under }
            }
            let x = right
                ? min(0.965, face.boundingBox.maxX + face.boundingBox.width * 0.58)
                : max(0.035, face.boundingBox.minX - face.boundingBox.width * 0.58)
            for (index, item) in sorted.enumerated() {
                result[item.region] = CGPoint(x: x, y: ys[index])
            }
        }
        return result
    }

    /// Every leader end in force for this face: the owner's pin when there is
    /// one, the automatic layout otherwise.
    static func layout(face: FaceGeometry,
                       settings: AnalysisSettings) -> [AnalysisRegion: CGPoint] {
        var result = defaultEnds(face: face, regions: settings.regions)
        for region in settings.regions {
            if let pinned = settings.endpoint(for: region) { result[region] = pinned }
        }
        return result
    }

    static func anchor(_ region: AnalysisRegion, face: FaceGeometry) -> CGPoint {
        let box = face.boundingBox
        let eyes = face.eyePolygons.sorted {
            FaceGeometry.boundingBox(of: $0).midX < FaceGeometry.boundingBox(of: $1).midX
        }
        // Central features take their dot on the side the leader runs to, so the
        // line leaves the feature instead of cutting across the face.
        let side: CGFloat = region.defaultsToRight ? 1 : -1

        switch region {
        case .forehead:
            return CGPoint(x: box.midX + side * box.width * 0.17,
                           y: box.minY + box.height * 0.855)
        case .eyeArea:
            // The dot sits on the outer corner of the eye on the side the
            // leader runs to; using the other eye would draw the line straight
            // across the face.
            let eye = region.defaultsToRight ? eyes.last : eyes.first
            if let eye {
                let r = FaceGeometry.boundingBox(of: eye)
                return CGPoint(x: region.defaultsToRight ? r.maxX : r.minX, y: r.midY)
            }
            return CGPoint(x: box.minX + box.width * 0.28, y: box.minY + box.height * 0.58)
        case .underEye:
            let eye = region.defaultsToRight ? eyes.last : eyes.first
            if let eye {
                let r = FaceGeometry.boundingBox(of: eye)
                return CGPoint(x: r.midX, y: r.minY - box.height * 0.028)
            }
            return CGPoint(x: box.minX + box.width * 0.30, y: box.minY + box.height * 0.48)
        case .brows:
            let brows = face.eyebrowPolygons.sorted {
                FaceGeometry.boundingBox(of: $0).midX < FaceGeometry.boundingBox(of: $1).midX
            }
            if let brow = FaceGeometry.centroid(of: brows.first ?? []) { return brow }
            return CGPoint(x: box.midX, y: box.minY + box.height * 0.70)
        case .texture:
            return cheekCenter(face: face, right: false)
        case .pigmentation:
            let center = cheekCenter(face: face, right: true)
            return CGPoint(x: center.x, y: center.y + box.height * 0.02)
        case .jawline:
            let contour = face.faceContour
            guard contour.count >= 5 else {
                return CGPoint(x: box.minX + box.width * 0.14, y: box.minY + box.height * 0.16)
            }
            // Vision starts the contour at one ear and ends at the other, so
            // the same fraction of the list gives either side.
            let offset = Int(Double(contour.count) * 0.20)
            let index = region.defaultsToRight ? offset : contour.count - 1 - offset
            return contour[max(0, min(contour.count - 1, index))]
        case .lips:
            let center = FaceGeometry.centroid(of: face.lipPolygon)
                ?? CGPoint(x: box.midX, y: box.minY + box.height * 0.32)
            return CGPoint(x: center.x + side * box.width * 0.16, y: center.y)
        case .nose:
            let points = face.nose.isEmpty ? face.noseCrest : face.nose
            let nose = FaceGeometry.boundingBox(of: points)
            guard nose.width > 0 else {
                return CGPoint(x: box.midX, y: box.minY + box.height * 0.45)
            }
            return CGPoint(x: nose.midX + side * nose.width * 0.42,
                           y: nose.minY + nose.height * 0.12)
        case .chin:
            return CGPoint(x: box.midX + side * box.width * 0.11,
                           y: box.minY + box.height * 0.055)
        }
    }

    /// The cheekbone, read from the face box rather than the skin-mask cheek
    /// rect: that one is sized to cover skin and lands on the eye on a narrow
    /// face, which put the callout circle over the eye.
    static func cheekCenter(face: FaceGeometry, right: Bool) -> CGPoint {
        let box = face.boundingBox
        return CGPoint(x: box.minX + box.width * (right ? 0.83 : 0.17),
                       y: box.minY + box.height * 0.36)
    }

    // MARK: - Metrics

    fileprivate struct Metrics {
        let photo: CGRect
        let canvas: CGSize
        /// The owner's thickness choice, applied to both the line and the dot
        /// so a heavier line never ends in a needle-thin point.
        let weight: CGFloat

        var shortSide: CGFloat { min(photo.width, photo.height) }
        var line: CGFloat { max(1.1, shortSide * 0.0022) * weight }
        var dot: CGFloat { max(1.6, shortSide * 0.0034) * weight }
        var dash: [CGFloat] { [line * 5.2, line * 4.2] }

        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: photo.minX + p.x * photo.width,
                    y: photo.minY + p.y * photo.height)
        }

        func rect(_ r: CGRect) -> CGRect {
            CGRect(x: photo.minX + r.minX * photo.width,
                   y: photo.minY + r.minY * photo.height,
                   width: r.width * photo.width,
                   height: r.height * photo.height)
        }

        func radius(_ fraction: CGFloat) -> CGFloat { fraction * shortSide }
    }

    // MARK: - Mesh

    /// Vision hands over about 76 points, all of them on the jaw, eyes, brows,
    /// lips and nose; nothing above the brow. The forehead rows below are added
    /// so the web can reach the hairline instead of stopping mid-face.
    static func meshPoints(for face: FaceGeometry) -> [CGPoint] {
        var points: [CGPoint] = []
        points += face.faceContour
        points += face.leftEye + face.rightEye
        points += face.leftPupil + face.rightPupil
        points += face.leftEyebrow + face.rightEyebrow
        points += face.outerLips + face.innerLips
        points += face.nose + face.noseCrest + face.medianLine

        let box = face.boundingBox
        func add(_ x: CGFloat, _ y: CGFloat) {
            points.append(CGPoint(x: box.minX + box.width * x,
                                  y: box.minY + box.height * y))
        }
        // Forehead: three rows thinning toward the hairline.
        for x in [0.24, 0.5, 0.76] { add(x, 0.755) }
        for x in [0.30, 0.5, 0.70] { add(x, 0.835) }
        for x in [0.38, 0.5, 0.62] { add(x, 0.905) }
        add(0.15, 0.700); add(0.85, 0.700)
        add(0.11, 0.620); add(0.89, 0.620)
        // Cheeks and jaw, bridging the eye line to the contour.
        add(0.17, 0.540); add(0.83, 0.540)
        add(0.17, 0.470); add(0.83, 0.470)
        add(0.13, 0.360); add(0.87, 0.360)
        add(0.24, 0.290); add(0.76, 0.290)
        add(0.19, 0.220); add(0.81, 0.220)
        add(0.50, 0.180)
        add(0.50, 0.560)

        var unique: [CGPoint] = []
        for point in points {
            let duplicate = unique.contains {
                abs($0.x - point.x) < 0.004 && abs($0.y - point.y) < 0.004
            }
            if !duplicate { unique.append(point) }
        }
        return unique
    }

    private static func drawMesh(in ctx: CGContext, face: FaceGeometry,
                                 m: Metrics, settings: AnalysisSettings) {
        let points = meshPoints(for: face)
        guard points.count >= 3 else { return }
        let tris = triangulate(points.map { CGPoint(x: $0.x * 1000, y: $0.y * 1000) })
        guard !tris.isEmpty else { return }

        let center = CGPoint(x: face.boundingBox.midX, y: face.boundingBox.midY)
        let reach = max(face.boundingBox.width, face.boundingBox.height) * 0.82
        let opacity = CGFloat(settings.lineOpacity)

        // The fade is per triangle, so the passes are drawn one triangle at a
        // time; batching them would flatten the gradient the reference has.
        for tri in tris {
            let a = points[tri.0], b = points[tri.1], c = points[tri.2]
            let centroid = CGPoint(x: (a.x + b.x + c.x) / 3,
                                   y: (a.y + b.y + c.y) / 3)
            let distance = hypot(centroid.x - center.x, centroid.y - center.y)
            let fade = max(0.20, 1 - 0.86 * min(1, distance / reach))
            let path = CGMutablePath()
            path.addLines(between: [m.point(a), m.point(b), m.point(c)])
            path.closeSubpath()

            ctx.saveGState()
            ctx.addPath(path)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(m.line * 4.6)
            ctx.setStrokeColor(rim(settings, 0.075 * opacity * fade))
            ctx.strokePath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(path)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(m.line * 0.8)
            ctx.setStrokeColor(rim(settings, 0.20 * opacity * fade))
            ctx.strokePath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(path)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(m.line * 0.58)
            ctx.setStrokeColor(ink(settings, 0.52 * opacity * fade))
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Vertices: a wide soft halo, then the bright point.
        for point in points {
            let distance = hypot(point.x - center.x, point.y - center.y)
            let fade = max(0.28, 1 - 0.72 * min(1, distance / reach))
            let p = m.point(point)
            ctx.saveGState()
            ctx.setFillColor(ink(settings, 0.10 * opacity * fade))
            let halo = m.dot * 4.4
            ctx.fillEllipse(in: CGRect(x: p.x - halo, y: p.y - halo,
                                       width: halo * 2, height: halo * 2))
            ctx.setFillColor(ink(settings, 0.95 * opacity * fade))
            let r = m.dot * 0.72
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r,
                                       width: r * 2, height: r * 2))
            ctx.restoreGState()
        }
    }

    // MARK: - Dashed style

    private static func drawFaceOutline(in ctx: CGContext, face: FaceGeometry,
                                        m: Metrics, settings: AnalysisSettings) {
        let contour = face.faceContour
        guard contour.count >= 3 else { return }
        let box = face.boundingBox
        let path = CGMutablePath()
        path.addLines(between: contour.map { m.point($0) })
        if let first = contour.first {
            let end = m.point(first)
            let top = m.point(CGPoint(x: box.midX, y: box.minY + box.height * 1.01))
            // Control points sit on the face box, not on the temple points: the
            // contour stops at the ears, and an arc between those two points
            // would cut the forehead in half.
            path.addCurve(to: end,
                          control1: CGPoint(x: m.point(CGPoint(x: box.maxX, y: 0)).x, y: top.y),
                          control2: CGPoint(x: m.point(CGPoint(x: box.minX, y: 0)).x, y: top.y))
            path.closeSubpath()
        }
        stroke(ctx, path, m: m, settings: settings,
               width: m.line * 0.8, alpha: 0.55, dash: m.dash)
    }

    private static func drawContour(in ctx: CGContext, region: AnalysisRegion,
                                    face: FaceGeometry, m: Metrics,
                                    settings: AnalysisSettings) {
        let box = face.boundingBox
        let eyes = face.eyePolygons.sorted {
            FaceGeometry.boundingBox(of: $0).midX < FaceGeometry.boundingBox(of: $1).midX
        }
        let width = m.line * 0.95
        let dash = m.dash

        switch region {
        case .forehead:
            let rect = CGRect(x: box.minX + box.width * 0.19,
                              y: box.minY + box.height * 0.765,
                              width: box.width * 0.62,
                              height: box.height * 0.185)
            stroke(ctx, CGPath(ellipseIn: m.rect(rect), transform: nil),
                   m: m, settings: settings, width: width, alpha: 0.80, dash: dash)

        case .eyeArea:
            // One ring around the eye the callout points at; a ring around both
            // read as spectacles.
            let eye = eyes.last ?? eyes.first
            if let eye {
                let r = FaceGeometry.boundingBox(of: eye)
                let grown = CGRect(x: r.minX - r.width * 0.18,
                                   y: r.minY - r.height * 0.34,
                                   width: r.width * 1.36,
                                   height: r.height * 1.62)
                stroke(ctx, CGPath(ellipseIn: m.rect(grown), transform: nil),
                       m: m, settings: settings, width: width, alpha: 0.85, dash: dash)
            }

        case .underEye:
            for eye in eyes {
                let r = FaceGeometry.boundingBox(of: eye)
                let path = CGMutablePath()
                let from = CGPoint(x: r.minX + r.width * 0.10,
                                   y: r.minY - r.height * 0.20)
                let to = CGPoint(x: r.maxX - r.width * 0.10,
                                 y: r.minY - r.height * 0.20)
                let control = CGPoint(x: r.midX, y: r.minY - r.height * 1.25)
                path.move(to: m.point(from))
                path.addQuadCurve(to: m.point(to), control: m.point(control))
                stroke(ctx, path, m: m, settings: settings,
                       width: width, alpha: 0.85, dash: dash)
            }

        case .brows:
            for brow in face.eyebrowPolygons {
                guard brow.count >= 2 else { continue }
                let path = CGMutablePath()
                path.addLines(between: brow.map { m.point($0) })
                stroke(ctx, path, m: m, settings: settings,
                       width: width * 1.1, alpha: 0.85, dash: dash)
            }

        case .texture:
            let radius = box.width * 0.105
            for right in [false, true] {
                let center = cheekCenter(face: face, right: right)
                let rect = CGRect(x: center.x - radius, y: center.y - radius,
                                  width: radius * 2, height: radius * 2)
                stroke(ctx, CGPath(ellipseIn: m.rect(rect), transform: nil),
                       m: m, settings: settings, width: width, alpha: 0.85, dash: dash)
            }

        case .pigmentation:
            let radius = box.width * 0.068
            for right in [false, true] {
                let center = cheekCenter(face: face, right: right)
                let lifted = CGPoint(x: center.x, y: center.y + box.height * 0.055)
                let rect = CGRect(x: lifted.x - radius, y: lifted.y - radius * 0.78,
                                  width: radius * 2, height: radius * 1.56)
                stroke(ctx, CGPath(ellipseIn: m.rect(rect), transform: nil),
                       m: m, settings: settings, width: width, alpha: 0.85, dash: dash)
            }

        case .jawline:
            let contour = face.faceContour
            guard contour.count >= 6 else { return }
            let lower = Int(Double(contour.count) * 0.08)
            let upper = Int(Double(contour.count) * 0.40)
            let slice = Array(contour[lower..<min(upper, contour.count)])
            guard slice.count >= 2 else { return }
            let path = CGMutablePath()
            path.addLines(between: slice.map { m.point($0) })
            stroke(ctx, path, m: m, settings: settings,
                   width: width * 1.05, alpha: 0.85, dash: dash)

        case .lips:
            let lips = face.lipPolygon
            guard lips.count >= 3 else { return }
            let path = CGMutablePath()
            path.addLines(between: lips.map { m.point($0) })
            path.closeSubpath()
            stroke(ctx, path, m: m, settings: settings,
                   width: width, alpha: 0.85, dash: dash)

        case .nose:
            let points = face.nose.isEmpty ? face.noseCrest : face.nose
            let nose = FaceGeometry.boundingBox(of: points)
            guard nose.width > 0 else { return }
            let apex = CGPoint(x: nose.midX, y: nose.maxY - nose.height * 0.05)
            let left = CGPoint(x: nose.minX - nose.width * 0.10,
                               y: nose.minY + nose.height * 0.08)
            let right = CGPoint(x: nose.maxX + nose.width * 0.10,
                                y: nose.minY + nose.height * 0.08)
            let path = CGMutablePath()
            path.addLines(between: [m.point(apex), m.point(left),
                                    m.point(right), m.point(apex)])
            stroke(ctx, path, m: m, settings: settings,
                   width: width, alpha: 0.85, dash: dash)

        case .chin:
            let rect = CGRect(x: box.midX - box.width * 0.17,
                              y: box.minY + box.height * 0.015,
                              width: box.width * 0.34,
                              height: box.height * 0.10)
            stroke(ctx, CGPath(ellipseIn: m.rect(rect), transform: nil),
                   m: m, settings: settings, width: width, alpha: 0.85, dash: dash)
        }
    }

    // MARK: - Callouts

    private static func drawCallouts(in ctx: CGContext, face: FaceGeometry,
                                     m: Metrics, settings: AnalysisSettings, poster: Bool) {
        let ends = layout(face: face, settings: settings)
        let margin = poster ? (m.canvas.height - m.photo.height) / 2 : 0

        for region in settings.primaryCallouts {
            guard let end = ends[region] else { continue }
            let placed = settings.anchor(for: region) ?? AnalysisRenderer.anchor(region, face: face)
            let anchor = m.point(placed)
            var tip = m.point(end)
            if poster {
                tip = extend(anchor: anchor, through: tip, photo: m.photo,
                             margin: margin, canvas: m.canvas)
            }

            let path = CGMutablePath()
            path.move(to: anchor)
            path.addLine(to: tip)
            stroke(ctx, path, m: m, settings: settings,
                   width: m.line * 0.72, alpha: 0.80)

            // The little end dot marks where the text will sit without drawing
            // any text of its own.
            let opacity = CGFloat(settings.lineOpacity)
            let endRadius = m.dot * 0.62
            ctx.saveGState()
            ctx.setStrokeColor(ink(settings, 0.75 * opacity))
            ctx.setLineWidth(m.line * 0.65)
            ctx.strokeEllipse(in: CGRect(x: tip.x - endRadius, y: tip.y - endRadius,
                                         width: endRadius * 2, height: endRadius * 2))
            ctx.restoreGState()

            dot(ctx, at: anchor, m: m, settings: settings)
        }
    }

    /// Continuation of a leader line into the blank band of a poster export.
    private static func extend(anchor: CGPoint, through tip: CGPoint,
                               photo: CGRect, margin: CGFloat,
                               canvas: CGSize) -> CGPoint {
        let dx = tip.x - anchor.x
        let dy = tip.y - anchor.y
        let length = hypot(dx, dy)
        guard length > 0.001, margin > 0 else { return tip }
        let dir = CGPoint(x: dx / length, y: dy / length)

        // Distance from the anchor to where the ray leaves the photo.
        var exit = CGFloat.greatestFiniteMagnitude
        if dir.x > 0 { exit = min(exit, (photo.maxX - anchor.x) / dir.x) }
        if dir.x < 0 { exit = min(exit, (photo.minX - anchor.x) / dir.x) }
        if dir.y > 0 { exit = min(exit, (photo.maxY - anchor.y) / dir.y) }
        if dir.y < 0 { exit = min(exit, (photo.minY - anchor.y) / dir.y) }
        guard exit.isFinite else { return tip }

        let reach = exit + margin * 0.58
        let point = CGPoint(x: anchor.x + dir.x * reach,
                            y: anchor.y + dir.y * reach)
        let inset: CGFloat = 6
        return CGPoint(x: min(canvas.width - inset, max(inset, point.x)),
                       y: min(canvas.height - inset, max(inset, point.y)))
    }

    // MARK: - Ink

    /// The chosen colour at the given alpha. The overlay is drawn in device RGB,
    /// so the components go straight in without a colour-space hop.
    fileprivate static func ink(_ settings: AnalysisSettings, _ alpha: CGFloat) -> CGColor {
        let c = settings.tint.rgb
        return CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha)
    }

    /// The rim sits behind the ink, in the opposite value: a pale hairline alone
    /// disappears on a bright wall, and the dark ink disappears on hair.
    fileprivate static func rim(_ settings: AnalysisSettings, _ alpha: CGFloat) -> CGColor {
        CGColor(gray: settings.tint.isDark ? 1 : 0, alpha: alpha)
    }

    // MARK: - Strokes

    private static func stroke(_ ctx: CGContext, _ path: CGPath, m: Metrics,
                               settings: AnalysisSettings, width: CGFloat,
                               alpha: CGFloat, dash: [CGFloat]? = nil) {
        let opacity = CGFloat(settings.lineOpacity) * alpha
        let rimAlpha = (settings.tint.isDark ? 0.55 : 0.22) * opacity

        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if let dash { ctx.setLineDash(phase: 0, lengths: dash) }
        ctx.setLineWidth(width * 2.4)
        ctx.setStrokeColor(rim(settings, rimAlpha))
        ctx.strokePath()
        ctx.restoreGState()

        ctx.saveGState()
        if settings.glow {
            // The glow follows the ink, except for the dark one: a black halo
            // reads as smudge, so it borrows the pale rim instead.
            let glow = settings.tint.isDark ? rim(settings, 0.55 * opacity)
                                            : ink(settings, 0.50 * opacity)
            ctx.setShadow(offset: .zero, blur: m.line * 4.2, color: glow)
        }
        ctx.addPath(path)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if let dash { ctx.setLineDash(phase: 0, lengths: dash) }
        ctx.setLineWidth(width)
        ctx.setStrokeColor(ink(settings, opacity))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func dot(_ ctx: CGContext, at p: CGPoint, m: Metrics,
                            settings: AnalysisSettings) {
        let opacity = CGFloat(settings.lineOpacity)
        let radius = m.dot
        ctx.saveGState()
        ctx.setFillColor(rim(settings, 0.30 * opacity))
        ctx.fillEllipse(in: CGRect(x: p.x - radius * 1.9, y: p.y - radius * 1.9,
                                   width: radius * 3.8, height: radius * 3.8))
        ctx.restoreGState()

        ctx.saveGState()
        if settings.glow {
            let glow = settings.tint.isDark ? rim(settings, 0.60 * opacity)
                                            : ink(settings, 0.85 * opacity)
            ctx.setShadow(offset: .zero, blur: radius * 2.6, color: glow)
        }
        ctx.setFillColor(ink(settings, opacity))
        ctx.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius,
                                   width: radius * 2, height: radius * 2))
        ctx.restoreGState()
    }

    // MARK: - Triangulation

    /// Bowyer–Watson. The point count is about a hundred, so a straightforward
    /// implementation is fast enough to run on every preview render.
    private static func triangulate(_ points: [CGPoint]) -> [(Int, Int, Int)] {
        let count = points.count
        guard count >= 3 else { return [] }

        var minX = points[0].x, maxX = points[0].x
        var minY = points[0].y, maxY = points[0].y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let delta = max(maxX - minX, maxY - minY) * 10 + 1
        let midX = (minX + maxX) / 2
        let midY = (minY + maxY) / 2

        var all = points
        all.append(CGPoint(x: midX - 2 * delta, y: midY - delta))
        all.append(CGPoint(x: midX, y: midY + 2 * delta))
        all.append(CGPoint(x: midX + 2 * delta, y: midY - delta))

        var triangles: [(Int, Int, Int)] = [(count, count + 1, count + 2)]

        for index in 0..<count {
            let p = all[index]
            var edges: [(Int, Int)] = []
            var kept: [(Int, Int, Int)] = []

            for tri in triangles {
                if inCircumcircle(p, all[tri.0], all[tri.1], all[tri.2]) {
                    edges.append((tri.0, tri.1))
                    edges.append((tri.1, tri.2))
                    edges.append((tri.2, tri.0))
                } else {
                    kept.append(tri)
                }
            }

            var counts: [Int64: Int] = [:]
            for edge in edges {
                let a = min(edge.0, edge.1)
                let b = max(edge.0, edge.1)
                counts[Int64(a) << 32 | Int64(b), default: 0] += 1
            }
            for edge in edges {
                let a = min(edge.0, edge.1)
                let b = max(edge.0, edge.1)
                if counts[Int64(a) << 32 | Int64(b)] == 1 {
                    kept.append((edge.0, edge.1, index))
                }
            }
            triangles = kept
        }

        return triangles.filter { $0.0 < count && $0.1 < count && $0.2 < count }
    }

    private static func inCircumcircle(_ p: CGPoint, _ a: CGPoint,
                                       _ b: CGPoint, _ c: CGPoint) -> Bool {
        let ax = a.x - p.x, ay = a.y - p.y
        let bx = b.x - p.x, by = b.y - p.y
        let cx = c.x - p.x, cy = c.y - p.y
        let det = (ax * ax + ay * ay) * (bx * cy - cx * by)
            - (bx * bx + by * by) * (ax * cy - cx * ay)
            + (cx * cx + cy * cy) * (ax * by - bx * ay)
        let orientation = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        return orientation > 0 ? det > 0 : det < 0
    }
}

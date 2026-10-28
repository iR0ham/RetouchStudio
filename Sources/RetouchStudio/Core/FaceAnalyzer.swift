import CoreGraphics
import Foundation
import Vision

/// Face geometry from Vision, in normalized image coordinates (0...1) with the
/// origin at the BOTTOM-LEFT, matching Core Graphics and Core Image.
///
/// The previous version only carried face/eye/brow/lip outlines, which made
/// feature-accurate editing impossible: there was no nose, no pupils, no
/// teeth region, and no derived cheek/jaw/chin/under-eye areas. Everything the
/// reshape and skin engines need is computed here once.
struct FaceGeometry {

    var boundingBox: CGRect

    // Raw landmark outlines (absolute, normalized to the whole image).
    var faceContour: [CGPoint]
    var leftEye: [CGPoint]
    var rightEye: [CGPoint]
    var leftPupil: [CGPoint]
    var rightPupil: [CGPoint]
    var leftEyebrow: [CGPoint]
    var rightEyebrow: [CGPoint]
    var outerLips: [CGPoint]
    var innerLips: [CGPoint]
    var nose: [CGPoint]
    var noseCrest: [CGPoint]
    var medianLine: [CGPoint]
    var hasLandmarks: Bool

    /// True when the inner-mouth region actually shows teeth. Geometry alone
    /// cannot decide this: a closed smile and an open smile can have the same
    /// lip opening, so the flag is set from pixels by `AutoAnalyzer`.
    var hasVisibleTeeth: Bool = false

    /// Luminance that separates sclera from iris inside the eye opening. Also
    /// measured from pixels: a fixed threshold fails on darker skin tones,
    /// where sclera is still the brightest part of the eye but nowhere near
    /// white. The default stays usable when eyes were not annotated.
    var eyeScleraLuminance: Double = 0.55

    // MARK: - Derived regions

    var eyePolygons: [[CGPoint]] { [leftEye, rightEye].filter { $0.count >= 3 } }
    var eyebrowPolygons: [[CGPoint]] { [leftEyebrow, rightEyebrow].filter { $0.count >= 3 } }

    var eyeRects: [CGRect] { eyePolygons.map { Self.boundingBox(of: $0) } }
    var leftEyeRect: CGRect { Self.boundingBox(of: leftEye) }
    var rightEyeRect: CGRect { Self.boundingBox(of: rightEye) }

    var noseRect: CGRect { Self.boundingBox(of: nose.isEmpty ? noseCrest : nose) }
    var noseCrestRect: CGRect { Self.boundingBox(of: noseCrest) }

    /// Lips outline used for editing (outer lips give the true mouth extent).
    var lipPolygon: [CGPoint] { outerLips.count >= 3 ? outerLips : innerLips }
    var lipRect: CGRect? {
        let r = Self.boundingBox(of: lipPolygon)
        return r.isNull ? nil : r
    }
    var innerLipRect: CGRect? {
        let r = Self.boundingBox(of: innerLips)
        return r.isNull ? nil : r
    }
    var innerLipPolygon: [CGPoint] { innerLips }

    /// Teeth sit inside the inner mouth. Vision's innerLips traces the mouth
    /// opening, so the middle of it is where the teeth are. Used for the
    /// visibility measurement, where a tight region keeps lips out of the
    /// bright/low-saturation count.
    var teethRect: CGRect? {
        guard !innerLips.isEmpty else { return nil }
        let r = Self.boundingBox(of: innerLips)
        guard !r.isNull else { return nil }
        // Inset vertically to stay inside the lips.
        return r.insetBy(dx: r.width * 0.12, dy: r.height * 0.18)
    }

    /// Region handed to the enamel mask. Vision's inner-lip outline stops
    /// short of the smile corners: measured on the fixtures it spans about
    /// 42% of the outer-lip width, so a mask seeded from it whitens only a
    /// patch of the teeth. The outer lips cover the whole opening; the pixel
    /// gate trims that back down to enamel.
    var enamelRect: CGRect? {
        guard let r = lipRect, r.width > 0, r.height > 0 else { return teethRect }
        return r.insetBy(dx: r.width * 0.08, dy: r.height * 0.10)
    }

    /// Inner-lip height over outer-lip height. Used together with a pixel
    /// measurement to decide whether teeth are actually visible.
    var mouthOpenness: Double {
        guard let inner = innerLipRect, let outer = lipRect, outer.height > 0.0001 else { return 0 }
        return Double(inner.height / outer.height)
    }

    /// Forehead: the upper part of the face contour, used for skin work.
    var foreheadRect: CGRect {
        let box = boundingBox
        return CGRect(x: box.minX + box.width * 0.18,
                      y: box.minY + box.height * 0.76,
                      width: box.width * 0.64,
                      height: box.height * 0.20)
    }

    /// Forehead plus cheeks as one rounded band, used when building the
    /// silhouette mask.
    var upperFaceRectForMask: CGRect {
        let box = boundingBox
        return CGRect(x: box.minX + box.width * 0.10,
                      y: box.minY + box.height * 0.40,
                      width: box.width * 0.80,
                      height: box.height * 0.52)
    }

    /// Cheeks: below the eyes, outside the nose, above the jaw.
    var leftCheekRect: CGRect { cheekRect(isLeft: true) }
    var rightCheekRect: CGRect { cheekRect(isLeft: false) }

    private func cheekRect(isLeft: Bool) -> CGRect {
        let box = boundingBox
        let eye = isLeft ? leftEyeRect : rightEyeRect
        let noseBox = noseRect
        let width = box.width * 0.26
        let height = box.height * 0.24
        // Place the cheek below the eye's bottom and to the outside.
        let y = max(box.minY + box.height * 0.16, eye.minY - height * 1.05)
        if isLeft {
            let x = max(box.minX + box.width * 0.10, eye.minX - width * 0.20)
            _ = noseBox
            return CGRect(x: x, y: y, width: width, height: height)
        } else {
            let x = min(box.maxX - box.width * 0.10 - width, eye.maxX - width * 0.80)
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }

    /// Where blush goes. The cheek rects above are sized for skin work and sit
    /// low; a flush belongs on the top of the cheekbone, toward the temple, so
    /// it is lifted and tightened. Coordinates are bottom-left origin, so a
    /// larger y means higher on the face.
    var leftBlushRect: CGRect { blushRect(isLeft: true) }
    var rightBlushRect: CGRect { blushRect(isLeft: false) }

    private func blushRect(isLeft: Bool) -> CGRect {
        let cheek = isLeft ? leftCheekRect : rightCheekRect
        let width = cheek.width * 0.90
        let height = cheek.height * 0.80
        // Keeping the outer edge and shortening the inner one pulls the colour
        // away from the nose, which is where a blush band must not start.
        let x = isLeft ? cheek.minX : cheek.maxX - width
        let y = cheek.midY - height * 0.30
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Jawline: the lower quarter of the face contour, left and right of the chin.
    var jawRects: (left: CGRect, right: CGRect) {
        let box = boundingBox
        let bandY = box.minY + box.height * 0.10
        let bandH = box.height * 0.20
        let bandW = box.width * 0.22
        let left = CGRect(x: box.minX + box.width * 0.06, y: bandY, width: bandW, height: bandH)
        let right = CGRect(x: box.maxX - box.width * 0.06 - bandW, y: bandY, width: bandW, height: bandH)
        return (left, right)
    }

    /// Chin: the bottom centre of the face.
    var chinRect: CGRect {
        let box = boundingBox
        return CGRect(x: box.midX - box.width * 0.17,
                      y: box.minY + box.height * 0.02,
                      width: box.width * 0.34,
                      height: box.height * 0.17)
    }

    /// Under-eye (tear trough) bands for dark-circle correction.
    var leftUnderEyeRect: CGRect { underEyeRect(isLeft: true) }
    var rightUnderEyeRect: CGRect { underEyeRect(isLeft: false) }

    private func underEyeRect(isLeft: Bool) -> CGRect {
        let eye = isLeft ? leftEyeRect : rightEyeRect
        let box = boundingBox
        let h = box.height * 0.085
        // Start just below the eye and extend downward.
        let y = max(box.minY + box.height * 0.05, eye.minY - h)
        let w = eye.width * 1.35
        let x = eye.midX - w / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Half of the face (left = viewer's left), for whole-face reshaping.
    var leftHalfRect: CGRect {
        let box = boundingBox
        return CGRect(x: box.minX, y: box.minY, width: box.width / 2, height: box.height)
    }
    var rightHalfRect: CGRect {
        let box = boundingBox
        return CGRect(x: box.midX, y: box.minY, width: box.width / 2, height: box.height)
    }

    // MARK: - Helpers

    static func boundingBox(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func centroid(of points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    /// Scales an outline about its own centre.
    static func scaled(_ points: [CGPoint], by factor: CGFloat) -> [CGPoint] {
        guard !points.isEmpty else { return points }
        let box = boundingBox(of: points)
        let center = CGPoint(x: box.midX, y: box.midY)
        return points.map {
            CGPoint(x: center.x + ($0.x - center.x) * factor,
                    y: center.y + ($0.y - center.y) * factor)
        }
    }

    var eyeCenters: (left: CGPoint?, right: CGPoint?) {
        (Self.centroid(of: leftEye.isEmpty ? leftPupil : leftEye),
         Self.centroid(of: rightEye.isEmpty ? rightPupil : rightEye))
    }

    /// Builds a face from just the regions a test cares about; everything else
    /// is left empty and the derived rects fall back to the bounding box.
    /// Exists so fixtures read as intent rather than a 13-argument call.
    static func synthetic(boundingBox: CGRect,
                          faceContour: [CGPoint] = [],
                          leftEye: [CGPoint] = [],
                          rightEye: [CGPoint] = [],
                          leftEyebrow: [CGPoint] = [],
                          rightEyebrow: [CGPoint] = [],
                          outerLips: [CGPoint] = [],
                          innerLips: [CGPoint] = [],
                          nose: [CGPoint] = []) -> FaceGeometry {
        FaceGeometry(boundingBox: boundingBox,
                     faceContour: faceContour,
                     leftEye: leftEye,
                     rightEye: rightEye,
                     leftPupil: [],
                     rightPupil: [],
                     leftEyebrow: leftEyebrow,
                     rightEyebrow: rightEyebrow,
                     outerLips: outerLips,
                     innerLips: innerLips,
                     nose: nose,
                     noseCrest: [],
                     medianLine: [],
                     hasLandmarks: true)
    }
}

enum FaceAnalyzer {

    /// Detects faces in an image that has already been oriented upright.
    static func analyze(_ image: CGImage) -> [FaceGeometry] {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let results = request.results else { return [] }
        return results.compactMap { geometry(from: $0) }
    }

    private static func geometry(from observation: VNFaceObservation) -> FaceGeometry {
        let box = observation.boundingBox
        let landmarks = observation.landmarks

        /// Vision reports landmark points relative to the face box; convert to
        /// absolute normalized image coordinates.
        func absolute(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            guard let region, region.pointCount > 0 else { return [] }
            return region.normalizedPoints.map { point in
                CGPoint(x: box.minX + point.x * box.width,
                        y: box.minY + point.y * box.height)
            }
        }

        var contour = absolute(landmarks?.faceContour)
        if contour.count < 3 {
            contour = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                       CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        }

        // Grow the eye outlines slightly so the mask covers lashes and lid.
        let leftEye = FaceGeometry.scaled(absolute(landmarks?.leftEye), by: 1.22)
        let rightEye = FaceGeometry.scaled(absolute(landmarks?.rightEye), by: 1.22)

        return FaceGeometry(boundingBox: box,
                            faceContour: contour,
                            leftEye: leftEye,
                            rightEye: rightEye,
                            leftPupil: absolute(landmarks?.leftPupil),
                            rightPupil: absolute(landmarks?.rightPupil),
                            leftEyebrow: absolute(landmarks?.leftEyebrow),
                            rightEyebrow: absolute(landmarks?.rightEyebrow),
                            outerLips: absolute(landmarks?.outerLips),
                            innerLips: absolute(landmarks?.innerLips),
                            nose: absolute(landmarks?.nose),
                            noseCrest: absolute(landmarks?.noseCrest),
                            medianLine: absolute(landmarks?.medianLine),
                            hasLandmarks: landmarks != nil)
    }
}

import CoreGraphics
import Foundation
import StudioCore

/// In-memory identity for detected faces.
///
/// A document stores the chosen face as an index into the largest-first list,
/// and an index names a slot, not a person: after a crop removes or reorders
/// faces the same index can land on somebody else. Every detection therefore
/// receives an identity here, and the selection follows that identity through
/// re-detection.
///
/// All of this is runtime state. `FaceGeometry` is never encoded, so nothing
/// in this file reaches the project file, the wire or the C ABI.
struct FaceIdentityTracker {
    /// Boxes that overlap at least this much are the same person.
    static let matchThreshold: CGFloat = 0.5

    private(set) var nextIdentity = 1
    /// Last box seen for every identity, including faces that are currently
    /// outside the crop. Keeping those is what lets a reset crop restore the
    /// chosen person instead of handing the slot to someone else.
    private var remembered: [Int: CGRect] = [:]

    /// A replacement document starts a fresh identity space.
    mutating func reset() {
        nextIdentity = 1
        remembered.removeAll()
    }

    /// Gives every face an identity, matching new detections to the remembered
    /// ones one-to-one by box overlap. Unmatched detections get fresh
    /// identities; unmatched remembered boxes stay so they can match again.
    ///
    /// Boxes are compared in the original photo's normalized, bottom-left
    /// frame. Both the crop and the orientation change between detections, so
    /// each box is mapped back through them first.
    mutating func assign(to faces: inout [FaceGeometry], crop: CGRect?,
                         orientation: DocumentOrientation,
                         orientedSize: CGSize) {
        let boxes = faces.map {
            Self.originalFrameBox($0.boundingBox, crop: crop,
                                  orientation: orientation, orientedSize: orientedSize)
        }

        var candidates: [(overlap: CGFloat, face: Int, identity: Int)] = []
        for (face, box) in boxes.enumerated() {
            for (identity, old) in remembered {
                let overlap = Self.overlap(box, old)
                if overlap >= Self.matchThreshold {
                    candidates.append((overlap, face, identity))
                }
            }
        }
        // Greedy one-to-one: the strongest pair wins, and neither the face nor
        // the identity can be used twice. The tie-breakers keep the result
        // independent of dictionary order.
        candidates.sort {
            if $0.overlap != $1.overlap { return $0.overlap > $1.overlap }
            if $0.face != $1.face { return $0.face < $1.face }
            return $0.identity < $1.identity
        }
        var matched = [Int?](repeating: nil, count: faces.count)
        var taken = Set<Int>()
        for candidate in candidates {
            guard matched[candidate.face] == nil,
                  !taken.contains(candidate.identity) else { continue }
            matched[candidate.face] = candidate.identity
            taken.insert(candidate.identity)
        }

        for index in faces.indices {
            let identity: Int
            if let existing = matched[index] {
                identity = existing
            } else {
                identity = nextIdentity
                nextIdentity += 1
            }
            faces[index].identity = identity
            remembered[identity] = boxes[index]
        }
    }

    /// A normalized bottom-left face box of the current, cropped frame →
    /// the same face's normalized bottom-left box in the original photo,
    /// before any crop or turn.
    static func originalFrameBox(_ box: CGRect, crop: CGRect?,
                                 orientation: DocumentOrientation,
                                 orientedSize: CGSize) -> CGRect {
        let window = crop.flatMap { CropGeometry.isFull($0) ? nil : $0 }
            ?? CropGeometry.full
        // Bottom-left normalized → top-left normalized inside the crop window.
        var rect = CGRect(x: window.minX + box.minX * window.width,
                          y: window.minY + (1 - box.maxY) * window.height,
                          width: box.width * window.width,
                          height: box.height * window.height)
        if !orientation.isIdentity,
           orientedSize.width >= 1, orientedSize.height >= 1 {
            rect = orientation.inverted.mapRect(rect, base: orientedSize)
        }
        return CGRect(x: rect.minX, y: 1 - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    /// Intersection over union. Disjoint or degenerate boxes overlap by zero.
    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull,
              intersection.width > 0, intersection.height > 0 else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let union = a.width * a.height + b.width * b.height - intersectionArea
        guard union > 0 else { return 0 }
        return intersectionArea / union
    }
}

/// The owner's chosen face, remembered by identity instead of by slot.
///
/// A crop or turn can drop the face or reorder the list; remembering the
/// identity means the selection empties while the person is outside the frame
/// and comes back with them. The project file still stores an index, so this
/// lives in memory only.
struct FaceSelection: Equatable {
    private(set) var identity: Int?

    mutating func choose(_ face: FaceGeometry?) {
        identity = face?.identity
    }

    mutating func clear() {
        identity = nil
    }

    /// The slot the chosen person occupies in the current frame, if any.
    func index(in faces: [FaceGeometry]) -> Int? {
        guard let identity else { return nil }
        return faces.firstIndex { $0.identity == identity }
    }
}

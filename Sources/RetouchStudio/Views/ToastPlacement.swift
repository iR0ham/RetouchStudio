import CoreGraphics

/// The canvas chrome a transient status pill must stay clear of.
struct ToastObstacles: Equatable {
    /// The part of the photo inside the canvas. A soft obstacle: crossing it
    /// hides pixels, but it hides no control.
    var photo: CGRect?
    /// The corner tags of the compare split. Each rect reserves room for the
    /// widest tag the shell can draw, so no localisation can grow past it.
    var beforeLabel: CGRect?
    var afterLabel: CGRect?
    /// The compare divider together with the strip that grabs it.
    var compareHandle: CGRect?
    /// The floating zoom/compare dock at the bottom of the canvas.
    var dock: CGRect?

    var hardRects: [CGRect] {
        [beforeLabel, afterLabel, compareHandle, dock].compactMap { $0 }
    }

    /// Rebuilds the obstacles from the same geometry `CompareCanvas` draws
    /// with. It lives apart from SwiftUI so the placement rules can be
    /// exercised without a window.
    static func compareWorkspace(canvas: CGSize,
                                 photo: CGRect,
                                 compareEnabled: Bool,
                                 comparePosition: Double,
                                 toolOwnsCanvas: Bool,
                                 peeking: Bool,
                                 dock: CGRect?) -> ToastObstacles {
        var result = ToastObstacles(dock: dock)
        guard canvas.width > 0, canvas.height > 0,
              photo.width > 0, photo.height > 0 else { return result }

        let visible = photo.intersection(CGRect(origin: .zero, size: canvas))
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return result }
        result.photo = visible

        // The tags only exist while the split itself is on the stage; with the
        // boundary off-screen one side fills the canvas and the tags go away.
        guard compareEnabled, !toolOwnsCanvas, !peeking else { return result }
        let fraction = min(1, max(0, comparePosition))
        let splitX = photo.minX + photo.width * CGFloat(fraction)
        guard splitX >= 0, splitX <= canvas.width else { return result }

        let inset = ToastPlacement.labelInset
        let reserve = min(ToastPlacement.labelReserveWidth, max(0, visible.width - inset * 2))
        if reserve > 0 {
            result.beforeLabel = CGRect(x: visible.minX + inset,
                                        y: visible.minY + inset,
                                        width: reserve,
                                        height: ToastPlacement.labelHeight)
            result.afterLabel = CGRect(x: visible.maxX - inset - reserve,
                                       y: visible.minY + inset,
                                       width: reserve,
                                       height: ToastPlacement.labelHeight)
        }
        result.compareHandle = CGRect(x: splitX - ToastPlacement.handleWidth / 2,
                                      y: 0,
                                      width: ToastPlacement.handleWidth,
                                      height: canvas.height)
        return result
    }
}

/// Chooses the spot for the status pill on the canvas.
///
/// The old pill was pinned to the top-leading corner, which is exactly where
/// the BEFORE tag sits once the photo reaches the top of the canvas. Instead of
/// one corner, the pill considers a few rows of the canvas (top, under the
/// tags, bottom, above the dock, middle) from both edges and the centre, and
/// takes the first row where it fits clear of every hard obstacle. Keeping the
/// photo out of the pill is a soft preference, so a letterboxed photo parks the
/// pill in the empty band; a photo that fills the canvas still gets a spot that
/// leaves the labels, divider and dock alone.
enum ToastPlacement {
    static let margin: CGFloat = 14
    static let clearance: CGFloat = 6
    /// Below this the message cannot be read; the search then gives up a little
    /// width rather than a label or a control.
    static let minimumWidth: CGFloat = 132
    static let labelInset: CGFloat = 10
    static let labelHeight: CGFloat = 17
    /// "BEFORE"/"AFTER" at the tag font, widened generously for any language.
    static let labelReserveWidth: CGFloat = 96
    static let handleWidth: CGFloat = 28

    /// Preference reduction runs once per child of the view that reads the key,
    /// and every child that does not measure reports the default. Taking the
    /// last value blindly lets such a child erase a real measurement, so the
    /// last non-empty size wins.
    static func mergedMeasurement(_ current: CGSize, _ next: CGSize) -> CGSize {
        next == .zero ? current : next
    }

    static func frame(in canvas: CGSize, toast: CGSize, obstacles: ToastObstacles) -> CGRect {
        guard canvas.width > 0, canvas.height > 0 else { return .zero }

        let inset = min(margin, min(canvas.width, canvas.height) / 2)
        let naturalWidth = min(max(1, toast.width), max(1, canvas.width - inset * 2))
        let height = min(max(1, toast.height), max(1, canvas.height - inset * 2))
        let hard = obstacles.hardRects.map { $0.insetBy(dx: -clearance, dy: -clearance) }
        let floor = min(minimumWidth, naturalWidth)

        if let fitted = search(in: canvas, naturalWidth: naturalWidth, height: height,
                               obstacles: obstacles, hard: hard, minimumWidth: floor,
                               inset: inset) {
            return fitted
        }
        // A canvas too small for a readable pill still must not cover a label:
        // retry with any positive width before falling back to the corner.
        if let squeezed = search(in: canvas, naturalWidth: naturalWidth, height: height,
                                 obstacles: obstacles, hard: hard, minimumWidth: 1,
                                 inset: inset) {
            return squeezed
        }
        return CGRect(x: inset, y: inset, width: naturalWidth, height: height)
    }

    // MARK: - Search

    private enum Edge: CaseIterable {
        case leading, trailing, center
    }

    private struct Candidate {
        var y: CGFloat
        var edge: Edge
        var rank: Int
    }

    private struct Score: Comparable {
        var touchesPhoto: Bool
        var shrink: CGFloat
        var photoOverlap: CGFloat
        var rank: Int

        static func < (lhs: Score, rhs: Score) -> Bool {
            if lhs.touchesPhoto != rhs.touchesPhoto { return !lhs.touchesPhoto }
            if lhs.shrink != rhs.shrink { return lhs.shrink < rhs.shrink }
            if lhs.photoOverlap != rhs.photoOverlap { return lhs.photoOverlap < rhs.photoOverlap }
            return lhs.rank < rhs.rank
        }
    }

    private static func search(in canvas: CGSize,
                               naturalWidth: CGFloat,
                               height: CGFloat,
                               obstacles: ToastObstacles,
                               hard: [CGRect],
                               minimumWidth: CGFloat,
                               inset: CGFloat) -> CGRect? {
        var best: (frame: CGRect, score: Score)?
        for candidate in candidates(in: canvas, height: height, obstacles: obstacles, inset: inset) {
            guard let frame = fit(width: naturalWidth, height: height,
                                  y: candidate.y, edge: candidate.edge,
                                  canvas: canvas, hard: hard,
                                  minimumWidth: minimumWidth, inset: inset) else { continue }
            let overlap = obstacles.photo.map { area(frame.intersection($0)) } ?? 0
            let score = Score(touchesPhoto: overlap > 0.5,
                              shrink: naturalWidth - frame.width,
                              photoOverlap: overlap,
                              rank: candidate.rank)
            if best == nil || score < best!.score {
                best = (frame, score)
            }
        }
        return best?.frame
    }

    private static func candidates(in canvas: CGSize,
                                   height: CGFloat,
                                   obstacles: ToastObstacles,
                                   inset: CGFloat) -> [Candidate] {
        var rows: [(y: CGFloat, rank: Int)] = [(inset, 0)]
        if let label = obstacles.beforeLabel ?? obstacles.afterLabel {
            rows.append((label.maxY + clearance, 3))
        }
        rows.append((canvas.height - inset - height, 6))
        if let dock = obstacles.dock {
            rows.append((dock.minY - clearance - height, 9))
        }
        rows.append(((canvas.height - height) / 2, 12))

        var result: [Candidate] = []
        for row in rows {
            for (offset, edge) in Edge.allCases.enumerated() {
                result.append(Candidate(y: row.y, edge: edge, rank: row.rank + offset))
            }
        }
        return result
    }

    /// Fits as much of the pill as possible into one free horizontal span of
    /// the row, choosing the span that keeps the pill widest.
    private static func fit(width: CGFloat,
                            height: CGFloat,
                            y: CGFloat,
                            edge: Edge,
                            canvas: CGSize,
                            hard: [CGRect],
                            minimumWidth: CGFloat,
                            inset: CGFloat) -> CGRect? {
        let lowest = max(inset, canvas.height - inset - height)
        let y = min(max(y, inset), lowest)
        let left = inset
        let right = canvas.width - inset
        guard right > left else { return nil }

        var free: [ClosedRange<CGFloat>] = [left...right]
        let band = CGRect(x: 0, y: y, width: canvas.width, height: height)
        for rect in hard {
            let crossing = rect.intersection(band)
            guard !crossing.isNull, crossing.width > 0.01, crossing.height > 0.01 else { continue }
            let lower = max(left, rect.minX)
            let upper = min(right, rect.maxX)
            guard upper - lower > 0.01 else { continue }
            free = subtract(free, lower...upper)
        }

        var options: [CGRect] = []
        for span in free {
            let fitted = min(width, span.upperBound - span.lowerBound)
            guard fitted + 0.01 >= minimumWidth else { continue }
            let x: CGFloat
            switch edge {
            case .leading:
                x = span.lowerBound
            case .trailing:
                x = span.upperBound - fitted
            case .center:
                x = min(max(canvas.width / 2 - fitted / 2, span.lowerBound),
                        span.upperBound - fitted)
            }
            options.append(CGRect(x: x, y: y, width: fitted, height: height))
        }
        guard !options.isEmpty else { return nil }

        // Prefer the widest slot; on a tie keep the requested edge, so a
        // leading row stays on the left when both sides have room.
        return options.max { lhs, rhs in
            if abs(lhs.width - rhs.width) > 0.01 { return lhs.width < rhs.width }
            switch edge {
            case .leading: return lhs.minX > rhs.minX
            case .trailing: return lhs.minX < rhs.minX
            case .center: return abs(lhs.midX - canvas.width / 2) > abs(rhs.midX - canvas.width / 2)
            }
        }
    }

    private static func subtract(_ ranges: [ClosedRange<CGFloat>],
                                 _ cut: ClosedRange<CGFloat>) -> [ClosedRange<CGFloat>] {
        var result: [ClosedRange<CGFloat>] = []
        for range in ranges {
            if cut.upperBound <= range.lowerBound + 0.01
                || cut.lowerBound >= range.upperBound - 0.01 {
                result.append(range)
                continue
            }
            if cut.lowerBound > range.lowerBound + 0.01 {
                result.append(range.lowerBound...cut.lowerBound)
            }
            if cut.upperBound < range.upperBound - 0.01 {
                result.append(cut.upperBound...range.upperBound)
            }
        }
        return result
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return 0 }
        return rect.width * rect.height
    }
}

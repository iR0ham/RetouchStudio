import AppKit
import SwiftUI
import StudioCore

/// Drag targets for the analysis line ends and the dots on the face. The lines
/// themselves are drawn by `AnalysisRenderer`; this layer only moves where a
/// line stops, which is where the owner's label will sit, and where it starts
/// on the feature.
struct AnalysisOverlay: View {
    @ObservedObject var model: EditorModel
    let displayed: CGSize

    private enum Handle: Equatable {
        case end(AnalysisRegion)
        case anchor(AnalysisRegion)

        var region: AnalysisRegion {
            switch self {
            case .end(let region), .anchor(let region): return region
            }
        }
    }

    @State private var dragging: Handle?
    @State private var startResolved = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            target

            ForEach(model.analysisAnchors, id: \.region) { anchor in
                dotHandle(at: anchor.point, active: dragging == .anchor(anchor.region))
            }
            ForEach(model.analysisLeaders, id: \.region) { leader in
                endHandle(at: leader.end, active: dragging == .end(leader.region))
            }
        }
        .frame(width: displayed.width, height: displayed.height)
        // Losing focus cancels the mouse-up, so a half-finished drag would
        // otherwise stay armed and move a pin on the next click.
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didResignKeyNotification)) { _ in
            dragging = nil
            startResolved = false
        }
    }

    /// One surface over the photo, like the sticker layer uses: a handle that
    /// small has a hit area too easy to miss, and the nearest handle within a
    /// finger's width is what the owner meant anyway.
    private var target: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: displayed.width, height: displayed.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // The click that brings the window forward must not
                        // move a pin.
                        guard model.acceptsPointerEdit else { return }
                        if !startResolved {
                            startResolved = true
                            dragging = resolve(normalized(value.startLocation))
                        }
                        guard let dragging else { return }
                        drag(dragging, to: normalized(value.location))
                    }
                    .onEnded { _ in
                        dragging = nil
                        startResolved = false
                    }
            )
    }

    /// The face dot and the outer end share one hit test, so a press between
    /// them moves whichever is actually under the pointer.
    private func resolve(_ point: CGPoint) -> Handle? {
        var best: (handle: Handle, distance: CGFloat)?
        func consider(_ handle: Handle, _ target: CGPoint) {
            let distance = hypot(target.x - point.x, target.y - point.y)
            guard distance <= grabTolerance else { return }
            if best == nil || distance < best!.distance { best = (handle, distance) }
        }
        for anchor in model.analysisAnchors { consider(.anchor(anchor.region), anchor.point) }
        for leader in model.analysisLeaders { consider(.end(leader.region), leader.end) }
        return best?.handle
    }

    private func drag(_ handle: Handle, to point: CGPoint) {
        switch handle {
        case .end(let region): model.dragAnalysisEnd(region, to: point)
        case .anchor(let region): model.dragAnalysisAnchor(region, to: point)
        }
    }

    /// A ring on the dot that sits on the feature, so it reads as something to
    /// pick up rather than as part of the drawing.
    private func dotHandle(at point: CGPoint, active: Bool) -> some View {
        Circle()
            .strokeBorder(active ? Theme.accentBright : Theme.accent.opacity(0.85),
                          lineWidth: active ? 1.6 : 1)
            .background(Circle().fill(Theme.accent.opacity(active ? 0.22 : 0.10)))
            .frame(width: active ? 15 : 11, height: active ? 15 : 11)
            .frame(width: 24, height: 24)
            .position(x: point.x * displayed.width,
                      y: (1 - point.y) * displayed.height)
            .animation(Motion.snappy, value: active)
            .allowsHitTesting(false)
    }

    private func endHandle(at end: CGPoint, active: Bool) -> some View {
        Circle()
            .strokeBorder(active ? Theme.accentBright : Theme.accent,
                          style: StrokeStyle(lineWidth: active ? 1.6 : 1.1,
                                             dash: active ? [] : [2.5, 2.5]))
            .opacity(active ? 1 : 0.8)
            .frame(width: active ? 20 : 14, height: active ? 20 : 14)
            .frame(width: 24, height: 24)
            .position(x: end.x * displayed.width,
                      y: (1 - end.y) * displayed.height)
            .animation(Motion.snappy, value: active)
            .allowsHitTesting(false)
    }

    /// A 24 pt grab radius, in the normalized units the model stores.
    private var grabTolerance: CGFloat {
        max(0.02, 24 / max(1, min(displayed.width, displayed.height)))
    }

    /// The overlay is stored bottom-left, the way the renderer and the export
    /// read it; the canvas measures from the top-left.
    private func normalized(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / max(1, displayed.width),
                y: 1 - point.y / max(1, displayed.height))
    }
}

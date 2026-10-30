import SwiftUI

/// Manual healing brush layer. A click places a stamp, a click inside an
/// existing stamp takes it back; the stamps themselves live in the model as
/// original-photo coordinates, so zooming, panning and cropping all keep them
/// attached to the blemish they were placed on.
struct HealOverlay: View {
    @ObservedObject var model: EditorModel
    let displayed: CGSize

    @State private var hover: CGPoint?

    /// Stamps are sized against the image's short side, so the same fraction
    /// reads as the same pixel size at any zoom or window size.
    private var shortSide: CGFloat { min(displayed.width, displayed.height) }

    private var brushDiameter: CGFloat {
        max(6, model.healBrushRadius * 2 * shortSide)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.visibleHealSpots, id: \.index) { entry in
                let diameter = max(4, entry.spot.radius * 2 * shortSide)
                Circle()
                    .fill(Theme.accent.opacity(0.16))
                    .overlay(Circle().strokeBorder(Theme.bone.opacity(0.9), lineWidth: 1))
                    .frame(width: diameter, height: diameter)
                    .position(x: entry.spot.center.x * displayed.width,
                              y: entry.spot.center.y * displayed.height)
                    .allowsHitTesting(false)
            }

            target

            if let hover {
                Circle()
                    .strokeBorder(Theme.bone.opacity(0.7), lineWidth: 1)
                    .frame(width: brushDiameter, height: brushDiameter)
                    .position(hover)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: displayed.width, height: displayed.height)
    }

    /// A near-transparent surface: enough to receive clicks over the whole
    /// photo, including the background, not only where the face masks found skin.
    private var target: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: displayed.width, height: displayed.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hover = location
                case .ended: hover = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        // The click that brings the window forward must not
                        // heal or erase anything.
                        guard model.acceptsPointerEdit else { return }
                        let point = CGPoint(
                            x: value.location.x / max(1, displayed.width),
                            y: value.location.y / max(1, displayed.height))
                        model.tapHeal(at: point)
                    }
            )
    }
}

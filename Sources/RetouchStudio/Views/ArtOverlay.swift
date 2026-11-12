import AppKit
import Combine
import SwiftUI
import StudioCore

/// The sticker layer. A click on empty photo places the current sticker, a
/// click on one selects it, and a drag moves it. Stickers live in the model as
/// original-photo coordinates, so a crop keeps them on the spot they were
/// placed on.
struct ArtOverlay: View {
    @ObservedObject var model: EditorModel
    let displayed: CGSize

    @State private var dragging: UUID?
    @State private var startResolved = false

    /// Sticker sizes are fractions of the short side, so they read the same at
    /// any zoom or window size and match what the export draws.
    private var shortSide: CGFloat { min(displayed.width, displayed.height) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            target

            ForEach(model.visibleStickers, id: \.sticker.id) { entry in
                stickerLayer(entry.sticker)
            }

            if let selected = model.visibleStickers
                .first(where: { $0.sticker.id == model.selectedSticker })?.sticker {
                selectionHandles(for: selected)
            }
        }
        .frame(width: displayed.width, height: displayed.height)
        // Losing focus cancels the mouse-up, so a half-finished drag would
        // otherwise stay armed and move a sticker on the next click.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification)) { _ in
            dragging = nil
            startResolved = false
        }
    }

    private func stickerLayer(_ sticker: Sticker) -> some View {
        let side = max(8, sticker.size * shortSide)
        let isSelected = model.selectedSticker == sticker.id

        return ZStack {
            if let glyph = model.stickerGlyph(sticker) {
                Image(nsImage: glyph)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: side, height: side)
                    .rotationEffect(.degrees(sticker.rotation))
                    .opacity(sticker.opacity)
            }

            if isSelected {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.accentBright,
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: side + 8, height: side + 8)
                    .rotationEffect(.degrees(sticker.rotation))
            }
        }
        .position(x: sticker.center.x * displayed.width,
                  y: sticker.center.y * displayed.height)
        .allowsHitTesting(false)
    }

    /// A near-transparent surface over the whole photo: the background can
    /// receive a sticker too, not only the skin the face masks found.
    private var target: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: displayed.width, height: displayed.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !startResolved {
                            startResolved = true
                            let start = normalized(value.startLocation)
                            dragging = model.stickerID(at: start)
                            if let id = dragging { model.selectSticker(id) }
                        }

                        if let id = dragging {
                            model.moveSticker(id, to: normalized(value.location))
                        }
                    }
                    .onEnded { value in
                        // The click that brings the window forward is also
                        // delivered here, and a tap lands where it pressed.
                        let isTap = hypot(value.translation.width,
                                          value.translation.height) < 2
                        if model.acceptsPointerEdit, isTap, dragging == nil {
                            model.tapArt(at: normalized(value.startLocation))
                        }
                        dragging = nil
                        startResolved = false
                    }
            )
    }

    /// Corner and rotation handles for the selected sticker. Both drive the
    /// stored sticker through the model, so they match the sliders exactly and
    /// stay correct at any zoom.
    private func selectionHandles(for sticker: Sticker) -> some View {
        let side = max(8, sticker.size * shortSide)
        let center = CGPoint(x: sticker.center.x * displayed.width,
                             y: sticker.center.y * displayed.height)
        let corner = point(around: center,
                           angle: sticker.rotation + 45,
                           distance: side * 0.5 * 1.41421356)
        let rotor = point(around: center,
                          angle: sticker.rotation - 90,
                          distance: side * 0.5 + 20)

        return ZStack {
            Circle()
                .fill(Theme.panel)
                .overlay(Circle().stroke(Theme.accentBright, lineWidth: 1.5))
                .frame(width: 9, height: 9)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
                .position(rotor)
                .help(model.s.artDragRotate)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // The click that activates the window also lands
                            // here; it must not nudge the rotation.
                            guard model.acceptsPointerEdit else { return }
                            let dx = Double(value.location.x - center.x)
                            let dy = Double(value.location.y - center.y)
                            model.rotateSelectedSticker(atan2(dy, dx) * 180 / Double.pi + 90)
                        }
                )

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Theme.accentBright)
                .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(Theme.panel, lineWidth: 1.5))
                .frame(width: 10, height: 10)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
                .position(corner)
                .help(model.s.artDragResize)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard model.acceptsPointerEdit else { return }
                            let dx = Double(value.location.x - center.x)
                            let dy = Double(value.location.y - center.y)
                            // The handle sits on the diagonal, so the side is
                            // the distance from the center times √2.
                            let fraction = hypot(dx, dy) * 1.41421356 / Double(max(1, shortSide))
                            model.resizeSelectedSticker(workingFraction: fraction)
                        }
                )
        }
    }

    private func point(around center: CGPoint, angle: Double, distance: CGFloat) -> CGPoint {
        let radians = angle * Double.pi / 180
        return CGPoint(x: center.x + CGFloat(cos(radians)) * distance,
                       y: center.y + CGFloat(sin(radians)) * distance)
    }

    private func normalized(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / max(1, displayed.width),
                y: point.y / max(1, displayed.height))
    }
}

import AppKit
import Combine
import SwiftUI

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

    private func normalized(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / max(1, displayed.width),
                y: point.y / max(1, displayed.height))
    }
}

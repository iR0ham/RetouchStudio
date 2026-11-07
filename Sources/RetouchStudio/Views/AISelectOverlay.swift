import SwiftUI

/// The selection layer for Quick Edit: the tinted mask, the point marker, and
/// the pointer handling for point / brush / box. It only captures the pointer
/// while the owner is picking; afterwards the canvas keeps panning and
/// comparing, and the selection stays visible.
struct AISelectOverlay: View {
    @ObservedObject var model: EditorModel
    let displayed: CGSize

    @State private var hover: CGPoint?
    @State private var stroke: [CGPoint] = []
    @State private var dragBox: CGRect?

    var body: some View {
        ZStack(alignment: .topLeading) {
            selection

            if let point = model.quickEditPoint {
                marker.position(x: point.x * displayed.width,
                                y: point.y * displayed.height)
            }

            if model.isAIPicking {
                if model.aiMaskTool == .brush, let hover {
                    brushCursor(hover)
                }
                if model.aiMaskTool == .box, let hover, dragBox == nil {
                    brushCursor(hover)
                }
                target
            }
        }
        .frame(width: displayed.width, height: displayed.height)
        .onDisappear { hover = nil; stroke = []; dragBox = nil }
    }

    // MARK: - Painted selection

    private var selection: some View {
        ZStack(alignment: .topLeading) {
            if let mask = model.aiMaskPreview {
                Image(decorative: mask, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .renderingMode(.template)
                    .foregroundStyle(Theme.accent.opacity(0.38))
                    .frame(width: displayed.width, height: displayed.height)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if stroke.count > 1 {
                liveStroke(stroke)
                    .stroke(model.aiMaskErasing ? Theme.warning.opacity(0.5)
                                                : Theme.accent.opacity(0.38),
                            style: StrokeStyle(lineWidth: strokeWidth,
                                               lineCap: .round, lineJoin: .round))
                    .allowsHitTesting(false)
            }

            if let dragBox {
                let rect = screenRect(dragBox)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.accent.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .strokeBorder(Theme.accent.opacity(0.8),
                                          style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }
        }
        .animation(Motion.snappy, value: model.aiMaskPreview != nil)
    }

    private var strokeWidth: CGFloat {
        max(2, CGFloat(model.aiMaskStrokeWidth) * displayed.width)
    }

    private func liveStroke(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.x * displayed.width,
                              y: first.y * displayed.height))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: point.x * displayed.width,
                                     y: point.y * displayed.height))
        }
        return path
    }

    private func screenRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * displayed.width,
               y: rect.minY * displayed.height,
               width: rect.width * displayed.width,
               height: rect.height * displayed.height)
    }

    // MARK: - Cursors and marker

    private var marker: some View {
        ZStack {
            Circle()
                .fill(Theme.accent.opacity(0.14))
                .frame(width: 34, height: 34)
            Circle()
                .strokeBorder(Theme.bone.opacity(0.95), lineWidth: 1.2)
                .frame(width: 34, height: 34)
            Rectangle()
                .fill(Theme.bone.opacity(0.95))
                .frame(width: 1, height: 10)
            Rectangle()
                .fill(Theme.bone.opacity(0.95))
                .frame(width: 10, height: 1)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func brushCursor(_ position: CGPoint) -> some View {
        Circle()
            .strokeBorder(Theme.bone.opacity(0.7), lineWidth: 1)
            .frame(width: max(6, strokeWidth), height: max(6, strokeWidth))
            .position(position)
            .allowsHitTesting(false)
    }

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
            .gesture(dragGesture)
    }

    // MARK: - Pointer

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard model.acceptsPointerEdit else { return }
                let point = normalized(value.location)
                switch model.aiMaskTool {
                case .point:
                    break
                case .brush:
                    if let last = stroke.last {
                        let dx = point.x - last.x, dy = point.y - last.y
                        guard dx * dx + dy * dy > 0.000004 else { return }
                        stroke.append(point)
                    } else {
                        stroke = [point]
                    }
                case .box:
                    dragBox = rect(from: normalized(value.startLocation), to: point)
                }
            }
            .onEnded { value in
                defer { stroke = []; dragBox = nil }
                guard model.acceptsPointerEdit else { return }
                let point = normalized(value.location)
                switch model.aiMaskTool {
                case .point:
                    withAnimation(Motion.snappy) {
                        model.placeQuickEditPoint(point)
                    }
                case .brush:
                    var points = stroke
                    if let last = points.last, last != point { points.append(point) }
                    guard !points.isEmpty else { return }
                    model.appendMaskStroke(AIMaskStroke(
                        points: points,
                        width: CGFloat(model.aiMaskStrokeWidth),
                        erase: model.aiMaskErasing))
                case .box:
                    if let box = dragBox, box.width >= 0.01, box.height >= 0.01 {
                        model.setMaskBox(box)
                    }
                }
            }
    }

    private func normalized(_ location: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, location.x / max(1, displayed.width))),
                y: min(1, max(0, location.y / max(1, displayed.height))))
    }

    private func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}

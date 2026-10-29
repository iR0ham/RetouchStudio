import SwiftUI

/// Interactive crop frame over the photo. The normalized draft lives in the
/// model; this view only converts to and from canvas points, so the same crop
/// survives zooming, window resizing and project save.
struct CropOverlay: View {
    @ObservedObject var model: EditorModel
    let displayed: CGSize

    @State private var moveStart: CGRect?
    @State private var resizeStart: CGRect?

    private enum Corner: CaseIterable, Hashable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private var frame: CGRect {
        CropGeometry.viewRect(model.cropDraft, in: displayed)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            dimming
            thirds
            border
            moveTarget

            ForEach(Corner.allCases, id: \.self) { corner in
                handle(corner)
            }

            sizeBadge
        }
        .frame(width: displayed.width, height: displayed.height)
        .animation(.easeOut(duration: 0.12), value: model.cropAspect)
    }

    // MARK: - Drawing

    /// Everything outside the crop is darkened with an even-odd fill, so the
    /// removal is a real hole rather than four rectangles that leave seams.
    private var dimming: some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: displayed))
            path.addRect(frame)
        }
        .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    private var thirds: some View {
        Path { path in
            for index in 1...2 {
                let x = frame.minX + frame.width * CGFloat(index) / 3
                path.move(to: CGPoint(x: x, y: frame.minY))
                path.addLine(to: CGPoint(x: x, y: frame.maxY))

                let y = frame.minY + frame.height * CGFloat(index) / 3
                path.move(to: CGPoint(x: frame.minX, y: y))
                path.addLine(to: CGPoint(x: frame.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.34), lineWidth: 0.5)
        .allowsHitTesting(false)
    }

    private var border: some View {
        Rectangle()
            .strokeBorder(Theme.bone.opacity(0.9), lineWidth: 1)
            .frame(width: max(1, frame.width), height: max(1, frame.height))
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
    }

    private var moveTarget: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: max(1, frame.width), height: max(1, frame.height))
            .position(x: frame.midX, y: frame.midY)
            .contentShape(Rectangle())
            .gesture(moveGesture)
    }

    private func handle(_ corner: Corner) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Theme.bone)
            .frame(width: 9, height: 9)
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.45), lineWidth: 0.5)
            )
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .position(cornerPoint(corner))
            .gesture(resizeGesture(corner))
    }

    private var sizeBadge: some View {
        let size = model.cropDraftPixelSize
        let below = frame.maxY + 18
        let y = below <= displayed.height - 10 ? below : max(frame.minY - 18, 14)

        return Text("\(Digits.num(Int(size.width))) × \(Digits.num(Int(size.height)))")
            .font(Theme.Font.face(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Theme.bone)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .position(x: frame.midX, y: y)
            .allowsHitTesting(false)
    }

    // MARK: - Gestures

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard displayed.width > 0, displayed.height > 0 else { return }
                if moveStart == nil { moveStart = model.cropDraft }
                guard let start = moveStart else { return }

                let dx = value.translation.width / displayed.width
                let dy = value.translation.height / displayed.height
                var next = start.offsetBy(dx: dx, dy: dy)
                next.origin.x = min(max(0, next.minX), 1 - next.width)
                next.origin.y = min(max(0, next.minY), 1 - next.height)
                model.cropDraft = next
            }
            .onEnded { _ in moveStart = nil }
    }

    private func resizeGesture(_ corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard displayed.width > 0, displayed.height > 0 else { return }
                if resizeStart == nil { resizeStart = model.cropDraft }
                guard let start = resizeStart else { return }

                let sign = signs(for: corner)
                let dx = value.translation.width / displayed.width
                let dy = value.translation.height / displayed.height

                // The opposite corner stays pinned.
                let anchor = CGPoint(x: sign.x > 0 ? start.minX : start.maxX,
                                     y: sign.y > 0 ? start.minY : start.maxY)
                let pointerX = (sign.x > 0 ? start.maxX : start.minX) + dx
                let pointerY = (sign.y > 0 ? start.maxY : start.minY) + dy
                var width = (pointerX - anchor.x) * sign.x
                var height = (pointerY - anchor.y) * sign.y

                let maxWidth = sign.x > 0 ? 1 - anchor.x : anchor.x
                let maxHeight = sign.y > 0 ? 1 - anchor.y : anchor.y

                if let ratio = model.cropAspect.ratio(originalAspect: model.workingAspect) {
                    let imageAspect = max(model.workingAspect, 0.0001)
                    // Whichever edge the pointer moved further drives the size,
                    // then the other edge follows the locked aspect.
                    let fromWidth = max(CropGeometry.minimumSize, width)
                    let fromHeight = max(CropGeometry.minimumSize, height) * ratio / imageAspect
                    let minimumWidth = max(CropGeometry.minimumSize,
                                           CropGeometry.minimumSize * ratio / imageAspect)
                    let availableWidth = min(maxWidth, maxHeight * ratio / imageAspect)

                    var target = max(fromWidth, fromHeight)
                    target = min(target, availableWidth)
                    target = max(target, min(minimumWidth, availableWidth))

                    width = target
                    height = target * imageAspect / ratio
                } else {
                    width = min(max(CropGeometry.minimumSize, width), maxWidth)
                    height = min(max(CropGeometry.minimumSize, height), maxHeight)
                }

                let rect = CGRect(x: sign.x > 0 ? anchor.x : anchor.x - width,
                                  y: sign.y > 0 ? anchor.y : anchor.y - height,
                                  width: width,
                                  height: height)
                model.cropDraft = CropGeometry.clamped(rect)
            }
            .onEnded { _ in resizeStart = nil }
    }

    // MARK: - Geometry

    private func signs(for corner: Corner) -> (x: CGFloat, y: CGFloat) {
        switch corner {
        case .topLeft: return (-1, -1)
        case .topRight: return (1, -1)
        case .bottomLeft: return (-1, 1)
        case .bottomRight: return (1, 1)
        }
    }

    private func cornerPoint(_ corner: Corner) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: frame.minX, y: frame.minY)
        case .topRight: return CGPoint(x: frame.maxX, y: frame.minY)
        case .bottomLeft: return CGPoint(x: frame.minX, y: frame.maxY)
        case .bottomRight: return CGPoint(x: frame.maxX, y: frame.maxY)
        }
    }
}

import AppKit
import SwiftUI

struct CompareCanvas: View {
    @ObservedObject var model: EditorModel
    @Binding var isDropTarget: Bool
    @StateObject private var events = CanvasEventMonitor()
    @State private var panStart: CGSize?
    @State private var isPanning = false
    @State private var compareDrag: (fraction: Double, x: CGFloat)?

    /// Canvas-wide coordinate space. The handle moves as it is dragged, so
    /// measuring the gesture against a space that stays put is the only way
    /// the split does not chase its own tail.
    private let canvasSpace = "compareCanvas"

    var body: some View {
        ZStack {
            CanvasSurface()

            if let processed = model.previewImage, let original = model.originalImage {
                editor(processed: processed, original: original)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            } else {
                DropZone(model: model) { model.openImage() }
                    .transition(.opacity)
            }
        }
        .onChange(of: model.hasImage) { _, _ in
            withAnimation(Motion.swell) { }
        }
        .background(
            ViewAnchor { view in events.attach(view: view) }
                .allowsHitTesting(false)
        )
        .onHover { inside in
            events.isPointerInside = inside
        }
        .onAppear {
            events.onScroll = { dx, dy, command, point in
                if command {
                    // ⌘-scroll zooms about the pointer.
                    model.setZoom(model.zoom * exp(Double(dy) * 0.01), anchor: point)
                } else {
                    model.panOffset.width += dx
                    model.panOffset.height += dy
                    model.clampPan()
                }
            }
            events.onMagnify = { magnification, point in
                model.setZoom(model.zoom * Double(1 + magnification), anchor: point)
            }
            events.onKeyDown = { key in
                guard model.hasImage else { return false }
                if key == " " {
                    model.isPeekingOriginal = true
                    return true
                }
                if model.toolMode == .heal, key == "[" {
                    model.nudgeHealBrush(by: -0.2)
                    return true
                }
                if model.toolMode == .heal, key == "]" {
                    model.nudgeHealBrush(by: 0.2)
                    return true
                }
                return model.selectTool(shortcut: key)
            }
            events.onKeyUp = { key in
                if key == " " {
                    model.endPeek()
                }
            }
            events.start()
        }
        .onDisappear { events.stop() }
        .overlay(alignment: .topLeading) {
            // The face count lives in the status card; this pill is only for
            // what just happened, so it does not sit there repeating itself.
            if model.isBusy || showsToast {
                statusPill.padding(14)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(Motion.smooth, value: model.status)
        .animation(Motion.smooth, value: model.isBusy)
        .overlay(alignment: .bottom) {
            if model.hasImage {
                canvasDock.padding(.bottom, 14)
            }
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: Theme.Radius.canvas, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        // The stage is a card of its own: rounded, hairlined, and the only thing
        // between the photo and the shell.
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.canvas, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.canvas, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.30), radius: 12, y: 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Canvas

    /// True when the status line is reporting an action rather than the standing
    /// face count.
    private var showsToast: Bool {
        model.hasImage && !model.status.isEmpty && model.status != model.faceStatusText
    }

    /// The photo gets soft corners while the whole sheet is visible, the way the
    /// reference presents it. Once zoomed in the stage crops it anyway, so the
    /// corners go square and no pixel is hidden behind a radius.
    private var sheetRadius: CGFloat {
        model.zoom > 1.0001 ? 0 : 10
    }

    private func editor(processed: NSImage, original: NSImage) -> some View {
        GeometryReader { geometry in
            let canvas = geometry.size
            let displayed = model.displayedCanvasSize
            let center = CGPoint(x: canvas.width / 2 + model.panOffset.width,
                                 y: canvas.height / 2 + model.panOffset.height)

            ZStack {
                // A soft drop shadow makes the photo read as a sheet lying on
                // the surface, the way Photos and Preview present an image.
                RoundedRectangle(cornerRadius: sheetRadius, style: .continuous)
                    .fill(Color.black.opacity(0.60))
                    .frame(width: displayed.width, height: displayed.height)
                    .position(x: center.x, y: center.y + 6)
                    .blur(radius: 14)
                    .opacity(model.zoom > 1.0001 ? 0 : 1)
                    .allowsHitTesting(false)

                if model.adjustments.backgroundRemove {
                    TransparencyGrid()
                        .frame(width: displayed.width, height: displayed.height)
                        .clipShape(RoundedRectangle(cornerRadius: sheetRadius, style: .continuous))
                        .position(center)
                        .allowsHitTesting(false)
                }

                Image(nsImage: processed)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: displayed.width, height: displayed.height)
                    .clipShape(RoundedRectangle(cornerRadius: sheetRadius, style: .continuous))
                    .position(center)

                if model.toolMode == .crop && !model.isAIPicking {
                    CropOverlay(model: model, displayed: displayed)
                        .position(center)
                }

                if model.toolMode == .heal && !model.isAIPicking {
                    HealOverlay(model: model, displayed: displayed)
                        .position(center)
                }

                if model.toolMode == .art && !model.isAIPicking {
                    ArtOverlay(model: model, displayed: displayed)
                        .position(center)
                }

                // The analysis lines sit on the finished photo, at the same
                // coordinates the export uses. While Space shows the original
                // they step aside so the peek stays untouched.
                if !model.isPeekingOriginal, let overlay = model.analysisOverlay {
                    Image(decorative: overlay, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: displayed.width, height: displayed.height)
                        .clipShape(RoundedRectangle(cornerRadius: sheetRadius, style: .continuous))
                        .position(center)
                        .allowsHitTesting(false)
                }

                if model.toolMode == .analysis && !model.isPeekingOriginal && !model.isAIPicking {
                    AnalysisOverlay(model: model, displayed: displayed)
                        .position(center)
                }

                // Quick Edit owns the pointer only while it is picking, so the
                // canvas keeps panning and comparing at every other time.
                if (model.isAIPicking || model.quickEditPoint != nil
                    || model.aiMaskHasSelection) && !model.isPeekingOriginal {
                    AISelectOverlay(model: model, displayed: displayed)
                        .position(center)
                }

                if model.compareEnabled && !model.toolOwnsCanvas {
                    Image(nsImage: original)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: displayed.width, height: displayed.height)
                        .clipShape(PartialRect(fraction: model.comparePosition))
                        .clipShape(RoundedRectangle(cornerRadius: sheetRadius, style: .continuous))
                        .position(center)

                    compareHandle(displayed: displayed, canvas: canvas, center: center)

                    // The tags hug whichever corners of the photo are actually
                    // visible, and they only appear while the split itself is on
                    // the stage: with the photo zoomed past the canvas the
                    // boundary can sit off-screen, and then one side fills the
                    // whole view and the tags would lie about it.
                    let splitX = center.x - displayed.width / 2 + displayed.width * CGFloat(model.comparePosition)
                    if splitX >= 0, splitX <= canvas.width {
                        let visibleLeft = max(0, center.x - displayed.width / 2)
                        let visibleTop = max(0, center.y - displayed.height / 2)
                        let visibleRight = min(canvas.width, center.x + displayed.width / 2)
                        let visibleBottom = min(canvas.height, center.y + displayed.height / 2)

                        HStack(spacing: 0) {
                            compareBadge(model.s.before, highlighted: false)
                            Spacer(minLength: 0)
                            compareBadge(model.s.after, highlighted: true)
                        }
                        .padding(10)
                        .frame(width: max(0, visibleRight - visibleLeft),
                               height: max(0, visibleBottom - visibleTop),
                               alignment: .top)
                        .position(x: (visibleLeft + visibleRight) / 2,
                                  y: (visibleTop + visibleBottom) / 2)
                        .allowsHitTesting(false)
                    }
                }

                if model.showFaceOverlay && !model.toolOwnsCanvas {
                    FaceOverlayView(faces: model.faces)
                        .frame(width: displayed.width, height: displayed.height, alignment: .topLeading)
                        .position(center)
                        .allowsHitTesting(false)
                }

                // The held-Space peek covers every overlay as well: the point is
                // to judge the edit against the photo as it arrived.
                if model.isPeekingOriginal {
                    Image(nsImage: original)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: displayed.width, height: displayed.height)
                        .clipShape(RoundedRectangle(cornerRadius: sheetRadius, style: .continuous))
                        .position(center)
                        .allowsHitTesting(false)

                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            compareBadge(model.s.before, highlighted: false)
                            Spacer(minLength: 0)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .allowsHitTesting(false)
                }
            }
            // The photo plane is not a sentence: masks, handles, healing spots
            // and the before/after split must keep their own left-to-right
            // geometry even when the shell is mirrored for Persian.
            .environment(\.layoutDirection, .leftToRight)
            .frame(width: canvas.width, height: canvas.height)
            .coordinateSpace(name: canvasSpace)
            .contentShape(Rectangle())
            // Clip to the canvas region. Without this the zoomed photo spills
            // out over the sidebar and toolbar instead of staying in its own
            // area.
            .clipped()
            .onAppear { model.updateCanvasSize(canvas) }
            .onChange(of: canvas) { _, newValue in model.updateCanvasSize(newValue) }
            // Dragging ALWAYS moves the photo. Scrubbing the before/after split
            // is the handle's own gesture, so the two never fight.
            .gesture(panGesture)
            .onTapGesture(count: 2) {
                guard !model.toolOwnsCanvas else { return }
                if model.zoom > 1.0001 {
                    model.resetView()
                } else {
                    model.setZoom(model.effectiveMaxZoom)
                }
            }
        }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                // The crop frame and the brush own the pointer in their modes.
                guard !model.toolOwnsCanvas else { return }
                if panStart == nil {
                    panStart = model.panOffset
                    isPanning = true
                }
                guard let start = panStart else { return }
                model.panOffset = CGSize(width: start.width + value.translation.width,
                                         height: start.height + value.translation.height)
                model.clampPan()
            }
            .onEnded { _ in
                panStart = nil
                isPanning = false
            }
    }

    /// Split line plus its drag handle. The whole line is grabbable — a knob
    /// alone is a small target that people miss — but the strip is narrow
    /// enough that it never swallows a pan that starts well away from it.
    private func compareHandle(displayed: CGSize, canvas: CGSize, center: CGPoint) -> some View {
        let x = center.x - displayed.width / 2 + displayed.width * CGFloat(model.comparePosition)
        let lineHeight = max(displayed.height, canvas.height)
        let hitWidth: CGFloat = 28

        return ZStack {
            Rectangle()
                .fill(Theme.bone.opacity(0.88))
                .frame(width: 1, height: lineHeight)
                .allowsHitTesting(false)

            ZStack {
                Circle()
                    .fill(Theme.panel)
                    .frame(width: 32, height: 32)
                    .overlay(Circle().strokeBorder(Theme.accent.opacity(0.85), lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 7, y: 2)
                Icon(name: "arrow.left.and.right", size: 13, emphasised: true)
                    .foregroundStyle(Theme.accentBright)
            }
        }
        .frame(width: hitWidth, height: lineHeight)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(canvasSpace))
                .onChanged { value in
                    guard displayed.width > 0 else { return }
                    if compareDrag == nil {
                        compareDrag = (model.comparePosition, value.startLocation.x)
                    }
                    guard let drag = compareDrag else { return }
                    let fraction = drag.fraction
                        + Double((value.location.x - drag.x) / displayed.width)
                    model.comparePosition = min(1, max(0, fraction))
                }
                .onEnded { _ in compareDrag = nil }
        )
        .position(x: x, y: center.y)
    }

    // MARK: - Chrome

    private func compareBadge(_ title: String, highlighted: Bool) -> some View {
        Text(title.uppercased())
            .font(Theme.Font.face(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(highlighted ? Theme.accentBright : Theme.bone.opacity(0.80))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.black.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(highlighted ? Theme.accent.opacity(0.55) : Theme.bone.opacity(0.18),
                                  lineWidth: 0.5)
            )
    }

    private var statusPill: some View {
        HStack(spacing: 7) {
            if model.isBusy {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 6, height: 6)
            } else {
                Circle()
                    .fill(model.faceStatusIsGood ? Theme.positive : Theme.warning)
                    .frame(width: 5, height: 5)
            }

            Text(model.status)
                .font(Theme.Font.face(size: 10.5))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)

            if !model.imageInfo.isEmpty && model.canvasSize.width > 980 {
                Text("·").foregroundStyle(Theme.faint)
                Text(model.imageInfo)
                    .font(Theme.Font.face(size: 10.5))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 9)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.panel.opacity(0.86))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 0.5)
        )
        .allowsHitTesting(false)
    }

    private var canvasDock: some View {
        HStack(spacing: 2) {
            dockButton(icon: "arrow.up.left.and.arrow.down.right",
                       active: model.zoom <= 1.0001,
                       help: model.s.fitToWindow) {
                model.resetView()
            }

            dockButton(icon: "minus.magnifyingglass",
                       enabled: model.zoom > 1.0001,
                       help: model.s.zoomOut) {
                model.zoomOut()
            }

            Text(model.zoom > 1.0001 ? Digits.percent(Int((model.zoom * 100).rounded())) : model.s.fit)
                .font(Theme.Font.face(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(model.zoom > 1.0001 ? Theme.accentBright : Theme.muted)
                .frame(minWidth: 38, minHeight: 28)

            dockButton(icon: "plus.magnifyingglass",
                       enabled: model.zoom < model.effectiveMaxZoom - 0.001,
                       help: model.s.zoomIn) {
                model.zoomIn()
            }

            dockSeparator

            dockButton(icon: "rectangle.split.2x1",
                       label: model.s.compare,
                       active: model.compareEnabled,
                       enabled: !model.toolOwnsCanvas,
                       help: model.s.compareToggle) {
                model.compareEnabled.toggle()
            }
            dockButton(icon: "face.dashed",
                       label: model.s.faceBox,
                       active: model.showFaceOverlay,
                       enabled: !model.toolOwnsCanvas,
                       help: model.s.faceBoxHelp) {
                model.showFaceOverlay.toggle()
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.panel.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.42), radius: 16, y: 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func dockButton(icon: String,
                            label: String? = nil,
                            active: Bool = false,
                            enabled: Bool = true,
                            help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Icon(name: icon, size: 14)
                if let label {
                    Text(label)
                        .font(Theme.Font.face(size: 11))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(active ? Theme.accentBright : Theme.muted)
            .frame(height: 28)
            .padding(.horizontal, 9)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? Theme.accentSoft : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(DockButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .help(help)
    }

    private var dockSeparator: some View {
        Rectangle()
            .fill(Theme.bone.opacity(0.11))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 3)
    }
}

/// Press feedback for the dock buttons without the stock macOS bezel.
private struct DockButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.bone.opacity(configuration.isPressed ? 0.08 : 0))
            )
    }
}

/// The grey checkerboard behind a removed background, so the transparency an
/// export will carry is visible on the canvas instead of reading as black.
struct TransparencyGrid: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 9
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(white: 0.90)))

            let columns = Int(ceil(size.width / cell))
            let rows = Int(ceil(size.height / cell))
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * cell,
                                      y: CGFloat(row) * cell,
                                      width: cell,
                                      height: cell)
                    context.fill(Path(rect), with: .color(Color(white: 0.78)))
                }
            }
        }
    }
}

/// The recessed dark surface the photo sits on. A very subtle radial lift in
/// the middle keeps it from looking like a flat black hole.
struct CanvasSurface: View {
    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Theme.bone.opacity(0.042), .clear],
                           center: .center, startRadius: 20, endRadius: 720)
        }
    }
}

/// Face box and feature regions (normalized coords, bottom-left origin).
struct FaceOverlayView: View {
    let faces: [FaceGeometry]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                ForEach(Array(faces.enumerated()), id: \.offset) { _, face in
                    roundedBox(viewRect(face.boundingBox, in: size),
                               color: Theme.accent, lineWidth: 1.5)
                    ForEach(Array(face.eyeRects.enumerated()), id: \.offset) { _, rect in
                        roundedBox(viewRect(rect, in: size), color: Theme.overlayEye.opacity(0.9),
                                   lineWidth: 1, dashed: true)
                    }
                    if let lip = face.lipRect {
                        roundedBox(viewRect(lip, in: size),
                                   color: Theme.overlayLip,
                                   lineWidth: 1, dashed: true)
                    }
                }
            }
        }
    }

    private func roundedBox(_ rect: CGRect, color: Color, lineWidth: CGFloat, dashed: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, dash: dashed ? [4, 3] : []))
            .frame(width: max(2, rect.width), height: max(2, rect.height))
            .position(x: rect.midX, y: rect.midY)
    }

    private func viewRect(_ normalized: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: normalized.minX * size.width,
               y: (1 - normalized.maxY) * size.height,
               width: normalized.width * size.width,
               height: normalized.height * size.height)
    }
}

struct DropZone: View {
    @ObservedObject var model: EditorModel
    let open: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Icon(name: "photo.on.rectangle.angled", size: 54)
                .foregroundStyle(Theme.faint)

            VStack(spacing: 5) {
                Text(model.s.dropTitle)
                    .font(Theme.Font.face(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(model.s.dropSubtitle)
                    .font(Theme.Font.face(size: 11.5))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }

            Button(action: open) {
                Text(model.s.openImage)
                    .font(Theme.Font.button)
                    .padding(.horizontal, 16)
                    .frame(height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.accent)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.bone.opacity(0.16), lineWidth: 0.5)
                    )
                    .foregroundStyle(Theme.accentInk)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 7) {
                featureLine("wand.and.stars", model.s.featureSmooth)
                featureLine("wand.and.rays", model.s.featureBlemish)
                featureLine("mouth", model.s.featureTeeth)
                featureLine("camera.filters", model.s.featureColor)
                featureLine("hand.draw", model.s.featureZoom)
            }
            .padding(.top, 10)
        }
        .padding(34)
    }

    private func featureLine(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 9) {
            Icon(name: icon, size: 14)
                .foregroundStyle(Theme.accent.opacity(0.85))
                .frame(width: 16)
            Text(text)
                .font(Theme.Font.face(size: 11))
                .foregroundStyle(Theme.muted)
        }
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CompareCanvas: View {
    @ObservedObject var model: EditorModel
    @Binding var isDropTarget: Bool
    @StateObject private var events = CanvasEventMonitor()
    @State private var panStart: CGSize?
    @State private var isPanning = false

    var body: some View {
        ZStack {
            CanvasSurface()

            if let processed = model.previewImage, let original = model.originalImage {
                editor(processed: processed, original: original)
            } else {
                DropZone(model: model) { model.openImage() }
            }
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
            events.start()
        }
        .onDisappear { events.stop() }
        .overlay(alignment: .bottom) {
            if model.hasImage {
                statusBar.padding(.bottom, 12)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.hasImage {
                zoomControls.padding(12)
            }
        }
        .overlay(alignment: .topLeading) {
            if model.hasImage && model.compareEnabled {
                compareBadges.padding(12)
            }
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [9, 6]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let itemURL = item as? URL {
                    url = itemURL
                }
                guard let url else { return }
                DispatchQueue.main.async { model.load(url: url) }
            }
            return true
        }
    }

    // MARK: - Canvas

    private func editor(processed: NSImage, original: NSImage) -> some View {
        GeometryReader { geometry in
            let canvas = geometry.size
            let displayed = model.displayedCanvasSize
            let center = CGPoint(x: canvas.width / 2 + model.panOffset.width,
                                 y: canvas.height / 2 + model.panOffset.height)

            ZStack {
                // A soft drop shadow makes the photo read as a sheet lying on
                // the surface, the way Photos and Preview present an image.
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.black.opacity(0.60))
                    .frame(width: displayed.width, height: displayed.height)
                    .position(x: center.x, y: center.y + 4)
                    .blur(radius: 10)
                    .opacity(model.zoom > 1.0001 ? 0 : 1)
                    .allowsHitTesting(false)

                Image(nsImage: processed)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: displayed.width, height: displayed.height)
                    .position(center)

                if model.compareEnabled {
                    Image(nsImage: original)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: displayed.width, height: displayed.height)
                        .clipShape(PartialRect(fraction: model.comparePosition))
                        .position(center)

                    compareHandle(displayed: displayed, canvas: canvas, center: center)
                }

                if model.showFaceOverlay {
                    FaceOverlayView(faces: model.faces)
                        .frame(width: displayed.width, height: displayed.height, alignment: .topLeading)
                        .position(center)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: canvas.width, height: canvas.height)
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

    /// Split line plus its drag handle. Only this control moves the before/after
    /// boundary.
    private func compareHandle(displayed: CGSize, canvas: CGSize, center: CGPoint) -> some View {
        let x = center.x - displayed.width / 2 + displayed.width * CGFloat(model.comparePosition)
        let lineHeight = max(displayed.height, canvas.height)

        return ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.85))
                .frame(width: 1.5, height: lineHeight)

            ZStack {
                Circle()
                    .fill(.regularMaterial)
                    .frame(width: 34, height: 34)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1))
                    .shadow(color: .black.opacity(0.30), radius: 5, y: 1)
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.8))
            }
        }
        // The frame, hit area and gesture must all be established BEFORE
        // .position(). Applying .contentShape after .position() puts the hit
        // area at the canvas origin instead of on the handle, which is why the
        // handle could not be grabbed.
        .frame(width: 46, height: lineHeight)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard displayed.width > 0 else { return }
                    // value.location is already in this 46-wide strip's local
                    // space, so convert back to canvas space before solving for
                    // the fraction.
                    let localX = value.location.x
                    let canvasX = x - 23 + localX
                    let left = center.x - displayed.width / 2
                    let fraction = (canvasX - left) / displayed.width
                    model.comparePosition = min(1, max(0, Double(fraction)))
                }
        )
        .position(x: x, y: center.y)
    }

    // MARK: - Chrome

    private var compareBadges: some View {
        HStack(spacing: 6) {
            Text(model.s.before)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
            Text(model.s.after)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .allowsHitTesting(false)
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button { model.zoomOut() } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(model.zoom <= 1.0001)
            .help(model.s.zoomOut)

            Text(model.zoom > 1.0001 ? "\(Int((model.zoom * 100).rounded()))%" : model.s.fit)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 50)
                .foregroundStyle(model.zoom > 1.0001 ? Color.accentColor : Color.secondary)

            Button { model.zoomIn() } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(model.zoom >= model.effectiveMaxZoom - 0.001)
            .help(model.s.zoomIn)

            Divider().frame(height: 14)

            Button { model.resetView() } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(model.zoom <= 1.0001)
            .help(model.s.fitToWindow)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .help(model.s.canvasHelp)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.isBusy {
                ProgressView().controlSize(.small)
            }
            Text(model.status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if !model.imageInfo.isEmpty {
                Text("·").foregroundStyle(.quaternary)
                Text(model.imageInfo)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 12)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }
}

/// The recessed dark surface the photo sits on. A very subtle radial lift in
/// the middle keeps it from looking like a flat black hole.
struct CanvasSurface: View {
    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            RadialGradient(colors: [Color.white.opacity(0.045), .clear],
                           center: .center, startRadius: 10, endRadius: 640)
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
                               color: Color.accentColor, lineWidth: 1.5)
                    ForEach(Array(face.eyeRects.enumerated()), id: \.offset) { _, rect in
                        roundedBox(viewRect(rect, in: size), color: .green.opacity(0.85),
                                   lineWidth: 1, dashed: true)
                    }
                    if let lip = face.lipRect {
                        roundedBox(viewRect(lip, in: size), color: .pink.opacity(0.9),
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
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)

            VStack(spacing: 5) {
                Text(model.s.dropTitle)
                    .font(.system(size: 16, weight: .semibold))
                Text(model.s.dropSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Button(action: open) {
                Text(model.s.openImage)
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            VStack(alignment: .leading, spacing: 7) {
                featureLine("sparkles", model.s.featureSmooth)
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
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(Color.accentColor)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

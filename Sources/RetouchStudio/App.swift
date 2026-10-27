import AppKit
import SwiftUI

/// Handles the two things SwiftUI's scene cannot: files opened from Finder or
/// the Open With menu, and the quit prompt for unexported adjustments.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: EditorModel?
    private var pendingURL: URL?

    func attach(model: EditorModel) {
        self.model = model
        // Finder can deliver the open event before the window appears, so an
        // early URL waits here until the model exists.
        if let pendingURL {
            self.pendingURL = nil
            model.requestLoad(url: pendingURL)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
        if let model {
            model.requestLoad(url: url)
        } else {
            pendingURL = url
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasUnsavedChanges else { return .terminateNow }
        return model.confirmDiscardIfNeeded() ? .terminateNow : .terminateCancel
    }
}

/// SwiftUI keeps its window delegate private, so this proxy intercepts the
/// close before AppKit removes the window. Otherwise the prompt would only show
/// up during the termination that follows, leaving a windowless app when the
/// user cancels.
@MainActor
final class EditorWindowDelegate: NSObject, NSWindowDelegate {
    private let model: EditorModel
    private weak var forwarding: NSWindowDelegate?

    init(model: EditorModel, forwarding: NSWindowDelegate?) {
        self.model = model
        self.forwarding = forwarding
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.confirmDiscardIfNeeded() else { return false }
        // The close was approved, so the later termination must not ask again.
        model.discardUnsavedChanges()
        return true
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return forwarding?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if forwarding?.responds(to: aSelector) == true { return forwarding }
        return super.forwardingTarget(for: aSelector)
    }
}

private struct WindowCloseGuard: NSViewRepresentable {
    let model: EditorModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> HookView {
        let view = HookView()
        view.onWindow = { window in
            let delegate = EditorWindowDelegate(model: model, forwarding: window.delegate)
            context.coordinator.retained = delegate
            window.delegate = delegate
        }
        return view
    }

    func updateNSView(_ nsView: HookView, context: Context) {}

    final class Coordinator {
        var retained: EditorWindowDelegate?
    }

    final class HookView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

@main
struct RetouchStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = EditorModel()

    init() {
        // Headless engine check (no UI) for verifying the processing pipeline.
        SelfCheck.runIfRequested()
        // Also behaves like a normal app when launched from a terminal binary.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        // A single window, not a WindowGroup: opening a file from Finder should
        // load it into the editor, not spawn a second window sharing the same
        // model.
        Window(model.s.appName, id: "editor") {
            EditorView(model: model)
                .background(WindowCloseGuard(model: model))
                .onAppear { appDelegate.attach(model: model) }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1320, height: 860)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button(model.s.undoMenu) { model.undo() }
                    .keyboardShortcut("z")
                    .disabled(!model.canUndo)
                Button(model.s.redoMenu) { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
            }
            CommandGroup(replacing: .newItem) {
                Button(model.s.openMenu) { model.openImage() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .newItem) {
                // A single Window scene does not ship the standard Close item.
                Button(model.s.closeWindow) { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w")
            }
            CommandGroup(replacing: .saveItem) {
                Button(model.s.exportMenu) { model.presentExportSheet() }
                    .keyboardShortcut("e")
                    .disabled(!model.hasImage)
            }
            CommandMenu(model.s.retouchMenu) {
                Button(model.s.autoColorMenu) { model.autoColorLight() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(!model.hasImage || model.isBusy)
                Button(model.s.autoRetouchMenu) { model.autoRetouch() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.hasImage || model.isBusy)
                Divider()
                Button(model.s.resetMenu) { model.resetAll() }
                    .keyboardShortcut("r")
                    .disabled(!model.hasImage || model.adjustments.isIdentity)
                Divider()
                Toggle(model.s.showCompareMenu, isOn: $model.compareEnabled)
                Toggle(model.s.showFaceOverlayMenu, isOn: $model.showFaceOverlay)
            }
            CommandGroup(after: .toolbar) {
                Button(model.s.zoomInMenu) { model.zoomIn() }
                    .keyboardShortcut("+")
                    .disabled(!model.hasImage || model.zoom >= model.effectiveMaxZoom - 0.001)
                Button(model.s.zoomOutMenu) { model.zoomOut() }
                    .keyboardShortcut("-")
                    .disabled(!model.hasImage || model.zoom <= 1.0001)
                Button(model.s.fitMenu) { model.resetView() }
                    .keyboardShortcut("0")
                    .disabled(!model.hasImage || model.zoom <= 1.0001)
            }
        }
    }
}

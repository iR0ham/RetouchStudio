import AppKit
import SwiftUI

@main
struct RetouchStudioApp: App {
    @StateObject private var model = EditorModel()

    init() {
        // Headless engine check (no UI) for verifying the processing pipeline.
        SelfCheck.runIfRequested()
        // Also behaves like a normal app when launched from a terminal binary.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup(model.s.appName) {
            EditorView(model: model)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1320, height: 860)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(model.s.openMenu) { model.openImage() }
                    .keyboardShortcut("o")
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

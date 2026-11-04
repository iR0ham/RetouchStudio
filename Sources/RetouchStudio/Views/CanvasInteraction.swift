import AppKit
import SwiftUI

/// رویدادهای چرخ اسکرول و پینچ ترک‌پد را می‌گیرد.
///
/// چرا مونیتور و نه یک NSView؟
///   اگر یک NSView روی بوم بگذاریم، کلیک و درگ هم به آن می‌رسد و
///   حرکت اسلایدر مقایسه و سایر اشاره‌های SwiftUI خراب می‌شود.
///   مونیتور محلی فقط رویدادهای اسکرول/پینچ را برمی‌دارد و کلیک‌ها دست‌نخورده می‌مانند.
final class CanvasEventMonitor: ObservableObject {

    /// نشانگر داخل کادر بوم است؟ تا اسکرول جاهای دیگر برنامه را نگیریم.
    var isPointerInside: Bool = false

    /// (dx, dy, commandPressed, localPoint)
    var onScroll: ((CGFloat, CGFloat, Bool, CGPoint) -> Void)?
    /// (magnificationDelta, localPoint)
    var onMagnify: ((CGFloat, CGPoint) -> Void)?
    /// A bare key press, with any letter or digit it produced. Returns true
    /// when the app used the key, so the monitor can swallow it.
    var onKeyDown: ((String) -> Bool)?
    /// A bare key release, for keys that act while held.
    var onKeyUp: ((String) -> Void)?

    private var scrollMonitor: Any?
    private var magnifyMonitor: Any?
    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?
    private var spaceHeld = false
    private weak var view: NSView?

    func attach(view: NSView?) {
        self.view = view
    }

    func start() {
        guard scrollMonitor == nil else { return }

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.isPointerInside, let point = self.localPoint(event) else { return event }
            if event.modifierFlags.contains(.command) {
                // ⌘ + اسکرول = بزرگ‌نمایی
                self.onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, true, point)
            } else {
                self.onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, false, point)
            }
            return nil
        }

        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            guard let self, self.isPointerInside, let point = self.localPoint(event) else { return event }
            self.onMagnify?(event.magnification, point)
            return nil
        }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.acceptsKeys else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control])
            guard modifiers.isEmpty else { return event }

            // Space is the only key that acts on the way down and up, so it is
            // matched by hardware code rather than by layout-dependent text.
            if event.keyCode == 49 {
                guard !event.isARepeat else { return nil }
                let handled = self.onKeyDown?(" ") == true
                guard handled else { return event }
                self.spaceHeld = true
                return nil
            }

            guard !event.isARepeat else { return event }
            let key = event.charactersIgnoringModifiers ?? ""
            guard !key.isEmpty, self.onKeyDown?(key) == true else { return event }
            return nil
        }

        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self, event.keyCode == 49, self.spaceHeld else { return event }
            self.spaceHeld = false
            self.onKeyUp?(" ")
            return nil
        }
    }

    /// Keys only drive the editor when its own window is key, no sheet is
    /// open and the caret is not in a text field (the look name, for example).
    private var acceptsKeys: Bool {
        guard let window = NSApp.keyWindow,
              window.identifier?.rawValue == "editor",
              window.attachedSheet == nil else { return false }
        return !(window.firstResponder is NSTextView)
    }

    func stop() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        if let magnifyMonitor { NSEvent.removeMonitor(magnifyMonitor) }
        if let keyDownMonitor { NSEvent.removeMonitor(keyDownMonitor) }
        if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
        scrollMonitor = nil
        magnifyMonitor = nil
        keyDownMonitor = nil
        keyUpMonitor = nil
        spaceHeld = false
    }

    private func localPoint(_ event: NSEvent) -> CGPoint? {
        guard let view else { return nil }
        let point = view.convert(event.locationInWindow, from: nil)
        guard view.bounds.contains(point) else { return nil }
        return point
    }

    deinit { stop() }
}

/// فقط برای اینکه به NSView زیرینِ بوم دسترسی داشته باشیم (تبدیل مختصات رویداد).
struct ViewAnchor: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = .clear
        DispatchQueue.main.async { onResolve(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

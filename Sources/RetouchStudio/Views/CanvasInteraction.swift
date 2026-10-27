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

    private var scrollMonitor: Any?
    private var magnifyMonitor: Any?
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
    }

    func stop() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        if let magnifyMonitor { NSEvent.removeMonitor(magnifyMonitor) }
        scrollMonitor = nil
        magnifyMonitor = nil
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

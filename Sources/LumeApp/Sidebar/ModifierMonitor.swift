import SwiftUI
import AppKit

/// Observes whether ⌃ (Control) is currently held and writes it to `pathPeek`.
/// A local `.flagsChanged` monitor is the standard AppKit way to track a held
/// modifier. The monitor is removed when the view disappears.
struct ModifierMonitor: NSViewRepresentable {
    @Binding var pathPeek: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let control = event.modifierFlags.contains(.control)
            Task { @MainActor in pathPeek = control }
            return event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m) }
        coordinator.monitor = nil
    }

    final class Coordinator {
        var monitor: Any?
    }
}

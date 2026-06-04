import SwiftUI
import Quartz

/// Renders `.docx`/office/long-tail formats with QuickLook — no parsing
/// libraries. Read-only. (Images use the native `ImageViewer` instead.)
///
/// IMPORTANT: `QLPreviewView.previewItem` runs a *blocking* load and asserts
/// (`_QLRaiseAssert` → `abort`) if it is assigned before the view is installed
/// in a window. We therefore defer assignment until `view.window != nil`, on the
/// main actor, once the item is materialized.
struct QuickLookViewer: NSViewRepresentable {
    let fileURL: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        load(view, coordinator: context.coordinator)
    }

    @MainActor
    private func load(_ view: QLPreviewView, coordinator: Coordinator) {
        let url = fileURL
        guard coordinator.loadedURL != url else { return }
        coordinator.loadedURL = url

        Task { @MainActor in
            // Wait (bounded, ~1s) for the view to join a window before the
            // blocking-load assignment, otherwise QLPreviewView aborts.
            var tries = 0
            while view.window == nil, tries < 60 {
                try? await Task.sleep(for: .milliseconds(16))
                tries += 1
            }
            guard view.window != nil else { coordinator.loadedURL = nil; return }
            await ICloudCoordinator.ensureDownloaded(url)
            guard view.window != nil, coordinator.loadedURL == url else { return }
            view.previewItem = url as NSURL
        }
    }

    @MainActor
    final class Coordinator {
        var loadedURL: URL?
    }
}

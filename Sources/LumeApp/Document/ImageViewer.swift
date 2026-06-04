import SwiftUI
import AppKit

/// Native image viewer for bitmap/vector formats (jpg/png/gif/heic/tiff/webp/…).
///
/// Replaces QuickLook for images: `QLPreviewView` asserts/aborts when its
/// preview item is assigned before the view is in a window, and a layer-backed
/// `NSImageView` inside a magnifiable `NSScrollView` is faster, lighter, and
/// GPU-composited (Core Animation). Decoding happens off the main thread so the
/// UI never hitches on large files; iCloud placeholders are materialized first.
struct ImageViewer: NSViewRepresentable {
    let fileURL: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 16
        scroll.backgroundColor = .clear
        scroll.drawsBackground = false

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true                 // layer-backed = GPU-composited
        imageView.layer?.contentsGravity = .resizeAspect
        imageView.translatesAutoresizingMaskIntoConstraints = true
        imageView.autoresizingMask = [.width, .height]

        scroll.documentView = imageView
        context.coordinator.imageView = imageView
        load(into: context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Re-decode only when the URL actually changes (the surface is also
        // rebuilt via `.id(url)`, but guard anyway to avoid redundant decodes).
        if context.coordinator.loadedURL != fileURL {
            load(into: context.coordinator)
        }
    }

    @MainActor
    private func load(into coordinator: Coordinator) {
        let url = fileURL
        coordinator.loadedURL = url
        let token = UUID()
        coordinator.token = token

        Task { @MainActor in
            await ICloudCoordinator.ensureDownloaded(url)
            // Read the bytes off the main thread (Data is Sendable, NSImage is
            // not, so we cross the actor boundary with the raw data and build the
            // image on main). The heavy file I/O stays off the UI thread; the
            // layer-backed NSImageView rasterizes on the GPU at draw time.
            let data = await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: url)
            }.value
            // Ignore a stale decode if the user moved on to another file.
            guard coordinator.token == token,
                  let data, let image = NSImage(data: data) else { return }
            coordinator.imageView?.image = image
            coordinator.imageView?.frame.size = image.size
        }
    }

    @MainActor
    final class Coordinator {
        weak var imageView: NSImageView?
        var loadedURL: URL?
        var token: UUID?
    }
}

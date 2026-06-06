import SwiftUI
import AppKit
import ImageIO

/// Native image viewer. Decodes off the main thread and downsamples very large
/// images so opening a huge photo never hangs the UI.
struct ImageViewer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSScrollView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter

        let scrollView = NSScrollView()
        scrollView.documentView = imageView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        context.coordinator.imageView = imageView
        context.coordinator.load(url, fitting: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if context.coordinator.loadedURL != url {
            context.coordinator.load(url, fitting: scrollView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        weak var imageView: NSImageView?
        var loadedURL: URL?

        func load(_ url: URL, fitting scrollView: NSScrollView) {
            loadedURL = url
            let maxPixel = 6144
            Task.detached(priority: .userInitiated) {
                let image = Self.downsampledImage(at: url, maxPixel: maxPixel)
                    ?? NSImage(contentsOf: url)
                await MainActor.run {
                    guard let imageView = self.imageView, self.loadedURL == url else { return }
                    imageView.image = image
                    if let size = image?.size {
                        imageView.frame = NSRect(origin: .zero, size: size)
                    }
                }
            }
        }

        nonisolated static func downsampledImage(at url: URL, maxPixel: Int) -> NSImage? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }
}

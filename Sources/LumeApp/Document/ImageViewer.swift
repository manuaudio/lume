import SwiftUI
import AppKit
import ImageIO

/// Longest-side pixel cap above which a still image is downsampled. Generous
/// enough that ordinary photos load at full resolution (crisp under the scroll
/// view's up-to-16× magnification); only extreme images are capped.
private let imageViewerMaxPixelSize = 6144

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
            // Decode off the main thread so the UI never hitches on large files.
            // Pathologically large STILL images are downsampled via ImageIO (the
            // GPU can't composite a 100-megapixel bitmap cheaply); normal and
            // animated images keep the lazy `NSImage(data:)` path so GIF/HEIC
            // animation and full-resolution zoom are preserved.
            let decoded = await Task.detached(priority: .userInitiated) {
                Self.decode(url)
            }.value
            // Ignore a stale decode if the user moved on to another file.
            guard coordinator.token == token else { return }
            let image: NSImage?
            switch decoded {
            case let .downsampled(box): image = NSImage(cgImage: box.cg, size: box.size)
            case let .full(data): image = NSImage(data: data)
            case .none: image = nil
            }
            guard let image else { return }
            coordinator.imageView?.image = image
            coordinator.imageView?.frame.size = image.size
            coordinator.imageView?.setAccessibilityLabel("Image, \(url.lastPathComponent)")
        }
    }

    /// Off-main decode decision. Reads only metadata first (cheap), then either
    /// downsamples a huge still or returns the raw bytes for a faithful decode.
    private nonisolated static func decode(_ url: URL) -> Decoded? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return .full(data)
        }
        // Animated images (frame count > 1) must keep their frames → full path.
        if CGImageSourceGetCount(source) > 1 { return .full(data) }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard max(w, h) > imageViewerMaxPixelSize else { return .full(data) }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: imageViewerMaxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return .full(data)
        }
        return .downsampled(CGImageBox(cg: cg, size: NSSize(width: cg.width, height: cg.height)))
    }

    /// Decode result crossing the actor boundary. `Data` is Sendable; `CGImage`
    /// is immutable and thread-safe, so the box is safely `@unchecked Sendable`.
    private enum Decoded: @unchecked Sendable {
        case full(Data)
        case downsampled(CGImageBox)
    }

    private struct CGImageBox: @unchecked Sendable {
        let cg: CGImage
        let size: NSSize
    }

    @MainActor
    final class Coordinator {
        weak var imageView: NSImageView?
        var loadedURL: URL?
        var token: UUID?
    }
}

import SwiftUI
import Quartz

/// Renders `.docx`/office/image/long-tail formats with QuickLook — no parsing
/// libraries. Read-only.
struct QuickLookViewer: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        ICloudCoordinator.ensureDownloaded(fileURL)
        view.previewItem = fileURL as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != fileURL {
            ICloudCoordinator.ensureDownloaded(fileURL)
            view.previewItem = fileURL as NSURL
        }
    }
}

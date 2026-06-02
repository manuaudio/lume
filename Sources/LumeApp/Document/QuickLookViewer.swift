import SwiftUI
import Quartz

/// Renders `.docx`/office/image/long-tail formats with QuickLook — no parsing
/// libraries. Read-only.
struct QuickLookViewer: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        load(into: view)
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != fileURL {
            load(into: view)
        }
    }

    private func load(into view: QLPreviewView) {
        let url = fileURL
        ICloudCoordinator.ensureDownloaded(url) { [weak view] in
            view?.previewItem = url as NSURL
        }
    }
}

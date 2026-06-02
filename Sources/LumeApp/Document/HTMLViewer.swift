import SwiftUI
import WebKit

/// Plain content-only web view for `.html` files (distinct from the CodeMirror
/// editor web view). Read-only.
struct HTMLViewer: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        ICloudCoordinator.ensureDownloaded(fileURL)
        view.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url != fileURL {
            ICloudCoordinator.ensureDownloaded(fileURL)
            view.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        }
    }
}

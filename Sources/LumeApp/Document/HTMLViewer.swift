import SwiftUI
import WebKit

/// Plain content-only web view for `.html` files (distinct from the CodeMirror
/// editor web view). Read-only.
struct HTMLViewer: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        load(into: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url != fileURL {
            load(into: view)
        }
    }

    private func load(into view: WKWebView) {
        let url = fileURL
        ICloudCoordinator.ensureDownloaded(url) { [weak view] in
            view?.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }
}

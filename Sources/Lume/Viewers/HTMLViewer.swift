import SwiftUI
import WebKit

/// Plain WKWebView for local HTML content — hardened for untrusted files:
/// content JavaScript is disabled and navigation is restricted to file:// URLs
/// inside the loaded file's own directory (remote navigation is denied).
struct HTMLViewer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Content-only viewing: never execute scripts from arbitrary local files.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        load(url, in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.loadedURL != url {
            load(url, in: webView, coordinator: context.coordinator)
        }
    }

    private func load(_ url: URL, in webView: WKWebView, coordinator: Coordinator) {
        coordinator.loadedURL = url
        coordinator.allowedDirectory = url.deletingLastPathComponent().standardizedFileURL
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?
        var allowedDirectory: URL?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            allows(navigationAction.request.url) ? .allow : .cancel
        }

        /// Only file:// URLs inside the loaded file's directory may navigate
        /// (covers the initial load, in-page anchors, and links to siblings).
        /// http(s), custom schemes, and `../` traversal out of the directory
        /// are all denied.
        private func allows(_ target: URL?) -> Bool {
            guard let target, target.isFileURL, let allowedDirectory else { return false }
            let targetPath = target.standardizedFileURL.path
            let dirPath = allowedDirectory.path
            return targetPath == dirPath || targetPath.hasPrefix(dirPath + "/")
        }
    }
}

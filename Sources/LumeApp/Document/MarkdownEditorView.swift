import SwiftUI
import WebKit
import LumeCore

/// Loads the bundled CodeMirror editor into a `WKWebView`, then hosts a single
/// document. Used by both the editable Markdown surface and the read-only code
/// view (toggled via `editable`).
///
/// The `WKWebView` is created ONCE and reused across document switches: when the
/// selected file changes, `updateNSView` re-inits the editor on the already-loaded
/// page via `bridge.show(...)` instead of letting SwiftUI tear down and rebuild
/// the view. Booting a fresh `WKWebView` (which reloads the ~1.5 MB CodeMirror
/// bundle and waits for a navigation round-trip) on every sidebar click was the
/// dominant cause of click-to-open sluggishness, so the document surface no longer
/// carries an `.id(url)` — reuse depends on a stable identity.
struct MarkdownEditorView: NSViewRepresentable {
    let fileURL: URL
    let editable: Bool
    let model: AppModel

    @Environment(\.colorScheme) private var scheme

    func makeCoordinator() -> EditorBridge { EditorBridge() }

    func makeNSView(context: Context) -> WKWebView {
        let bridge = context.coordinator

        let config = WKWebViewConfiguration()
        config.userContentController.add(bridge, name: "lume")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = bridge
        webView.setValue(false, forKey: "drawsBackground") // let the page bg show through
        bridge.attach(webView)

        // Load the editor shell once. The first document is requested immediately
        // (in parallel with the page load) and flushed by the bridge as soon as
        // the page reports ready — the read and the WebView boot overlap instead
        // of serializing.
        if let base = WebEditorResources.editorURL {
            webView.loadFileURL(base, allowingReadAccessTo: base.deletingLastPathComponent())
        }
        loadDocument(into: bridge)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let bridge = context.coordinator
        bridge.setTheme(dark: scheme == .dark)
        // The selection changed onto a new file (same viewer type → reused view):
        // re-init the editor on the live page rather than rebuilding it.
        if bridge.shownURL != fileURL {
            loadDocument(into: bridge)
        }
    }

    /// Point the bridge at `fileURL`, route its change-writes to that file, and
    /// kick the iCloud-aware read. The read is off the calling frame; a stale
    /// completion (user already moved on) is dropped via the `shownURL` guard.
    private func loadDocument(into bridge: EditorBridge) {
        let url = fileURL
        let editable = self.editable
        let dark = scheme == .dark
        bridge.shownURL = url
        bridge.onChange = editable ? { [model] text in model.write(text, to: url) } : { _ in }
        model.readFile(url) { text in
            guard bridge.shownURL == url else { return }
            bridge.show(text: text, editable: editable, dark: dark)
        }
    }
}

/// Locates the bundled web editor inside `Bundle.module`.
///
/// The `web/` folder is copied verbatim via `.copy("Resources/web")`, so the
/// editor lives at `<bundle>/web/editor.html`. We hand the webview read access
/// to that directory so `dist/editor.bundle.js` and `editor.css` resolve.
enum WebEditorResources {
    static let editorURL: URL? =
        Bundle.module.url(forResource: "editor", withExtension: "html", subdirectory: "web")
}

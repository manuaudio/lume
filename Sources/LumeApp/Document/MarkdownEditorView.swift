import SwiftUI
import WebKit
import LumeCore

/// Loads the bundled CodeMirror editor into a `WKWebView`, then hosts a single
/// document. Used by both the editable Markdown surface and the read-only code
/// view (toggled via `editable`).
struct MarkdownEditorView: NSViewRepresentable {
    let fileURL: URL
    let editable: Bool
    let model: AppModel

    @Environment(\.colorScheme) private var scheme

    func makeCoordinator() -> EditorBridge {
        let bridge = EditorBridge()
        if editable {
            bridge.onChange = { [model] text in
                model.write(text, to: fileURL)
            }
        }
        return bridge
    }

    func makeNSView(context: Context) -> WKWebView {
        let bridge = context.coordinator
        let dark = scheme == .dark

        let config = WKWebViewConfiguration()
        config.userContentController.add(bridge, name: "lume")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = bridge
        webView.setValue(false, forKey: "drawsBackground") // let the page bg show through
        bridge.attach(webView)

        // Push the initial document once the editor page is ready. The read is
        // iCloud-aware and runs off the main thread, so a slow/evicted file does
        // not freeze the UI; the editor loads when the bytes arrive.
        bridge.onReady = { [model] in
            model.readFile(fileURL) { text in
                bridge.load(text: text, editable: editable, dark: dark)
            }
        }

        if let base = WebEditorResources.editorURL {
            webView.loadFileURL(base, allowingReadAccessTo: base.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.setTheme(dark: scheme == .dark)
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

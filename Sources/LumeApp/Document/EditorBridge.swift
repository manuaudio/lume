import Foundation
import WebKit

/// The SwiftUI ↔ CodeMirror (WKWebView) boundary for editable/read-only docs.
///
/// Owns the script-message handler that receives debounced `change` events from
/// the editor, and exposes typed calls (`load`, `setTheme`) that marshal into
/// `window.Lume.*` JavaScript.
final class EditorBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// Called with the editor's full text whenever the document changes.
    var onChange: (String) -> Void = { _ in }

    /// Invoked once the bundled `editor.html` finishes loading, so the caller
    /// can push the initial document text.
    var onReady: () -> Void = {}

    private weak var webView: WKWebView?
    private var didLoadPage = false

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    /// Initialize the CodeMirror editor with text and configuration.
    func load(text: String, editable: Bool, dark: Bool) {
        let js = """
        Lume.init({ text: \(text.asJSStringLiteral), mode: 'markdown', editable: \(editable), theme: '\(dark ? "dark" : "light")' });
        """
        run(js)
    }

    /// Push the active color scheme into the editor in lockstep with SwiftUI.
    func setTheme(dark: Bool) {
        guard didLoadPage else { return }
        run("Lume.setTheme('\(dark ? "dark" : "light")');")
    }

    private func run(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        if type == "change", let text = body["text"] as? String {
            onChange(text)
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didLoadPage = true
        onReady()
    }
}

extension String {
    /// JSON-encode this string so it is safe to embed as a JS string literal,
    /// including the surrounding quotes.
    var asJSStringLiteral: String {
        let data = (try? JSONSerialization.data(withJSONObject: [self])) ?? Data("[\"\"]".utf8)
        let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
        // Strip the surrounding [ ] from the single-element JSON array, leaving
        // the quoted, escaped string literal.
        return String(arr.dropFirst().dropLast())
    }
}

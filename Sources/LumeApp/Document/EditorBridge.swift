import Foundation
import WebKit

/// The SwiftUI ↔ CodeMirror (WKWebView) boundary for editable/read-only docs.
///
/// Owns the script-message handler that receives debounced `change` events from
/// the editor, and exposes typed calls (`show`, `setTheme`) that marshal into
/// `window.Lume.*` JavaScript. The bridge persists for the lifetime of the
/// reused `WKWebView`, so switching documents re-runs `Lume.init` on the
/// already-loaded page instead of booting a fresh web view (see
/// `MarkdownEditorView`).
final class EditorBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// Called with the editor's full text whenever the document changes. Reset by
    /// `MarkdownEditorView` on every document switch so writes always target the
    /// file currently shown.
    var onChange: (String) -> Void = { _ in }

    /// The URL currently shown (or being loaded). Lets `updateNSView` skip a
    /// redundant reload and lets a slow read ignore itself if the user moved on.
    var shownURL: URL?

    private weak var webView: WKWebView?
    private var pageLoaded = false
    /// The document we want shown. Stored until the editor page finishes loading,
    /// then flushed via `Lume.init`. Overwritten by a newer switch so the last
    /// requested document wins.
    private var desired: (text: String, editable: Bool, dark: Bool)?

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    /// Show a document in the editor. Defers until the bundled `editor.html` has
    /// finished loading; once loaded, subsequent calls re-init the editor on the
    /// live page (no navigation, no reload).
    func show(text: String, editable: Bool, dark: Bool) {
        desired = (text, editable, dark)
        flushIfReady()
    }

    /// Push the active color scheme into the editor in lockstep with SwiftUI.
    func setTheme(dark: Bool) {
        guard pageLoaded else { return }
        run("Lume.setTheme('\(dark ? "dark" : "light")');")
    }

    private func flushIfReady() {
        guard pageLoaded, let d = desired else {
            Perf.mark("flushIfReady SKIP (pageLoaded=\(pageLoaded), hasDesired=\(desired != nil))")
            return
        }
        Perf.mark("flushIfReady -> evaluating Lume.init (\(d.text.count) chars)")
        let js = """
        Lume.init({ text: \(d.text.asJSStringLiteral), mode: 'markdown', editable: \(d.editable), theme: '\(d.dark ? "dark" : "light")' });
        """
        run(js)
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
        Perf.mark("WKWebView didFinish (editor.html + 1.5MB bundle loaded)")
        pageLoaded = true
        flushIfReady()
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

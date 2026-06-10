import SwiftUI
import AppKit
import LumeKit

/// A native NSTextView (TextKit 2) wrapped for SwiftUI. Opens instantly and
/// applies lightweight markdown highlighting — no WebView, no JS bundle.
struct EditorView: NSViewRepresentable {
    @Environment(AppState.self) private var app

    func makeCoordinator() -> Coordinator { Coordinator(app: app) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 2 stack: NSTextView created with a layout manager.
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

        // Canonical resizable text view inside a scroll view.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.autohidesScrollers = true
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let incoming = app.documentText ?? ""
        // Only replace storage when the model changed externally (file switch),
        // not on every keystroke — preserves cursor + undo.
        if textView.string != incoming {
            textView.string = incoming
            context.coordinator.clearUndoHistory()
            context.coordinator.highlight(textView)
            // Open a freshly-selected document ready to type — no extra click needed.
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let app: AppState
        weak var textView: NSTextView?
        private var highlightWorkItem: DispatchWorkItem?
        /// Dedicated undo stack for typing. Without it, NSTextView falls back to
        /// the window's undo manager — the file-ops stack — and ⌘Z mid-typing
        /// could re-trash a file instead of undoing keystrokes.
        private let textUndoManager = UndoManager()

        init(app: AppState) { self.app = app }

        /// NSTextView asks its delegate for an undo manager (`allowsUndo`).
        func undoManager(for view: NSTextView) -> UndoManager? { textUndoManager }

        /// Drop typing history when the model replaces the document (file switch).
        func clearUndoHistory() { textUndoManager.removeAllActions() }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            app.documentTextChanged(textView.string)
            // Debounce re-highlighting while typing.
            highlightWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.highlight(textView)
            }
            highlightWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        /// Apply markdown token attributes only when the file is markdown.
        func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            storage.setAttributes([.font: baseFont, .foregroundColor: NSColor.textColor], range: full)

            guard app.selectedKind == .markdown else { return }
            for token in MarkdownHighlighter.tokens(in: textView.string) {
                guard NSMaxRange(token.range) <= storage.length else { continue }
                storage.addAttributes(attributes(for: token.kind, baseFont: baseFont), range: token.range)
            }
        }

        private func attributes(for kind: HighlightKind, baseFont: NSFont) -> [NSAttributedString.Key: Any] {
            switch kind {
            case .heading:
                return [.font: NSFont.monospacedSystemFont(ofSize: 16, weight: .bold),
                        .foregroundColor: NSColor.controlAccentColor]
            case .strong:
                return [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)]
            case .emphasis:
                let italic = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                return [.font: italic]
            case .code:
                return [.foregroundColor: NSColor.systemPink,
                        .backgroundColor: NSColor.textBackgroundColor.blended(withFraction: 0.08, of: .systemGray) ?? .textBackgroundColor]
            case .link:
                return [.foregroundColor: NSColor.linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue]
            }
        }
    }
}

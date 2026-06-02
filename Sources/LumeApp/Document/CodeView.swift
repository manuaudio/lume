import SwiftUI
import LumeCore

/// Read-only syntax-highlighted view for source/code files. Reuses the bundled
/// CodeMirror editor in non-editable mode.
struct CodeView: View {
    let fileURL: URL
    let model: AppModel

    var body: some View {
        MarkdownEditorView(fileURL: fileURL, editable: false, model: model)
    }
}

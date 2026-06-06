import SwiftUI
import LumeKit

/// Native `.env` editor: aligned key = value rows with values masked by default
/// (click the eye to reveal/copy). Edits rebuild the file text, preserving
/// comments and blank lines, and mark the document dirty (⌘S saves).
struct EnvEditorView: View {
    @Environment(AppState.self) private var app

    @State private var lines: [EnvLine] = []
    @State private var revealed: Set<Int> = []
    @State private var lastPushed: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    row(index: index, line: line)
                }
            }
            .padding(16)
        }
        .onAppear { reload() }
        .onChange(of: app.selectedURL) { _, _ in reload() }
        .onChange(of: app.documentText) { _, newText in
            // Re-parse on external loads/file-switches, but ignore our own edits.
            if newText != lastPushed { reload() }
        }
    }

    @ViewBuilder
    private func row(index: Int, line: EnvLine) -> some View {
        switch line {
        case .blank:
            Color.clear.frame(height: 6)
        case let .comment(text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
        case let .entry(entry):
            HStack(spacing: 8) {
                Text(entry.key)
                    .font(.system(.body, design: .monospaced).weight(.medium))
                    .frame(minWidth: 140, alignment: .leading)
                Text("=").foregroundStyle(.tertiary)
                if revealed.contains(index) {
                    TextField("value", text: bindingForValue(index: index, key: entry.key))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                } else {
                    Text(EnvFile.mask(entry.value))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Button {
                    if revealed.contains(index) { revealed.remove(index) } else { revealed.insert(index) }
                } label: {
                    Image(systemName: revealed.contains(index) ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealed.contains(index) ? "Hide value" : "Reveal value")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.value, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy value")
            }
        }
    }

    private func bindingForValue(index: Int, key: String) -> Binding<String> {
        Binding(
            get: {
                if case let .entry(e) = lines[index] { return e.value }
                return ""
            },
            set: { newValue in
                lines[index] = .entry(EnvEntry(key: key, value: newValue))
                let text = serialize()
                lastPushed = text
                app.documentTextChanged(text)
            }
        )
    }

    private func serialize() -> String {
        lines.map { line in
            switch line {
            case .blank: return ""
            case let .comment(c): return c
            case let .entry(e): return "\(e.key)=\(e.value)"
            }
        }.joined(separator: "\n")
    }

    private func reload() {
        revealed.removeAll()
        lines = EnvFile.parse(app.currentText)
        lastPushed = app.documentText
    }
}

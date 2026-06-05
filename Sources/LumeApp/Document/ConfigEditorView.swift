import SwiftUI
import AppKit
import LumeCore

/// Structured, "vibecoder-friendly" editor for config files the `ConfigRegistry`
/// recognizes (JSON today; more formats drop in via the registry). Shows an
/// editable form over the parsed `ConfigValue` tree, with a toggle to the raw
/// source. Edits in either mode write back through the model's coordinated path.
struct ConfigEditorView: View {
    let fileURL: URL
    let format: any ConfigFormat.Type
    let model: AppModel

    @State private var root: ConfigValue?
    @State private var rawText = ""
    @State private var rawMode = false
    @State private var parseError: String?
    /// Set while `reload()` / structured edits assign `rawText` so the
    /// programmatic change doesn't trigger a self-overwriting disk write.
    @State private var isLoading = false
    @State private var writeTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(.background)
        .onAppear {
            rawMode = !model.configShowsStructured(forPath: fileURL.path)
            reload()
        }
        .onChange(of: rawMode) { _, raw in
            model.setConfigShowsStructured(!raw, forPath: fileURL.path)
        }
    }

    @ViewBuilder private var content: some View {
        if rawMode {
            TextEditor(text: $rawText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(12)
                .onChange(of: rawText) { _, new in
                    guard !isLoading else { return }
                    reparse(new)
                    scheduleWrite(new)
                }
        } else if let parseError {
            ContentUnavailableView {
                Label("Can't show structured view", systemImage: "exclamationmark.triangle")
            } description: {
                Text(parseError)
            } actions: {
                Button("Edit raw source") { rawMode = true }
            }
        } else if let root {
            List {
                ConfigNodeEditor(value: root, label: fileURL.lastPathComponent) { updated in
                    apply(updated)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack {
            DocumentHeaderTitle(filename: fileURL.lastPathComponent, systemImage: "curlybraces")
            if parseError != nil, !rawMode {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("Structured view unavailable — invalid \(format.identifier).")
            }
            Spacer()
            Toggle("Raw source", isOn: $rawMode)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .documentHeaderBar()
    }

    private func reload() {
        isLoading = true
        model.readFile(fileURL) { text in
            rawText = text
            reparse(text)
            isLoading = false
        }
    }

    private func reparse(_ text: String) {
        do {
            root = try format.parse(text)
            parseError = nil
        } catch {
            parseError = (error as? ConfigParseError)?.message ?? "\(error)"
        }
    }

    /// A structured edit: update the tree, re-serialize, mirror into rawText, and
    /// schedule a write. `isLoading` guards the rawText assignment.
    private func apply(_ updated: ConfigValue) {
        root = updated
        guard let text = try? format.serialize(updated) else { return }
        isLoading = true
        rawText = text
        isLoading = false
        scheduleWrite(text)
    }

    /// Debounce writes (~400ms), matching EnvView / the Markdown editor.
    private func scheduleWrite(_ text: String) {
        writeTask?.cancel()
        writeTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            model.write(text, to: fileURL)
        }
    }
}

/// Recursive editor for one `ConfigValue` node. Leaf scalars are editable;
/// objects/arrays nest under disclosure rows. Any change rebuilds this node and
/// bubbles it up via `onChange` so the root re-serializes.
private struct ConfigNodeEditor: View {
    let value: ConfigValue
    let label: String
    let onChange: (ConfigValue) -> Void

    var body: some View {
        switch value {
        case let .object(entries):
            DisclosureGroup(label) {
                ForEach(Array(entries.enumerated()), id: \.offset) { idx, entry in
                    ConfigNodeEditor(value: entry.value, label: entry.key) { child in
                        var copy = entries
                        copy[idx].value = child
                        onChange(.object(copy))
                    }
                }
            }
        case let .array(items):
            DisclosureGroup("\(label) [\(items.count)]") {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    ConfigNodeEditor(value: item, label: "\(idx)") { child in
                        var copy = items
                        copy[idx] = child
                        onChange(.array(copy))
                    }
                }
            }
        default:
            ConfigLeafRow(label: label, value: value, onChange: onChange)
        }
    }
}

/// One editable scalar row: string/number text field, bool toggle, or null.
private struct ConfigLeafRow: View {
    let label: String
    let value: ConfigValue
    let onChange: (ConfigValue) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(.body, design: .monospaced).weight(.semibold))
            Spacer(minLength: 16)
            editor
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var editor: some View {
        switch value {
        case let .string(s):
            TextField("", text: Binding(get: { s }, set: { onChange(.string($0)) }))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .accessibilityLabel(label)
        case let .number(n):
            TextField("", text: Binding(get: { n }, set: { onChange(.number($0)) }))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 140)
                .font(.system(.body, design: .monospaced))
                .accessibilityLabel(label)
        case let .bool(b):
            Toggle("", isOn: Binding(get: { b }, set: { onChange(.bool($0)) }))
                .labelsHidden()
                .accessibilityLabel(label)
        case .null:
            Text("null").foregroundStyle(.tertiary).italic()
        case .object, .array:
            EmptyView() // handled by ConfigNodeEditor
        }
    }
}

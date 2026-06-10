import SwiftUI
import LumeKit

/// Structured editor for JSON/YAML/TOML/plist via ConfigKit. Shows a form of
/// keys and leaf values (editable), with a Raw toggle that drops to the plain
/// text editor. Leaf edits re-serialize and mark the document dirty (⌘S saves).
struct ConfigEditorView: View {
    @Environment(AppState.self) private var app

    @State private var root: ConfigValue = .null
    @State private var parseError: String?
    @State private var raw = false
    @State private var lastPushed: String?
    @State private var suppressPush = false

    private var format: (any ConfigFormat.Type)? {
        guard let name = app.selectedURL?.lastPathComponent else { return nil }
        return ConfigRegistry.format(forFilename: name)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(app.selectedURL?.lastPathComponent ?? "")
                    .font(.headline)
                Spacer()
                Picker("", selection: $raw) {
                    Text("Structured").tag(false)
                    Text("Raw").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .disabled(parseError != nil && !raw)
            }
            .padding(10)
            Divider()

            if raw {
                EditorView()
            } else if let parseError {
                ContentUnavailableView {
                    Label("Can't Parse", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(parseError)
                } actions: {
                    Button("Edit Raw") { raw = true }
                }
            } else {
                ScrollView {
                    ConfigNodeView(value: $root, label: nil)
                        .padding(14)
                }
            }
        }
        .onAppear { applyDefaultRaw(); reload() }
        .onChange(of: app.selectedURL) { _, _ in applyDefaultRaw(); reload() }
        .onChange(of: app.documentText) { _, newText in
            if newText != lastPushed { reload() }
        }
        .onChange(of: root) { _, _ in reserialize() }
        .onChange(of: raw) { _, newRaw in
            if let path = app.selectedURL?.path { app.setConfigShowsRaw(newRaw, forPath: path) }
        }
    }

    /// Initialize the Structured/Raw choice from the per-file override or the
    /// global default (View ▸ Structured Config Editor).
    private func applyDefaultRaw() {
        guard let path = app.selectedURL?.path else { return }
        raw = app.configShowsRaw(forPath: path)
    }

    private func reload() {
        guard let format else { parseError = "Unsupported config format."; return }
        do {
            let parsed = try format.parse(app.currentText)
            suppressPush = true
            root = parsed
            lastPushed = app.documentText
            parseError = nil
            DispatchQueue.main.async { suppressPush = false }
        } catch {
            parseError = "\(error)"
            raw = true
        }
    }

    private func reserialize() {
        guard !suppressPush, !raw, let format else { return }
        if let text = try? format.serialize(root) {
            lastPushed = text
            app.documentTextChanged(text)
        }
    }
}

/// Recursive view over a ConfigValue. Objects/arrays disclose; leaves edit.
private struct ConfigNodeView: View {
    @Binding var value: ConfigValue
    let label: String?

    var body: some View {
        switch value {
        case .object(let entries):
            container {
                ForEach(entries.indices, id: \.self) { i in
                    ConfigNodeView(value: entryBinding(i), label: entries[i].key)
                }
            }
        case .array(let items):
            container {
                ForEach(items.indices, id: \.self) { i in
                    ConfigNodeView(value: arrayBinding(i), label: "[\(i)]")
                }
            }
        case .string(let s):
            leaf {
                TextField("", text: Binding(get: { s }, set: { value = .string($0) }))
                    .textFieldStyle(.roundedBorder)
            }
        case .number(let n):
            leaf {
                TextField("", text: Binding(get: { n }, set: { value = .number($0) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
            }
        case .bool(let b):
            leaf {
                Toggle("", isOn: Binding(get: { b }, set: { value = .bool($0) })).labelsHidden()
            }
        case .date(let d):
            leaf {
                TextField("", text: Binding(get: { d }, set: { value = .date($0) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
            }
        case .data(let d):
            // Binary payloads aren't editable inline; show the base64 read-only.
            leaf {
                Text(d)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .null:
            leaf { Text("null").foregroundStyle(.tertiary) }
        }
    }

    @ViewBuilder
    private func container<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        if let label {
            DisclosureGroup(label) { VStack(alignment: .leading, spacing: 6, content: content) }
        } else {
            VStack(alignment: .leading, spacing: 6, content: content)
        }
    }

    @ViewBuilder
    private func leaf<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        HStack(spacing: 8) {
            if let label {
                Text(label)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 140, alignment: .leading)
            }
            content()
            Spacer(minLength: 0)
        }
    }

    private func entryBinding(_ i: Int) -> Binding<ConfigValue> {
        Binding(
            get: {
                guard case let .object(entries) = value, entries.indices.contains(i) else { return .null }
                return entries[i].value
            },
            set: { newValue in
                guard case var .object(entries) = value, entries.indices.contains(i) else { return }
                entries[i] = ConfigEntry(key: entries[i].key, value: newValue)
                value = .object(entries)
            }
        )
    }

    private func arrayBinding(_ i: Int) -> Binding<ConfigValue> {
        Binding(
            get: {
                guard case let .array(items) = value, items.indices.contains(i) else { return .null }
                return items[i]
            },
            set: { newValue in
                guard case var .array(items) = value, items.indices.contains(i) else { return }
                items[i] = newValue
                value = .array(items)
            }
        )
    }
}

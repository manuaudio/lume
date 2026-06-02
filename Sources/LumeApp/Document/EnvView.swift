import SwiftUI
import AppKit
import LumeCore

/// Native `.env` viewer: masked key=value rows with per-row reveal/copy, plus a
/// raw-edit mode that writes back to disk.
struct EnvView: View {
    let fileURL: URL
    let model: AppModel

    @State private var lines: [EnvLine] = []
    @State private var revealed: Set<String> = []
    @State private var rawMode = false
    @State private var rawText = ""

    private var entries: [EnvEntry] { EnvFile.entries(from: lines) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if rawMode {
                TextEditor(text: $rawText)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .onChange(of: rawText) { _, new in
                        model.write(new, to: fileURL)
                    }
            } else if entries.isEmpty {
                ContentUnavailableView("No variables", systemImage: "key",
                                       description: Text("This .env file has no KEY=VALUE entries."))
            } else {
                List {
                    ForEach(entries, id: \.key) { entry in
                        EnvRow(
                            entry: entry,
                            isRevealed: revealed.contains(entry.key),
                            onToggle: { toggle(entry.key) },
                            onCopy: { copy(entry.value) }
                        )
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(.background)
        .onAppear(perform: reload)
    }

    private var header: some View {
        HStack {
            Label(fileURL.lastPathComponent, systemImage: "key.fill")
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("Edit raw", isOn: $rawMode)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private func reload() {
        rawText = model.readFile(fileURL)
        lines = EnvFile.parse(rawText)
    }

    private func toggle(_ key: String) {
        if revealed.contains(key) { revealed.remove(key) } else { revealed.insert(key) }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct EnvRow: View {
    let entry: EnvEntry
    let isRevealed: Bool
    let onToggle: () -> Void
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.key)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 16)

            Text(isRevealed ? (entry.value.isEmpty ? "—" : entry.value) : EnvFile.mask(entry.value))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button(isRevealed ? "Hide value" : "Reveal value",
                   systemImage: isRevealed ? "eye.slash" : "eye",
                   action: onToggle)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(isRevealed ? "Hide value" : "Reveal value")

            Button("Copy value", systemImage: "doc.on.doc", action: onCopy)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Copy value")
        }
        .padding(.vertical, 4)
    }
}

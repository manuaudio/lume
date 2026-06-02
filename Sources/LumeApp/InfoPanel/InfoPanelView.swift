import SwiftUI
import SwiftData
import LumeCore

/// Right pane: edit tags + free-text notes for the selected file's metadata.
/// Works for any file kind (you can tag a PDF or docx, not just Markdown).
struct InfoPanelView: View {
    let model: AppModel

    @Environment(\.modelContext) private var context
    @State private var name = ""
    @State private var tagsText = ""
    @State private var notes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let url = model.selectedFile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        fileSummary(url)
                        nameSection(url)
                        tagsSection
                        notesSection
                    }
                    .padding(16)
                }

                Divider()
                HStack {
                    Spacer()
                    Button("Save") { save(url: url) }
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                }
                .padding(12)
            } else {
                ContentUnavailableView("No selection", systemImage: "tag",
                                       description: Text("Select a file to view and edit its tags and notes."))
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .onChange(of: model.selectedFile) { _, _ in load() }
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack {
            Label("Info", systemImage: "info.circle")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func fileSummary(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name.isEmpty ? url.lastPathComponent : name)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .truncationMode(.middle)
            Text(name.isEmpty
                 ? url.deletingLastPathComponent().path
                 : url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func nameSection(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DISPLAY NAME")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(url.lastPathComponent, text: $name)
                .textFieldStyle(.roundedBorder)
            Text("A friendly label shown in the sidebar (e.g. name a .env so you can tell them apart).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TAGS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("work, invoice", text: $tagsText)
                .textFieldStyle(.roundedBorder)
            Text("Comma-separated")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NOTES")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Add notes…", text: $notes, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(6...)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.quaternary)
                )
        }
    }

    // MARK: Persistence

    private func store() -> LibraryStore { LibraryStore(context: context) }

    private func load() {
        guard let url = model.selectedFile, let meta = store().meta(for: url.path) else {
            name = ""
            tagsText = ""
            notes = ""
            return
        }
        name = meta.displayName
        tagsText = meta.tags.map(\.name).joined(separator: ", ")
        notes = meta.info
    }

    private func save(url: URL) {
        let names = tagsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        store().setMeta(path: url.path, info: notes, tagNames: names,
                        displayName: name.trimmingCharacters(in: .whitespaces))
    }
}

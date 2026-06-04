import SwiftUI
import SwiftData
import LumeCore
import LumeUI

/// Pillar ①: the collapsible tag header at the top of the document pane. Shared
/// across all file types (markdown, code, env, pdf, html, quicklook). Renders the
/// selected file's tags as removable/recolorable chips and an "+ add tag"
/// autocomplete popover. Persists through `LibraryStore.setMeta`, preserving the
/// file's existing `info` (notes) and `displayName`. Orphan pruning runs inside
/// `setMeta`, so removing a tag's last file auto-cleans the vocabulary.
struct DocumentTagHeader: View {
    let url: URL
    let model: AppModel

    @Environment(\.modelContext) private var context
    @Query(sort: \Tag.name) private var allTags: [Tag]
    @State private var tagNames: [String] = []
    @State private var loaded = false
    @State private var addingTag = false
    @State private var showingNotes = false

    /// Live color for a tag name from the reactive @Query (0 until first saved).
    private func colorIndex(_ name: String) -> Int {
        allTags.first { $0.name == name }?.colorIndex ?? 0
    }

    private var parentPath: String {
        url.deletingLastPathComponent().path
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // Left: filename + faint parent path.
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(parentPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .layoutPriority(1)

            // Center: chips + add control.
            FlowLayout(spacing: 6) {
                ForEach(tagNames, id: \.self) { name in
                    TagChip(name: name,
                            colorIndex: colorIndex(name),
                            onRemove: { remove(name) },
                            onRecolor: { idx in recolor(name, idx) })
                }
                addButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right: notes + collapse.
            HStack(spacing: 8) {
                Button {
                    showingNotes.toggle()
                } label: {
                    Image(systemName: "note.text")
                }
                .buttonStyle(.borderless)
                .help("Notes")
                .popover(isPresented: $showingNotes, arrowEdge: .bottom) {
                    DocumentNotesPopover(url: url)
                }

                Button {
                    model.showEditorTags = false
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .help("Hide tag header")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear(perform: load)
        .onChange(of: url) { _, _ in loaded = false; load() }
        .onChange(of: allTags) { _, _ in reloadFromStore() }
    }

    private var addButton: some View {
        Button { addingTag = true } label: {
            HStack(spacing: 3) {
                Image(systemName: "plus")
                Text("add tag")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(.quaternary))
        }
        .buttonStyle(.plain)
        .help("Add a tag")
        .popover(isPresented: $addingTag, arrowEdge: .bottom) {
            TagAddPopover(existingOnFile: tagNames) { name in
                add(name)
            }
        }
    }

    // MARK: Data

    private func load() {
        guard !loaded else { return }
        let store = LibraryStore(context: context)
        tagNames = store.meta(for: url.path)?.tags.map(\.name) ?? []
        loaded = true
    }

    /// Re-derive the file's tag membership from the store when the reactive tag
    /// vocabulary changes (rename/delete/orphan-prune elsewhere). Tag add/remove
    /// persists immediately, so the store is the source of truth — there is no
    /// unsaved local tag state to clobber, so this is safe to run on any change.
    private func reloadFromStore() {
        let store = LibraryStore(context: context)
        tagNames = store.meta(for: url.path)?.tags.map(\.name) ?? []
    }

    /// Persist the current `tagNames`, preserving the file's existing notes/info
    /// and displayName (spec requirement: never clobber them).
    private func persist() {
        let store = LibraryStore(context: context)
        let existing = store.meta(for: url.path)
        store.setMeta(path: url.path,
                      info: existing?.info ?? "",
                      tagNames: tagNames,
                      displayName: existing?.displayName ?? "")
    }

    private func add(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !tagNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return }
        tagNames.append(trimmed)
        persist()
    }

    private func remove(_ name: String) {
        tagNames.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        persist()   // setMeta auto-prunes the tag if this was its last file
    }

    private func recolor(_ name: String, _ idx: Int) {
        // Make sure the tag exists in the store before recoloring (a just-added
        // tag is already persisted by `add`, but be defensive).
        persist()
        LibraryStore(context: context).recolorTag(named: name, colorIndex: idx)
    }
}

/// A minimal per-file notes popover opened by the header's 🗒 button. Loads the
/// file's notes from `FileMeta.info` (via `LibraryStore.meta(for:)`) and saves
/// edits through the SAME `setMeta(path:info:tagNames:displayName:)` path the
/// header uses — writing the edited notes into `info` while preserving the
/// file's existing `tagNames` and `displayName`, so notes and tags never clobber
/// each other. Scoped and simple by design: a focused `TextEditor` plus an
/// explicit Save. Persisting through `setMeta` keeps the reactive @Query-backed
/// chips and the sidebar in sync (and runs the usual orphan prune).
struct DocumentNotesPopover: View {
    let url: URL

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var notes = ""
    @State private var loaded = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $notes)
                .font(.callout)
                .focused($focused)
                .frame(width: 280, height: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.quaternary)
                )
            HStack {
                Spacer()
                Button("Done") { save(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        notes = LibraryStore(context: context).meta(for: url.path)?.info ?? ""
        loaded = true
    }

    /// Save the edited notes into `info`, preserving the file's existing tags and
    /// displayName (read fresh so a tag added while the popover was open isn't lost).
    private func save() {
        let store = LibraryStore(context: context)
        let existing = store.meta(for: url.path)
        store.setMeta(path: url.path,
                      info: notes,
                      tagNames: existing?.tags.map(\.name) ?? [],
                      displayName: existing?.displayName ?? "")
    }
}

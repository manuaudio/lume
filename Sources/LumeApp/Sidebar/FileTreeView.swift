import AppKit
import SwiftUI
import LumeCore

/// Lazily lists the children of `parent`, honoring files-only + tag filter.
struct FileTreeView: View {
    let parent: URL
    let model: AppModel
    var names: [String: String] = [:]
    var depth: Int = 0

    @State private var children: [FileNode] = []

    var body: some View {
        ForEach(visibleChildren) { node in
            SidebarItemRow(url: node.url, isDirectory: node.isDirectory,
                           section: .browser, depth: depth,
                           model: model, names: names)
                .tag(SidebarRow(url: node.url, isDirectory: node.isDirectory,
                                section: .browser).id)

            if node.isDirectory, model.expandedPaths.contains(node.url.path) {
                FileTreeView(parent: node.url, model: model, names: names, depth: depth + 1)
            }
        }
        .onAppear { reload() }
        .onChange(of: parent) { _, _ in reload() }
    }

    private var visibleChildren: [FileNode] {
        var nodes = children
        if model.filesOnly { nodes = nodes.filter { !$0.isDirectory } }
        if let tag = model.activeTagFilter {
            let allowed = model.store?.paths(taggedWith: tag) ?? []
            // Keep directories (so you can navigate into them) + tagged files.
            nodes = nodes.filter { $0.isDirectory || allowed.contains($0.url.path) }
        }
        if !model.browseFilter.isEmpty {
            nodes = nodes.filter { $0.isDirectory || $0.name.localizedCaseInsensitiveContains(model.browseFilter) }
        }
        return nodes
    }

    private func reload() {
        children = model.children(of: parent)
    }
}

/// One selectable file/folder row. Single-click a folder toggles inline
/// expansion; double-click drills in. Files select (SidebarView opens them).
struct SidebarItemRow: View {
    let url: URL
    let isDirectory: Bool
    let section: SidebarSection
    var depth: Int = 0
    let model: AppModel
    var names: [String: String] = [:]

    private var isExpanded: Bool { model.expandedPaths.contains(url.path) }
    private var isRenaming: Bool { model.renamingPath == url.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if isDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 12)
                        .onTapGesture { model.toggleExpanded(url) }
                } else {
                    Spacer().frame(width: 12)
                }

                if isRenaming {
                    RenameField(url: url, model: model)
                } else if isDirectory {
                    Label(names[url.path] ?? url.lastPathComponent,
                          systemImage: section == .pinned ? "folder.fill" : "folder")
                        .foregroundStyle(section == .pinned ? .yellow : .primary)
                        .lineLimit(1)
                } else {
                    FileRow(url: url,
                            kind: FileKind.detect(filename: url.lastPathComponent),
                            name: names[url.path])
                }
                Spacer(minLength: 0)
            }
            if !isDirectory, model.selectedFile == url, !isRenaming {
                RowMetaView(url: url, model: model)
            }
        }
        .padding(.leading, CGFloat(depth) * 12)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard isDirectory else { return }
            model.expandedPaths.remove(url.path)   // undo the single-tap's pending expand
            model.drillInto(url)
        }
        .onTapGesture(count: 1) { if isDirectory { model.toggleExpanded(url) } else { model.selectedFile = url } }
        .contextMenu { RowMenu(url: url, isDirectory: isDirectory, model: model) }
    }
}

/// A leaf file row: kind-tinted icon + middle-truncated name.
struct FileRow: View {
    let url: URL
    let kind: FileKind
    var name: String? = nil

    var body: some View {
        Label {
            Text(name ?? url.lastPathComponent).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: icon(for: kind))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint(for: kind))
        }
    }

    private func icon(for kind: FileKind) -> String {
        switch kind {
        case .markdown: return "doc.text"
        case .env: return "key.fill"
        case .pdf: return "doc.richtext"
        case .previewable: return "doc"
        case .html: return "globe"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .unsupported: return "questionmark.square.dashed"
        }
    }

    private func tint(for kind: FileKind) -> Color {
        switch kind {
        case .markdown: return .blue
        case .env: return .orange
        case .pdf: return .red
        case .html: return .teal
        case .code: return .purple
        case .previewable, .unsupported: return .secondary
        }
    }
}

/// Shared right-click menu for any sidebar row.
struct RowMenu: View {
    let url: URL
    let isDirectory: Bool
    let model: AppModel

    var body: some View {
        if isDirectory {
            Button("Open", systemImage: "arrow.right.circle") { model.drillInto(url) }
            Button("Expand / Collapse", systemImage: "chevron.right") { model.toggleExpanded(url) }
        } else {
            Button("Open", systemImage: "doc.text") { model.selectedFile = url }
        }
        Divider()
        let pinned = model.isPinned(url)
        Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
            model.togglePin(url, isDirectory: isDirectory)
        }
        Button("Rename…", systemImage: "pencil") { model.renamingPath = url.path }
        Button("Edit Tags / Notes…", systemImage: "tag") {
            model.selectedFile = url
            model.notesOpenPath = url.path
        }
        Divider()
        Button("Reveal in Finder", systemImage: "magnifyingglass") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

/// In-place display-name editor shown on the row being renamed.
struct RenameField: View {
    let url: URL
    let model: AppModel

    @Environment(\.modelContext) private var context
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear {
                text = model.store?.displayName(for: url.path) ?? url.lastPathComponent
                focused = true
            }
            .onSubmit { commit() }
            .onExitCommand { model.renamingPath = nil }   // Esc cancels
            .onChange(of: focused) { _, f in if !f && model.renamingPath == url.path { commit() } }
    }

    private func commit() {
        let store = LibraryStore(context: context)
        let meta = store.meta(for: url.path)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Preserve existing notes/tags; only the display name changes here.
        store.setMeta(path: url.path,
                      info: meta?.info ?? "",
                      tagNames: meta?.tags.map(\.name) ?? [],
                      displayName: trimmed == url.lastPathComponent ? "" : trimmed)
        model.renamingPath = nil
    }
}

/// Tag chips + collapsible notes for the selected file, shown beneath its row.
struct RowMetaView: View {
    let url: URL
    let model: AppModel

    @Environment(\.modelContext) private var context
    @State private var tagsText = ""
    @State private var notes = ""
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?

    private static let saveDebounce = Duration.milliseconds(400)

    private var notesOpen: Bool { model.notesOpenPath == url.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                TextField("add tags (comma-separated)", text: $tagsText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit { save() }
                    .onChange(of: tagsText) { _, _ in scheduleSave() }
                Button {
                    model.notesOpenPath = notesOpen ? nil : url.path
                } label: {
                    Image(systemName: notesOpen ? "note.text" : "note.text.badge.plus")
                }
                .buttonStyle(.borderless)
                .help(notesOpen ? "Hide notes" : "Add notes")
            }
            if notesOpen {
                TextField("Notes…", text: $notes, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .lineLimit(3...8)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    .onChange(of: notes) { _, _ in scheduleSave() }   // debounced autosave
            }
        }
        .padding(.leading, 18)
        .padding(.vertical, 2)
        .onAppear(perform: load)
        .onDisappear { saveTask?.cancel(); save() }
        .onChange(of: url) { _, _ in saveTask?.cancel(); loaded = false; load() }
    }

    private func load() {
        guard !loaded else { return }
        let store = LibraryStore(context: context)
        let meta = store.meta(for: url.path)
        tagsText = meta?.tags.map(\.name).joined(separator: ", ") ?? ""
        notes = meta?.info ?? ""
        loaded = true
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: Self.saveDebounce)
            if Task.isCancelled { return }
            save()
        }
    }

    private func save() {
        let store = LibraryStore(context: context)
        let tagNames = tagsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        store.setMeta(path: url.path, info: notes, tagNames: tagNames,
                      displayName: store.displayName(for: url.path) ?? "")
    }
}

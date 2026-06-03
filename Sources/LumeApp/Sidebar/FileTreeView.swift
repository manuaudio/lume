import AppKit
import SwiftUI
import LumeCore

/// Lazily lists the children of `parent`, honoring files-only + tag filter.
struct FileTreeView: View {
    let parent: URL
    let model: AppModel
    var names: [String: String] = [:]
    let hiddenPaths: Set<String>
    let section: SidebarSection
    var depth: Int = 0

    @State private var children: [FileNode] = []

    var body: some View {
        ForEach(visibleChildren) { node in
            SidebarItemRow(url: node.url, isDirectory: node.isDirectory,
                           section: section, depth: depth,
                           model: model, names: names,
                           hiddenPaths: hiddenPaths)
                .tag(SidebarRow(url: node.url, isDirectory: node.isDirectory,
                                section: section).id)

            if node.isDirectory, model.expandedPaths.contains(node.url.path) {
                FileTreeView(parent: node.url, model: model, names: names,
                             hiddenPaths: hiddenPaths, section: section, depth: depth + 1)
            }
        }
        .onAppear { reload() }
        .onChange(of: parent) { _, _ in reload() }
    }

    private var visibleChildren: [FileNode] {
        var nodes = children
        if model.filesOnly { nodes = nodes.filter { !$0.isDirectory } }
        if !model.showHidden {
            nodes = nodes.filter { !hiddenPaths.contains($0.url.path) }
        }
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
    var hiddenPaths: Set<String> = []

    private var isExpanded: Bool { model.expandedPaths.contains(url.path) }
    private var isRenaming: Bool { model.renamingPath == url.path }
    private var isHidden: Bool { hiddenPaths.contains(url.path) }

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
                    RenameField(url: url, model: model,
                                autoName: section == .pinned ? DisplayName.autoName(for: url) : nil)
                } else if isDirectory {
                    Label(names[url.path] ?? url.lastPathComponent,
                          systemImage: section == .pinned ? "folder.fill" : "folder")
                        .foregroundStyle(section == .pinned ? .yellow : .primary)
                        .lineLimit(1)
                } else {
                    FileRow(url: url,
                            kind: FileKind.detect(filename: url.lastPathComponent),
                            name: names[url.path],
                            autoName: section == .pinned ? DisplayName.autoName(for: url) : nil)
                }
                Spacer(minLength: 0)
                if model.showHidden, isHidden {
                    Button { model.unhide(url) } label: { Image(systemName: "eye") }
                        .buttonStyle(.borderless)
                        .help("Un-hide")
                }
            }
            .opacity(isHidden ? 0.45 : 1)
            if !isDirectory, model.selectedFile == url, !isRenaming {
                RowMetaView(url: url, model: model)
            }
        }
        .padding(.leading, CGFloat(depth) * 12)
        .contentShape(Rectangle())
        .draggable(url)
        .onTapGesture(count: 2) {
            guard isDirectory else { return }
            model.expandedPaths.remove(url.path)   // undo the single-tap's pending expand
            model.drillInto(url)
        }
        .onTapGesture(count: 1) { if isDirectory { model.toggleExpanded(url) } else { model.selectedFile = url } }
        .contextMenu {
            RowMenu(url: url,
                    isDirectory: isDirectory,
                    rowID: SidebarRow(url: url, isDirectory: isDirectory, section: section).id,
                    hiddenPaths: hiddenPaths,
                    model: model)
        }
    }
}

/// A leaf file row: kind-tinted icon + effective name, with the real filename
/// shown muted alongside whenever the label differs from it.
struct FileRow: View {
    let url: URL
    let kind: FileKind
    var name: String? = nil       // user override (FileMeta.displayName), if any
    var autoName: String? = nil   // parent-folder auto-name (Pinned context only)

    /// Override > auto-name > real filename.
    private var effectiveName: String { name ?? autoName ?? url.lastPathComponent }

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(effectiveName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if effectiveName != url.lastPathComponent {
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)   // give up space first when the row is tight
                }
            }
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
    let rowID: String
    let hiddenPaths: Set<String>
    let model: AppModel

    /// Right-clicking a row outside the current selection should act on that one
    /// row (standard macOS behavior): adopt it as the selection first.
    private func ensureSelected() {
        if !model.selectedRowIDs.contains(rowID) {
            model.selectedRowIDs = [rowID]
        }
    }

    private var multi: Bool { model.selectedRowIDs.count > 1 }

    var body: some View {
        Group {
            if isDirectory && !multi {
                Button("Open", systemImage: "arrow.right.circle") {
                    ensureSelected(); model.drillInto(url)
                }
                Button("Expand / Collapse", systemImage: "chevron.right") {
                    model.toggleExpanded(url)
                }
            } else if !multi {
                Button("Open", systemImage: "doc.text") {
                    ensureSelected(); model.selectedFile = url
                }
            }

            Divider()

            Button("Copy Path\(multi ? "s" : "")", systemImage: "doc.on.clipboard") {
                ensureSelected(); model.copyPaths()
            }
            .keyboardShortcut("c", modifiers: [.option, .command])

            let allHidden = model.selectionIsAllHidden(hiddenPaths)
                || (model.selectedRowIDs.isEmpty && hiddenPaths.contains(url.path))
            Button(allHidden ? "Un-hide" : "Hide",
                   systemImage: allHidden ? "eye" : "eye.slash") {
                ensureSelected(); model.setHiddenForSelection(!allHidden)
            }
            .keyboardShortcut(.delete, modifiers: .command)

            Button("Edit Tags…", systemImage: "tag") {
                ensureSelected()
                if multi {
                    model.notesOpenPath = nil
                    model.editingTagsForSelection = true
                } else {
                    model.selectedFile = url
                    model.notesOpenPath = url.path
                }
            }

            if !multi {
                Button("Rename…", systemImage: "pencil") {
                    ensureSelected(); model.renamingPath = url.path
                }
            }

            Button("Unpin", systemImage: "pin.slash") {
                ensureSelected(); model.unpinSelection()
            }

            Divider()

            Button("Reveal in Finder", systemImage: "magnifyingglass") {
                ensureSelected()
                NSWorkspace.shared.activateFileViewerSelecting(model.selectedURLs)
            }
        }
    }
}

/// In-place display-name editor shown on the row being renamed. Pre-fills with
/// the effective label and treats "filename" or "auto-name" as "no override".
struct RenameField: View {
    let url: URL
    let model: AppModel
    var autoName: String? = nil   // Pinned-context parent-folder name, if applicable

    @Environment(\.modelContext) private var context
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear {
                // Effective label: user override > auto-name (pinned) > filename.
                text = model.store?.displayName(for: url.path)
                    ?? autoName
                    ?? url.lastPathComponent
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
        // Accepting the real filename OR the auto-name stores no override, so the
        // row stays auto/plain and a later auto-name change still applies.
        let isDefault = trimmed == url.lastPathComponent || trimmed == autoName
        // Preserve existing notes/tags; only the display name changes here.
        store.setMeta(path: url.path,
                      info: meta?.info ?? "",
                      tagNames: meta?.tags.map(\.name) ?? [],
                      displayName: isDefault ? "" : trimmed)
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

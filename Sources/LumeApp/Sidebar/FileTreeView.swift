import AppKit
import SwiftUI
import SwiftData
import LumeCore
import LumeUI

/// One file-tree element: the row, plus — only when it's an expanded folder —
/// its recursive subtree, presented as a SINGLE child view so the parent
/// ForEach keeps a constant view count per element.
private struct FileNodeView: View {
    let node: FileNode
    let model: AppModel
    let section: SidebarSection
    let depth: Int

    var body: some View {
        SidebarItemRow(url: node.url, isDirectory: node.isDirectory,
                       section: section, depth: depth,
                       model: model,
                       displayName: model.displayNames[node.url.path],
                       isHidden: model.hiddenPaths.contains(node.url.path))
            .tag(SidebarRow(url: node.url, isDirectory: node.isDirectory,
                            section: section).id)

        if node.isDirectory, model.expandedPaths.contains(node.url.path) {
            FileTreeView(parent: node.url, model: model,
                         section: section, depth: depth + 1)
        }
    }
}

/// Lazily lists the children of `parent`, honoring files-only.
struct FileTreeView: View {
    let parent: URL
    let model: AppModel
    let section: SidebarSection
    var depth: Int = 0

    @State private var children: [FileNode]

    init(parent: URL, model: AppModel,
         section: SidebarSection, depth: Int = 0) {
        self.parent = parent
        self.model = model
        self.section = section
        self.depth = depth
        // Seed children at construction so the first render shows them. A bare
        // `ForEach` whose collection is initially empty never fires `.onAppear`,
        // so relying on it to kick off the first load left the tree permanently
        // empty. `.onChange(of: parent)` still handles re-roots on the same view.
        _children = State(initialValue: model.children(of: parent,
                                                        includeHidden: Self.includeHidden(section: section, model: model)))
    }

    /// Whether the on-disk enumeration should include Finder-hidden files.
    /// Browser shows reality (dotfiles gated by the browser toggle); the pinned
    /// region is a curation surface and never reveals OS-hidden files here.
    /// Shared by the `_children` seed and `reload()` so the policy can't drift.
    private static func includeHidden(section: SidebarSection, model: AppModel) -> Bool {
        section == .browser && model.showBrowserHidden
    }

    var body: some View {
        // Per-row SCALARS, not the whole dicts. Reading model.displayNames /
        // model.hiddenPaths inside FileNodeView re-renders this (cheap) ForEach on
        // a meta change, but each leaf row receives an unchanged scalar and SwiftUI
        // skips it — only the edited row's scalar changes, so only it renders.
        // Each node maps to exactly ONE child view (FileNodeView), so the outer
        // ForEach keeps a CONSTANT view count per element: expanding a folder grows
        // FileNodeView's body, not the sibling list, so SwiftUI doesn't re-diff the
        // whole row collection (Apple's constant-view-count rule).
        ForEach(visibleChildren) { node in
            FileNodeView(node: node, model: model, section: section, depth: depth)
        }
        .onAppear { reload() }
        .onChange(of: parent) { _, _ in reload() }
        // Re-enumerate when the browser hidden toggle flips so dotfiles
        // appear/disappear. Harmless no-op for the pinned tree (it always
        // enumerates with includeHidden: false; reload() re-applies that).
        // No matching watcher for `showPinnedHidden` is needed: that flag only
        // affects the `visibleChildren` filter, which re-evaluates reactively
        // via @Observable tracking — no new filesystem enumeration required.
        .onChange(of: model.showBrowserHidden) { _, _ in reload() }
        // FSEvents (Finder/other-app edits) bump the cache revision. Re-read ONLY
        // when THIS directory was the one invalidated: an invalidated dir is a
        // cache miss, an untouched dir is still cached. Without this gate a single
        // edit anywhere (including the editor's own autosave) re-ran reload() on
        // every mounted FileTreeView in the expanded tree.
        .onChange(of: model.fileSystemRevision) { _, _ in
            if !model.isDirectoryCached(parent, includeHidden: Self.includeHidden(section: section, model: model)) {
                reload()
            }
        }
    }

    private var visibleChildren: [FileNode] {
        var nodes = children
        if model.filesOnly { nodes = nodes.filter { !$0.isDirectory } }
        // Curation filter: only the FAVORITES region hides items by FileMeta.hidden,
        // and only when the pinned reveal toggle is off. The browser shows reality.
        if section == .pinned, !model.showPinnedHidden {
            nodes = nodes.filter { !model.hiddenPaths.contains($0.url.path) }
        }
        if !model.browseFilter.isEmpty {
            nodes = nodes.filter { $0.isDirectory || $0.name.localizedCaseInsensitiveContains(model.browseFilter) }
        }
        return nodes
    }

    private func reload() {
        children = model.children(of: parent,
                                  includeHidden: Self.includeHidden(section: section, model: model))
    }
}

/// One selectable file/folder row. Selection is native (List(selection:)); the
/// disclosure triangle toggles inline expansion, and a double-click drills into
/// a folder / opens a file. Single clicks are NOT intercepted, so ⌘/⇧
/// multi-select works in both regions.
struct SidebarItemRow: View {
    let url: URL
    let isDirectory: Bool
    let section: SidebarSection
    var depth: Int = 0
    let model: AppModel
    /// This row's own display-name override (FileMeta.displayName), or nil. A
    /// SCALAR so SwiftUI re-renders this row only when ITS name changes.
    var displayName: String? = nil
    /// Whether this row's path is hidden. Scalar, same isolation rationale.
    var isHidden: Bool = false

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
                        .accessibilityHidden(true)   // expand/collapse exposed as a row action below
                } else {
                    Spacer().frame(width: 12)
                }

                if isRenaming {
                    RenameField(url: url, model: model,
                                autoName: section == .pinned ? DisplayName.autoName(for: url) : nil)
                } else if isDirectory {
                    Label(displayName ?? url.lastPathComponent,
                          systemImage: section == .pinned ? "folder.fill" : "folder")
                        .foregroundStyle(section == .pinned ? .yellow : .primary)
                        .lineLimit(1)
                } else {
                    FileRow(url: url,
                            kind: FileKind.detect(filename: url.lastPathComponent),
                            name: displayName,
                            autoName: section == .pinned ? DisplayName.autoName(for: url) : nil)
                }
                Spacer(minLength: 0)
                if section == .pinned, model.showPinnedHidden, isHidden {
                    Button { model.unhide(url) } label: { Image(systemName: "eye") }
                        .buttonStyle(.borderless)
                        .help("Un-hide")
                        .accessibilityLabel("Un-hide \(displayName ?? url.lastPathComponent)")
                }
            }
            .opacity(section == .pinned && isHidden ? 0.45 : 1)
            // VoiceOver: name/role/state + an Expand/Collapse action.
            // NOTE: do NOT wrap this in `.accessibilityElement(children: .combine)`.
            // Inside `List(selection:)` that synthesizes a combined a11y element
            // over the row content which HIJACKS single-click hit-testing — it
            // silently breaks click-to-select (single-click selection is now
            // owned natively by `List(selection:)`, and double-click drill/open
            // still routes through the remaining `.onTapGesture(count: 2)` below).
            // These label/hint/action modifiers annotate the row's native
            // selectable element and leave mouse selection intact.
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(isDirectory ? "Opens folder" : "Opens file")
            .accessibilityAddTraits(
                model.selectedRowIDs.contains(SidebarRow(url: url, isDirectory: isDirectory, section: section).id)
                ? .isSelected : [])
            .accessibilityAction(named: isExpanded ? "Collapse" : "Expand") {
                if isDirectory { model.toggleExpanded(url) }
            }
            if !isDirectory, model.selectedFile == url, !isRenaming {
                RowMetaView(url: url, model: model)
            }
        }
        .padding(.leading, CGFloat(depth) * 12)
        .contentShape(Rectangle())
        // Drag-to-copy-paths only in the browser; in Favorites it would fight
        // the list's .onMove drag-to-reorder.
        .draggableIf(section == .browser, url)
        // Double-click = Finder drill/open. The single click is handled by native
        // List(selection:) (so ⌘/⇧ multi-select and .onMove keep working). For a
        // file we set the SELECTION (not selectedFile directly) so the List, the
        // RowMetaView (gated on selectedFile == url), the action bar, and the
        // keyboard helpers all stay in sync — onChange(selectedRowIDs) →
        // openIfSingleFileSelected() then sets selectedFile.
        .onTapGesture(count: 2) {
            if isDirectory {
                model.expandedPaths.remove(url.path)   // collapse any pending inline expand
                model.drillInto(url)
            } else {
                // Sync the selection (so List/action-bar/keyboard helpers agree),
                // then open explicitly. The explicit open matters when this file
                // is ALREADY the sole selection: the set is unchanged, so the
                // onChange(selectedRowIDs)→openIfSingleFileSelected path doesn't
                // fire, and without this the second click would do nothing.
                model.selectedRowIDs = [SidebarRow(url: url, isDirectory: false, section: section).id]
                model.selectedFile = url
            }
        }
        .contextMenu {
            RowMenu(url: url,
                    isDirectory: isDirectory,
                    section: section,
                    rowID: SidebarRow(url: url, isDirectory: isDirectory, section: section).id,
                    hiddenPaths: model.hiddenPaths,
                    model: model)
        }
    }

    /// A spoken description: name, then folder/file, then any pinned/hidden state.
    private var accessibilityLabel: String {
        var parts = [displayName ?? url.lastPathComponent, isDirectory ? "folder" : "file"]
        if section == .pinned { parts.append("pinned") }
        if isHidden { parts.append("hidden") }
        return parts.joined(separator: ", ")
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
        case .image: return "photo"
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
        case .image: return .green
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
    let section: SidebarSection
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

            // Real filesystem operations live in the browser (the live tree);
            // the pinned region is a curation surface (use Pin/Hide there).
            if section == .browser {
                Divider()
                if isDirectory && !multi {
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        model.newFolder(in: url)
                    }
                }
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    ensureSelected(); model.duplicate()
                }
                Button("Move to Trash", systemImage: "trash", role: .destructive) {
                    ensureSelected(); model.trash()
                }
            }

            // Hide/Un-hide curates the FAVORITES view, so it applies ONLY to a
            // nested item inside a pinned folder — never a top-level favorite
            // (use Unpin) and never the browser (which shows reality).
            if section == .pinned && !model.isPinned(url) {
                // If the clicked row isn't part of the selection, judge by that
                // row (right-click adopts it); otherwise judge by the whole
                // selection. The action re-derives state AFTER ensureSelected()
                // so label and action can't disagree.
                let allHidden = model.selectionIsAllHidden(hiddenPaths)
                    || (!model.selectedRowIDs.contains(rowID) && hiddenPaths.contains(url.path))
                Button(allHidden ? "Un-hide" : "Hide",
                       systemImage: allHidden ? "eye" : "eye.slash") {
                    ensureSelected()
                    model.setHiddenForSelection(!model.selectionIsAllHidden(hiddenPaths))
                }
                // ⌃⌘H, not ⌘⌫: ⌘⌫ is the universal "Move to Trash" and is reserved
                // for that (see RowMenu trash action).
                .keyboardShortcut("h", modifiers: [.control, .command])
            }

            Button("Edit Tags…", systemImage: "tag") {
                ensureSelected()
                if multi {
                    model.notesOpenPath = nil
                    model.editingTagsForSelection = true
                } else {
                    model.selectedFile = url
                    model.tagsOpenPath = url.path
                }
            }

            if !multi {
                Button("Rename…", systemImage: "pencil") {
                    ensureSelected(); model.renamingPath = url.path
                }
            }

            if section == .browser {
                if !multi {
                    Button(model.isPinned(url) ? "Unpin" : "Pin",
                           systemImage: model.isPinned(url) ? "pin.slash" : "pin") {
                        ensureSelected(); model.togglePin(url, isDirectory: isDirectory)
                    }
                }
            } else if model.isPinned(url) {
                Button("Unpin", systemImage: "pin.slash") {
                    ensureSelected(); model.unpinSelection()
                }
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
    @Query private var allTags: [Tag]
    @State private var tagNames: [String] = []
    @State private var notes = ""
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?
    private static let saveDebounce = Duration.milliseconds(400)

    private var notesOpen: Bool { model.notesOpenPath == url.path }
    /// The inline tag editor is open for this file. Driven from the model so a
    /// chip tap and the row's "Edit Tags…" context menu share one source of
    /// truth (and so it works even when the file has no tags to tap).
    private var editingTags: Bool { model.tagsOpenPath == url.path }
    /// When the file has no tags and isn't being edited, nothing renders — the
    /// row collapses to zero height (no perpetual field, no reserved space).
    private var showsMeta: Bool { editingTags || !tagNames.isEmpty }

    /// Live color for a tag name from the reactive @Query (0 until first saved).
    private func colorIndex(_ name: String) -> Int {
        allTags.first { $0.name == name }?.colorIndex ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Zero-size anchor so `load()` runs even when the visible content is
            // empty — an otherwise-empty VStack may never fire `.onAppear`.
            Color.clear.frame(width: 0, height: 0).onAppear(perform: load)

            if editingTags {
                editor
                if notesOpen { notesField.padding(.top, 6) }
            } else if !tagNames.isEmpty {
                chips
            }
        }
        .padding(.leading, 18)
        .padding(.vertical, showsMeta ? 2 : 0)
        .onDisappear {
            saveTask?.cancel(); save()
            // Leaving the row collapses its editors so it reopens clean.
            if model.tagsOpenPath == url.path { model.tagsOpenPath = nil }
            if model.notesOpenPath == url.path { model.notesOpenPath = nil }
        }
        .onChange(of: url) { _, _ in saveTask?.cancel(); loaded = false; load() }
    }

    /// Collapsed state: read-only colored chips. Click anywhere to edit.
    private var chips: some View {
        FlowLayout(spacing: 4) {
            ForEach(tagNames, id: \.self) { name in
                TagChip(name: name, colorIndex: colorIndex(name))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.tagsOpenPath = url.path }
        .help("Click to edit tags")
    }

    /// Editing state: the token field plus notes toggle and a Done button.
    private var editor: some View {
        HStack(spacing: 6) {
            TagField(names: $tagNames, colorIndex: colorIndex, recolor: recolor)
                .onChange(of: tagNames) { _, _ in scheduleSave() }
            Button {
                model.notesOpenPath = notesOpen ? nil : url.path
            } label: {
                Image(systemName: notesOpen ? "note.text" : "note.text.badge.plus")
            }
            .buttonStyle(.borderless)
            .help(notesOpen ? "Hide notes" : "Add notes")
            Button {
                saveTask?.cancel(); save()
                model.notesOpenPath = nil
                model.tagsOpenPath = nil
            } label: {
                Image(systemName: "checkmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Done")
        }
    }

    private var notesField: some View {
        TextField("Notes…", text: $notes, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.caption)
            .lineLimit(3...8)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            .onChange(of: notes) { _, _ in scheduleSave() }   // debounced autosave
    }

    private func load() {
        guard !loaded else { return }
        let store = LibraryStore(context: context)
        let meta = store.meta(for: url.path)
        tagNames = meta?.tags.map(\.name) ?? []
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
        store.setMeta(path: url.path, info: notes, tagNames: tagNames,
                      displayName: store.displayName(for: url.path) ?? "")
    }

    /// Inline recolor: flush pending edits first so the tag row exists, then
    /// recolor it. Returns immediately if the store can't find it (brand-new,
    /// not yet saved) — harmless, the auto-assigned color stands.
    private func recolor(_ name: String, _ colorIndex: Int) {
        saveTask?.cancel()
        save()
        LibraryStore(context: context).recolorTag(named: name, colorIndex: colorIndex)
    }
}

private extension View {
    /// Applies `.draggable(payload)` only when `enabled`, leaving the view
    /// untouched otherwise (so reorderable lists keep their drag behavior).
    @ViewBuilder
    func draggableIf<T: Transferable>(_ enabled: Bool, _ payload: T) -> some View {
        if enabled {
            self.draggable(payload)
        } else {
            self
        }
    }
}

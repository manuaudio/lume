import AppKit
import SwiftUI
import SwiftData
import LumeCore
import LumeUI

struct SidebarView: View {
    let model: AppModel

    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Favorite.sortIndex) private var favorites: [Favorite]
    @Query(sort: \Tag.name) private var tags: [Tag]

    @FocusState private var filterFocused: Bool

    /// Drives the tag rename sheet (non-nil while renaming a specific tag).
    @State private var renamingTag: TagRef?

    /// Drives the Manage Tags panel.
    @State private var showingTagManager = false

    private var selection: Binding<Set<String>> {
        Binding(get: { model.selectedRowIDs }, set: { model.selectedRowIDs = $0 })
    }

    private var filter: Binding<String> {
        Binding(get: { model.browseFilter }, set: { model.browseFilter = $0 })
    }

    /// Favorites shown in the pinned list, honoring the FAVORITES show-hidden
    /// toggle (`showPinnedHidden`). Shared by the `ForEach` and `.onMove` so
    /// reorder indices stay correct.
    private var visibleFavorites: [Favorite] {
        model.showPinnedHidden ? favorites : favorites.filter { !model.hiddenPaths.contains($0.path) }
    }

    /// Flat top-to-bottom order of every visible row id, matching what the List
    /// actually renders (GROUPS region, then FAVORITES + expanded pinned children,
    /// then the browser tree). Feeds the keyboard range math in `AppModel`.
    ///
    /// PERFORMANCE: this recursively walks the expanded tree via
    /// `model.children(of:)` → an UNCACHED `FileManager` directory read per
    /// expanded folder. It is therefore NOT a computed property observed by the
    /// body (that recomputed the whole disk walk on every selection/arrow-key
    /// render — a per-keystroke main-thread hang). Instead it is recomputed only
    /// from the explicit `.onChange` triggers below, for the inputs that actually
    /// change the visible STRUCTURE/order — never on `selectedRowIDs`.
    private func computeOrderedRowIDs() -> [String] {
        var ids: [String] = []

        // GROUPS region first (matches the rendered order: GROUPS, FAVORITES,
        // OPEN FOLDER). A group header row, then — when expanded — one file row
        // per tagged file in sorted order.
        for tag in tags {
            ids.append(GroupRowID.headerID(tagName: tag.name))
            guard model.expandedGroups.contains(tag.name) else { continue }
            for path in model.sortedGroupFilePaths(forTagNamed: tag.name) {
                ids.append(GroupRowID.fileID(tagName: tag.name, path: path))
            }
        }

        func walk(_ url: URL, isDir: Bool, section: SidebarSection, includeHidden: Bool) {
            ids.append(SidebarRow(url: url, isDirectory: isDir, section: section).id)
            guard isDir, model.expandedPaths.contains(url.path) else { return }
            for child in visibleChildren(of: url, section: section, includeHidden: includeHidden) {
                walk(child.url, isDir: child.isDirectory, section: section, includeHidden: includeHidden)
            }
        }

        for fav in visibleFavorites {
            walk(URL(fileURLWithPath: fav.path), isDir: fav.kindRaw == "folder",
                 section: .pinned, includeHidden: false)
        }
        if let root = model.browseRoot {
            for child in visibleChildren(of: root, section: .browser,
                                         includeHidden: model.showBrowserHidden) {
                walk(child.url, isDir: child.isDirectory, section: .browser,
                     includeHidden: model.showBrowserHidden)
            }
        }
        return ids
    }

    /// Every input that can change the OUTPUT of `computeOrderedRowIDs`, folded
    /// into one cheap Equatable value. When (and only when) this changes does the
    /// recursive disk walk re-run — selection is deliberately absent. Keep this in
    /// lockstep with the inputs read by `computeOrderedRowIDs` / `visibleChildren`:
    /// expanded set, expanded GROUPS, the tag names, browse root, the
    /// visible-favorites list (favorites order + pinned-hidden reveal + hidden
    /// paths), files-only, the browse text filter, the browser-hidden reveal, the
    /// display names (so a group's file order re-walks on a name change), and the
    /// group membership cache (so adding/removing a file to/from a group re-walks).
    private var rowOrderSignature: RowOrderSignature {
        RowOrderSignature(
            expanded: model.expandedPaths,
            expandedGroups: model.expandedGroups,
            tagNames: tags.map(\.name),
            browseRoot: model.browseRoot?.path,
            favoritePaths: visibleFavorites.map(\.path),
            filesOnly: model.filesOnly,
            browseFilter: model.browseFilter,
            showBrowserHidden: model.showBrowserHidden,
            showPinnedHidden: model.showPinnedHidden,
            hiddenPaths: model.hiddenPaths,
            displayNames: model.displayNames,
            groupFilePaths: model.groupFilePaths
        )
    }

    /// The same filtering `FileTreeView.visibleChildren` applies, hoisted here so
    /// the keyboard order matches the rendered order exactly.
    /// ⚠️ CROSS-PHASE DRIFT: duplicates `FileTreeView.visibleChildren`
    /// (FileTreeView.swift). Keep them in lockstep on any future change.
    private func visibleChildren(of parent: URL, section: SidebarSection,
                                 includeHidden: Bool) -> [FileNode] {
        var nodes = model.children(of: parent, includeHidden: includeHidden)
        if model.filesOnly { nodes = nodes.filter { !$0.isDirectory } }
        if section == .pinned, !model.showPinnedHidden {
            nodes = nodes.filter { !model.hiddenPaths.contains($0.url.path) }
        }
        if !model.browseFilter.isEmpty {
            nodes = nodes.filter { $0.isDirectory || $0.name.localizedCaseInsensitiveContains(model.browseFilter) }
        }
        return nodes
    }

    var body: some View {
        List(selection: selection) {
            GroupsSection(model: model, tags: tags,
                          renamingTag: $renamingTag,
                          showingTagManager: $showingTagManager)
            pinnedSection()
            browserSection()
        }
        .listStyle(.sidebar)
        // Mount the expensive all-metadata @Query ONCE, isolated in a leaf view
        // whose body is Color.clear. It updates the model's meta index; it never
        // re-renders the tree. Removing the @Query from SidebarView is what kills
        // the invalidation storm.
        .background(MetaIndexLoader(model: model))
        .sheet(item: $renamingTag) { ref in
            TagRenameSheet(model: model, oldName: ref.name) {
                renamingTag = nil
            }
        }
        .sheet(isPresented: $showingTagManager) {
            TagManagerSheet(model: model, isPresented: $showingTagManager)
        }
        .safeAreaInset(edge: .top) {
            topBar
        }
        .safeAreaInset(edge: .bottom) {
            if model.selectedRowIDs.count >= 2 {
                SidebarActionBar(model: model, hiddenPaths: model.hiddenPaths)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: model.selectedRowIDs.count >= 2)
        .background(ModifierMonitor(pathPeek: Binding(get: { model.pathPeek },
                                                      set: { model.pathPeek = $0 })))
        .sheet(isPresented: Binding(get: { model.editingTagsForSelection },
                                    set: { model.editingTagsForSelection = $0 })) {
            MultiTagSheet(model: model,
                          isPresented: Binding(get: { model.editingTagsForSelection },
                                               set: { model.editingTagsForSelection = $0 }))
        }
        .onChange(of: model.selectedRowIDs) { _, _ in model.openIfSingleFileSelected() }
        // Recompute the flat visible order ONLY when the inputs that change the
        // rendered structure/order change — NOT on selection. `rowOrderSignature`
        // folds every such input into one Equatable value, so a single onChange
        // covers them all and the expensive disk walk runs only when needed.
        .onChange(of: rowOrderSignature) { _, _ in
            model.orderedVisibleRowIDs = computeOrderedRowIDs()
        }
        .onAppear {
            model.orderedVisibleRowIDs = computeOrderedRowIDs()
        }
        // List-scoped keys: these only fire when the List — not a text field —
        // is first responder, so they never interfere with the filter/rename/
        // notes editors. Each returns `.handled` only when it acts.
        .background(QLHost(controller: QuickLook.shared))
        .onKeyPress(.init("/")) { filterFocused = true; return .handled }
        .onKeyPress(.space) {
            guard let id = model.soleSelectedRowID,
                  let row = SidebarRow.decode(id), !row.isDirectory else { return .ignored }
            QuickLook.shared.show(row.url)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard let id = model.soleSelectedRowID,
                  let row = SidebarRow.decode(id) else { return .ignored }
            guard row.isDirectory else { return .ignored }   // → on a file: no-op
            if model.expandedPaths.contains(row.url.path) {
                model.moveSelection(by: 1)                    // already open → descend
            } else {
                model.expandedPaths.insert(row.url.path)      // closed → expand
            }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard let id = model.soleSelectedRowID,
                  let row = SidebarRow.decode(id) else { return .ignored }
            if row.isDirectory, model.expandedPaths.contains(row.url.path) {
                model.expandedPaths.remove(row.url.path)      // open folder → collapse
                return .handled
            }
            // Collapsed folder or file → jump to the parent folder (Finder).
            return model.selectParentRow(ofRowID: id) ? .handled : .ignored
        }
        .onKeyPress(keys: [.upArrow], phases: .down) { press in
            if press.modifiers.contains(.shift) {
                model.extendSelection(by: -1)
            } else if press.modifiers.isEmpty {
                model.moveSelection(by: -1)
            } else {
                return .ignored
            }
            return .handled
        }
        .onKeyPress(keys: [.downArrow], phases: .down) { press in
            if press.modifiers.contains(.shift) {
                model.extendSelection(by: 1)
            } else if press.modifiers.isEmpty {
                model.moveSelection(by: 1)
            } else {
                return .ignored
            }
            return .handled
        }
        .onKeyPress(.return) {
            guard model.soleSelectedRowID != nil else { return .ignored }
            model.activateSelectedRow()
            return .handled
        }
        .onKeyPress(keys: ["a"], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            model.selectAllVisibleRows()
            return .handled
        }
        // Type-to-select: a printable letter/number with no ⌘/⌃ jumps to the
        // first matching visible row (Finder typeahead). Arrows, space, ⏎, and
        // shortcuts produce non-alphanumeric characters here and pass through.
        .onKeyPress(phases: .down) { press in
            guard !press.modifiers.contains(.command),
                  !press.modifiers.contains(.control),
                  let ch = press.characters.first,
                  ch.isLetter || ch.isNumber else { return .ignored }
            model.typeaheadAppend(ch)
            return .handled
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumeFocusFilter)) { _ in
            filterFocused = true
        }
        // The local .flagsChanged monitor can miss the ⌃ key-up if the app/window
        // resigns active while held, leaving the tree dimmed and the peek bar
        // stuck. Reset pathPeek defensively on resign / disappear.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.pathPeek = false
        }
        .onDisappear { model.pathPeek = false }
    }

    // MARK: Top bar — filter field + files-only toggle

    private var topBar: some View {
        VStack(spacing: 6) {
            filterField
            HStack {
                Toggle(isOn: Binding(get: { model.filesOnly },
                                     set: { model.filesOnly = $0 })) {
                    Label("Files only", systemImage: "doc")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Filter…", text: filter)
                .textFieldStyle(.plain)
                .focused($filterFocused)
                .onExitCommand { filterFocused = false }
            if !model.browseFilter.isEmpty {
                Button {
                    model.browseFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        // Match the bordered inset-field treatment used by the tag/notes editors
        // so the filter field doesn't read as flat/disabled next to them.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        )
    }

    // MARK: Pinned

    private var openFolderTitle: String {
        let name = model.browseRoot?.lastPathComponent ?? ""
        return name.isEmpty ? "OPEN FOLDER" : "OPEN FOLDER · \(name)"
    }

    @ViewBuilder private func pinnedSection() -> some View {
        Section {
            if favorites.isEmpty {
                Text("Right-click any file or folder to pin it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(visibleFavorites) { fav in
                    let url = URL(fileURLWithPath: fav.path)
                    let isDir = fav.kindRaw == "folder"
                    SidebarItemRow(url: url,
                                   isDirectory: isDir,
                                   section: .pinned, depth: 0,
                                   model: model,
                                   displayName: model.displayNames[url.path],
                                   isHidden: model.hiddenPaths.contains(url.path))
                        .tag(SidebarRow(url: url, isDirectory: isDir,
                                        section: .pinned).id)
                    // Inline expansion: a favorited folder reveals its children
                    // in place (the curation surface), mirroring the browser tree.
                    if isDir, model.expandedPaths.contains(url.path) {
                        FileTreeView(parent: url, model: model,
                                     section: .pinned, depth: 1)
                    }
                }
                .onMove { indices, newOffset in
                    // Reorder only the visible favorites, then re-stitch hidden
                    // paths at the tail so the store keeps a complete ordering.
                    var visible = visibleFavorites.map(\.path)
                    visible.move(fromOffsets: indices, toOffset: newOffset)
                    let hidden = favorites.map(\.path).filter { !visible.contains($0) }
                    model.store?.reorderFavorites(visible + hidden)
                }
            }
        } header: {
            SectionHeader(title: "FAVORITES",
                          isOn: Binding(get: { model.showPinnedHidden },
                                        set: { model.showPinnedHidden = $0 }),
                          help: "Show items hidden from Favorites")
        }
        // Drag a file/folder from the browser onto FAVORITES to pin it.
        .dropDestination(for: URL.self) { urls, _ in
            model.pinDropped(urls)
            return true
        }
    }

    // MARK: Browser

    @ViewBuilder private func browserSection() -> some View {
        Section {
            pathPeekBar
            if let root = model.browseRoot {
                FileTreeView(parent: root, model: model,
                             section: .browser, depth: 0)
                    .opacity(model.pathPeek ? 0.4 : 1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: model.pathPeek)
            }
        } header: {
            SectionHeader(title: openFolderTitle,
                          isOn: Binding(get: { model.showBrowserHidden },
                                        set: { model.showBrowserHidden = $0 }),
                          help: "Show hidden files (.env, .claude…)")
        }
    }

    /// Transient ancestor path, shown only while ⌃ is held (model.pathPeek).
    /// Clicking a chip re-roots and the bar collapses; releasing ⌃ collapses it.
    @ViewBuilder private var pathPeekBar: some View {
        if model.pathPeek, let root = model.browseRoot {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let segs = Breadcrumb.segments(for: root, home: home)
            HStack(spacing: 4) {
                ForEach(Array(segs.enumerated()), id: \.element.id) { i, seg in
                    if i > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Button(seg.label) {
                        model.drillInto(seg.url)
                    }
                    .buttonStyle(.borderless)
                    .lineLimit(1)
                    .foregroundStyle(i == segs.count - 1 ? .primary : .secondary)
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.bar)
        }
    }
}

// MARK: - MetaIndexLoader

/// A LEAF view that owns the expensive all-metadata `@Query` and does nothing
/// but feed it into the model's stable meta index. Its body is `Color.clear`, so
/// when `allMeta` changes (a tag edit, hide, rename, the debounced notes
/// autosave) only THIS view re-evaluates — never the sidebar tree. The model's
/// `displayNames`/`hiddenPaths` then update, and only the rows whose own scalar
/// changed re-render. Mounted once via `.background` on the List.
struct MetaIndexLoader: View {
    let model: AppModel
    @Query private var allMeta: [FileMeta]
    // Observe the tag list too, so EMPTY groups (tags with no files — invisible
    // when iterating FileMeta) still get a `[name: []]` entry, and so a tag
    // create/rename/delete refreshes the membership cache.
    @Query(sort: \Tag.name) private var allTags: [Tag]

    var body: some View {
        Color.clear
            .onAppear { push() }
            .onChange(of: allMeta) { _, _ in push() }
            .onChange(of: allTags.map(\.name)) { _, _ in push() }
    }

    private func push() {
        var names: [String: String] = [:]
        var hidden: Set<String> = []
        // Seed every existing tag with an empty list so empty groups still render.
        var groups: [String: [String]] = [:]
        for t in allTags { groups[t.name] = [] }
        for m in allMeta {
            if !m.displayName.isEmpty { names[m.path] = m.displayName }
            if m.hidden { hidden.insert(m.path) }
            for tag in m.tags { groups[tag.name, default: []].append(m.path) }
        }
        model.updateMetaIndex(displayNames: names, hiddenPaths: hidden)
        // Sort each group by effective display name (reusing the names just built),
        // matching `sortedGroupFilePaths`' previous on-the-fly ordering.
        for (name, paths) in groups {
            groups[name] = GroupSort.sorted(paths) { names[$0] }
        }
        model.updateGroupFilePaths(groups)
    }
}

// MARK: - RowOrderSignature

/// A cheap, value-type fingerprint of every input that affects the flat visible
/// row order. Equating two of these lets SwiftUI's `.onChange` re-drive the
/// (expensive) ordered-row walk only when the structure/visibility actually
/// changed — never on a mere selection change. See `SidebarView.rowOrderSignature`.
private struct RowOrderSignature: Equatable {
    let expanded: Set<String>
    let expandedGroups: Set<String>
    let tagNames: [String]
    let browseRoot: String?
    let favoritePaths: [String]
    let filesOnly: Bool
    let browseFilter: String
    let showBrowserHidden: Bool
    let showPinnedHidden: Bool
    let hiddenPaths: Set<String>
    // Folded in so a group's file order re-walks when a display name changes
    // (group rows sort by effective display name).
    let displayNames: [String: String]
    // Folded in so the group rows re-walk when membership changes (a file is
    // tagged/untagged, or a group emptied) even if no display name changed.
    let groupFilePaths: [String: [String]]
}

// MARK: - SectionHeader

/// A section header with a trailing borderless eye toggle. Used identically by
/// the FAVORITES and OPEN FOLDER regions so both controls look the same.
struct SectionHeader: View {
    let title: String
    @Binding var isOn: Bool
    let help: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button { isOn.toggle() } label: {
                Image(systemName: isOn ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(help)
            .accessibilityLabel(isOn ? "Hide hidden items" : "Show hidden items")
        }
    }
}

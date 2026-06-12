import SwiftUI
import AppKit
import LumeKit

struct SidebarView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            SourceSwitcherView()
            Divider()
            if app.showingRemote, app.remote != nil {
                RemoteTreeView()
            } else if app.rootURL != nil || !app.scans.isEmpty {
                List {
                    ScansRegion()
                    BundlesRegion()
                    ActivityRegion()
                    GroupsRegion()
                    FavoritesRegion()
                    OpenFolderRegion()
                }
                .listStyle(.sidebar)
                .onKeyPress { handleKey($0) }
                if !app.selectedRowIDs.isEmpty {
                    Divider()
                    SelectionActionBar()
                }
                Divider()
                SidebarFilterBar()
            } else {
                emptyState
            }
        }
        .toolbar {
            ToolbarItem {
                Button { openFolder() } label: {
                    Label("Open Folder", systemImage: "folder.badge.plus")
                }
            }
            ToolbarItem {
                Button { app.beginNewScan() } label: {
                    Label("New Scan", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .alert("Rename", isPresented: bindableApp.presentingRename) {
            TextField("Name", text: bindableApp.renameText)
            Button("Rename") { app.commitRename() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: bindableApp.presentingMultiTag) { MultiTagSheet() }
        .sheet(isPresented: bindableApp.presentingTagManager) { TagManagerSheet() }
        .sheet(isPresented: bindableApp.presentingScanEditor) { NewScanSheet() }
        .sheet(isPresented: bindableApp.presentingNewConnection) { NewConnectionSheet() }
        .sheet(isPresented: bindableApp.presentingOpenGitHubRepo) { OpenGitHubRepoSheet() }
        .sheet(isPresented: bindableApp.presentingRepoBrowser) { RepoBrowserSheet() }
    }

    private var bindableApp: Bindable<AppState> { Bindable(app) }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Folder Open", systemImage: "folder.badge.plus")
        } description: {
            Text("Open a folder to start browsing.")
        } actions: {
            Button("Open Folder…") { openFolder() }
                .buttonStyle(.borderedProminent)
            Button("New Scan…") { app.beginNewScan() }
        }
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            app.openFolder(url)
        }
    }

    /// Finder-style keyboard navigation over the whole sidebar.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let shift = press.modifiers.contains(.shift)
        let command = press.modifiers.contains(.command)

        switch press.key {
        case .upArrow:
            app.resetTypeahead()
            shift ? app.extendSelection(by: -1) : app.moveSelection(by: -1)
            return .handled
        case .downArrow:
            app.resetTypeahead()
            shift ? app.extendSelection(by: 1) : app.moveSelection(by: 1)
            return .handled
        case .leftArrow:
            app.resetTypeahead(); app.collapseOrAscend(); return .handled
        case .rightArrow:
            app.resetTypeahead(); app.expandOrDescend(); return .handled
        case .return:
            app.resetTypeahead(); app.openOrDrillSelected(); return .handled
        case .escape:
            app.resetTypeahead(); app.clearSelection(); return .handled
        default:
            break
        }

        if command, press.characters == "a" {
            app.selectAllRows(); return .handled
        }
        // Type-ahead: a printable character with no command/control.
        if !command, !press.modifiers.contains(.control),
           let ch = press.characters.first,
           ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-" {
            app.typeaheadAppend(ch); return .handled
        }
        return .ignored
    }
}

// MARK: - SCANS

private struct ScansRegion: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Section {
            if app.scans.isEmpty {
                Text("Create a scan to gather files (CLAUDE.md, .env…) across folders")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(app.scans, id: \.id) { scan in
                    Button {
                        app.runScan(scan)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text.magnifyingglass")
                            Text(scan.name).lineLimit(1)
                            Spacer()
                            if app.activeScan?.id == scan.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit…") { app.beginEditScan(scan) }
                        Button("Delete", role: .destructive) { app.deleteScan(scan) }
                    }
                }
            }
        } header: {
            HStack(spacing: 10) {
                Text("Scans")
                Spacer()
                Button { app.beginNewScan() } label: { Image(systemName: "plus.circle") }
                    .buttonStyle(.borderless)
            }
        }
    }
}

// MARK: - Bundles

private struct BundlesRegion: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Section {
            if app.bundles.isEmpty {
                Text("Save a set of files to re-copy as LLM context")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(app.bundles, id: \.id) { bundle in
                    Button {
                        app.openBundle(bundle)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "shippingbox")
                            Text(bundle.name).lineLimit(1)
                            Spacer()
                            Text("\(bundle.paths.count)")
                                .font(.caption).foregroundStyle(.tertiary)
                            if app.activeBundle?.id == bundle.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Open") { app.openBundle(bundle) }
                        Button("Delete", role: .destructive) { app.deleteBundle(bundle) }
                    }
                }
            }
        } header: {
            Text("Bundles")
        }
    }
}

// MARK: - Activity

private struct ActivityRegion: View {
    @Environment(AppState.self) private var app

    private static let timeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        Section {
            if app.recentChanges.isEmpty {
                Text("Edits under this folder show up here.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(app.recentChanges.prefix(8)) { entry in
                    let url = URL(fileURLWithPath: entry.path)
                    Button {
                        app.choose(url)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(url.lastPathComponent).font(.body).lineLimit(1)
                                Text(url.deletingLastPathComponent().lastPathComponent)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(Self.timeFormatter.localizedString(for: entry.date, relativeTo: Date()))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            HStack(spacing: 10) {
                Text("Activity")
                Spacer()
                if !app.recentChanges.isEmpty {
                    Button { app.clearActivityLog() } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                        .help("Clear activity")
                }
            }
        }
    }
}

// MARK: - GROUPS

private struct GroupsRegion: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        Section {
            if app.tags.isEmpty {
                Text("Drag files onto a group, or tag from the editor header")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(app.tags, id: \.name) { tag in
                    GroupHeaderRow(tag: tag)
                    if app.isGroupExpanded(tag.name) {
                        ForEach(app.groupFilePaths[tag.name] ?? [], id: \.self) { path in
                            GroupMemberRow(tagName: tag.name, path: path)
                        }
                    }
                }
            }
        } header: {
            HStack(spacing: 10) {
                Text("Groups")
                Spacer()
                if !app.tags.isEmpty {
                    Button { app.presentingTagManager = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Manage Tags")
                    .accessibilityLabel("Manage Tags")
                }
                Button { app.beginNewGroup() } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New Group")
                .accessibilityLabel("New Group")
            }
        }
        .alert("New Group", isPresented: $app.presentingNewGroup) {
            TextField("Group name", text: $app.newGroupName)
            Button("Create") {
                app.createGroup(named: app.newGroupName)
                app.newGroupName = ""
            }
            Button("Cancel", role: .cancel) { app.newGroupName = "" }
        }
    }
}

/// A tag's GROUP header: expand/collapse, color dot, member count. Drop a file
/// here to tag it; right-click to recolor / rename / delete.
private struct GroupHeaderRow: View {
    let tag: Tag
    @Environment(AppState.self) private var app
    @State private var renaming = false
    @State private var newName = ""
    @State private var dropTargeted = false

    private var headerID: String { GroupRowID.headerID(tagName: tag.name) }

    var body: some View {
        Button {
            let f = NSEvent.modifierFlags
            app.handleRowTap(headerID, command: f.contains(.command), shift: f.contains(.shift)) {
                app.toggleGroup(tag.name)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: app.isGroupExpanded(tag.name) ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Circle().fill(Color.tag(tag.colorIndex)).frame(width: 9, height: 9)
                Text(tag.name).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(tag.files.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            dropTargeted ? Color.accentColor.opacity(0.18)
                : (app.isRowSelected(headerID) ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .dropDestination(for: URL.self) { urls, _ in
            for u in urls { app.addTag(tag.name, toPath: u.path) }
            if !app.isGroupExpanded(tag.name) { app.toggleGroup(tag.name) }
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .contextMenu {
            Menu("Color") {
                ForEach(0..<TagPalette.count, id: \.self) { i in
                    Button(TagPalette.swatch(at: i).name) {
                        app.recolorGroup(tag.name, colorIndex: i)
                    }
                }
            }
            Button("Rename…") { newName = tag.name; renaming = true }
            Button("Delete Group", role: .destructive) { app.deleteGroup(tag.name) }
        }
        .alert("Rename Group", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { _ = app.renameGroup(tag.name, to: newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Renaming to an existing group merges them.")
        }
    }
}

/// A file inside an expanded GROUP. Opens on click; full file-ops context menu
/// plus "Remove from {group}".
private struct GroupMemberRow: View {
    let tagName: String
    let path: String
    @Environment(AppState.self) private var app

    private var url: URL { URL(fileURLWithPath: path) }
    private var rowID: String { GroupRowID.fileID(tagName: tagName, path: path) }

    var body: some View {
        Button {
            let f = NSEvent.modifierFlags
            app.handleRowTap(rowID, command: f.contains(.command), shift: f.contains(.shift)) {
                app.choose(url)
            }
        } label: {
            HStack(spacing: 6) {
                Spacer().frame(width: 14)
                RowLabel(url: url, isDirectory: false, hidden: app.isHidden(url))
            }
        }
        .buttonStyle(.plain)
        .modifier(FileRowActions(url: url, rowID: rowID, isDirectory: false) {
            Button("Remove from \(tagName)") { app.removeTag(tagName, fromPath: path) }
            Divider()
        })
    }
}

// MARK: - Favorites

private struct FavoritesRegion: View {
    @Environment(AppState.self) private var app
    @State private var dropTargeted = false

    var body: some View {
        Section("Favorites") {
            let items = app.favoriteRowItems
            if items.isEmpty {
                Text("Pin files and folders here — or drag them in")
                    .font(.callout)
                    .foregroundStyle(dropTargeted ? .primary : .tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .dropDestination(for: URL.self) { urls, _ in
                        app.pinDropped(urls); return !urls.isEmpty
                    } isTargeted: { dropTargeted = $0 }
            } else {
                ForEach(items) { item in
                    FavoriteRow(item: item)
                }
            }
        }
    }
}

// MARK: - Open Folder (browser)

private struct OpenFolderRegion: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Section {
            let rows = app.browserRows
            if rows.isEmpty {
                Text(app.browseFilter.isEmpty ? "Empty folder" : "No matches")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(rows) { row in
                    BrowserRow(item: row)
                }
            }
        } header: {
            HStack(spacing: 6) {
                BreadcrumbBar()
                Spacer(minLength: 4)
                Button { app.newFolder() } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New Folder (⇧⌘N)")
                .accessibilityLabel("New Folder")
            }
        }
    }
}

// MARK: - Breadcrumb

private struct BreadcrumbBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(Array(app.breadcrumb.enumerated()), id: \.element.id) { index, seg in
                    Button(seg.label) { app.navigate(to: seg.url) }
                        .buttonStyle(.plain)
                        .foregroundStyle(index == app.breadcrumb.count - 1 ? .primary : .secondary)
                    if index < app.breadcrumb.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .font(.caption)
        }
    }
}

// MARK: - Selection action bar

private struct SelectionActionBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let urls = app.selectedURLs
        HStack(spacing: 12) {
            Text("\(urls.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button { app.presentingMultiTag = true } label: { Image(systemName: "tag") }
                .help("Tag selected")
                .accessibilityLabel("Tag selected")
            Button { app.copySelectedPaths() } label: { Image(systemName: "doc.on.clipboard") }
                .help("Copy Paths (⌥⌘C)")
                .accessibilityLabel("Copy Paths")
            Button { app.revealInFinder(urls) } label: { Image(systemName: "magnifyingglass") }
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal in Finder")
            Button { app.moveToTrash(urls) } label: { Image(systemName: "trash") }
                .help("Move to Trash")
                .accessibilityLabel("Move to Trash")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4))
    }
}

// MARK: - Filter bar

private struct SidebarFilterBar: View {
    @Environment(AppState.self) private var app
    @FocusState private var filterFocused: Bool

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $app.browseFilter)
                    .textFieldStyle(.plain)
                    .focused($filterFocused)
                    .onChange(of: app.focusFilterRequested) { _, _ in filterFocused = true }
                if !app.browseFilter.isEmpty {
                    Button { app.browseFilter = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear filter")
                }
            }
            HStack(spacing: 12) {
                Toggle("Files only", isOn: $app.filesOnly)
                Toggle("Hidden", isOn: $app.showBrowserHidden)
                Spacer()
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

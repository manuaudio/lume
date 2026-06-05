import AppKit
import SwiftUI
import SwiftData
import LumeCore
import LumeUI

/// The GROUPS sidebar region: a flat list of tags as expandable, color-tinted
/// virtual folders. Each group expands to show EVERY file carrying that tag
/// (from anywhere on disk), sorted by effective display name. A ＋ New Group row
/// creates an empty, persistent group. Drag a file onto a group to tag it.
struct GroupsSection: View {
    let model: AppModel
    let tags: [Tag]
    @Binding var renamingTag: TagRef?
    @Binding var showingTagManager: Bool

    @State private var newGroupPromptShown = false
    @State private var newGroupName = ""

    var body: some View {
        Section {
            ForEach(tags) { tag in
                groupHeaderRow(tag)
                if model.expandedGroups.contains(tag.name) {
                    ForEach(model.sortedGroupFilePaths(forTagNamed: tag.name), id: \.self) { path in
                        groupFileRow(tagName: tag.name, path: path)
                    }
                }
            }
            newGroupRow
        } header: {
            HStack {
                Text("GROUPS")
                Spacer()
                Button { showingTagManager = true } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Manage tags (rename, recolor, merge, delete)")
                .accessibilityLabel("Manage tags")
            }
        }
        .alert("New Group", isPresented: $newGroupPromptShown) {
            TextField("Group name", text: $newGroupName)
            Button("Create") {
                model.createGroup(named: newGroupName)
                newGroupName = ""
            }
            Button("Cancel", role: .cancel) { newGroupName = "" }
        } message: {
            Text("Create an empty group. Tag files (or drag them here) to add them.")
        }
    }

    // MARK: Group header row

    @ViewBuilder private func groupHeaderRow(_ tag: Tag) -> some View {
        let id: String = GroupRowID.header(tagName: tag.name)
        let isExpanded = model.expandedGroups.contains(tag.name)
        let count = model.sortedGroupFilePaths(forTagNamed: tag.name).count
        HStack(spacing: 6) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(width: 12)
                .onTapGesture { model.toggleGroupExpanded(tag.name) }
                .accessibilityHidden(true)
            Image(systemName: "tag.fill")
                .foregroundStyle(tagColor(tag.colorIndex))
            Text(tag.name).lineLimit(1)
            Spacer(minLength: 0)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .tag(id)
        .accessibilityLabel("\(tag.name), group, \(count) file\(count == 1 ? "" : "s")")
        .accessibilityAddTraits(model.selectedRowIDs.contains(id) ? .isSelected : [])
        .accessibilityAction(named: isExpanded ? "Collapse" : "Expand") {
            model.toggleGroupExpanded(tag.name)
        }
        // Double-click a group → expand/collapse (no disk folder to drill into).
        .onTapGesture(count: 2) { model.toggleGroupExpanded(tag.name) }
        // Single-click → select only (honoring ⌘/⇧). A group header isn't a file,
        // so clickRow won't open anything; isDirectory:false keeps it from being
        // treated as a real folder.
        .onTapGesture {
            model.clickRow(id: id, isDirectory: false,
                           url: URL(fileURLWithPath: "/"),
                           command: NSEvent.modifierFlags.contains(.command),
                           shift: NSEvent.modifierFlags.contains(.shift))
        }
        // Drag a file onto this group → tag it with this group's name.
        .dropDestination(for: URL.self) { urls, _ in
            model.tag(urls, withTagNamed: tag.name)
            return true
        }
        .contextMenu {
            Button("Rename…", systemImage: "pencil") {
                renamingTag = TagRef(name: tag.name)
            }
            Menu("Recolor") {
                ForEach(0..<TagPalette.count, id: \.self) { i in
                    Button(TagPalette.swatch(at: i).name) {
                        model.store?.recolorTag(named: tag.name, colorIndex: i)
                    }
                }
            }
            Button("Copy Paths", systemImage: "doc.on.clipboard") {
                model.copyPaths(forGroupNamed: tag.name)
            }
            Divider()
            Button("Delete Group", systemImage: "trash", role: .destructive) {
                model.expandedGroups.remove(tag.name)
                model.store?.deleteTag(named: tag.name)
            }
        }
    }

    // MARK: File-under-group row

    @ViewBuilder private func groupFileRow(tagName: String, path: String) -> some View {
        let url = URL(fileURLWithPath: path)
        let id: String = GroupRowID.file(tagName: tagName, path: path)
        let name = model.displayNames[path] ?? url.lastPathComponent
        HStack(spacing: 6) {
            Spacer().frame(width: 12)   // align under the disclosure column
            Image(systemName: icon(forPath: path))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1).truncationMode(.middle)
                Text((path as NSString).deletingLastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .contentShape(Rectangle())
        .tag(id)
        .accessibilityLabel("\(name), in group \(tagName)")
        .accessibilityAddTraits(model.selectedRowIDs.contains(id) ? .isSelected : [])
        // Double-click → open the file in the document pane.
        .onTapGesture(count: 2) {
            model.selectedRowIDs = [id]
            model.selectedFile = url
        }
        // Single-click → select + open (honoring ⌘/⇧). clickRow decodes the
        // groupfile id to this real file URL via SidebarRow.decode, and because
        // isDirectory:false it sets selectedFile through the normal path.
        .onTapGesture {
            model.clickRow(id: id, isDirectory: false, url: url,
                           command: NSEvent.modifierFlags.contains(.command),
                           shift: NSEvent.modifierFlags.contains(.shift))
        }
        .contextMenu {
            Button("Open", systemImage: "doc.text") {
                model.selectedRowIDs = [id]
                model.selectedFile = url
            }
            Button("Copy Path", systemImage: "doc.on.clipboard") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([url as NSURL])
                pb.setString(PathExport.clipboardString(for: [url]), forType: .string)
            }
            Button("Remove from “\(tagName)”", systemImage: "tag.slash") {
                model.removeFromGroup(path: path, tagNamed: tagName)
            }
            Divider()
            Button("Reveal in Finder", systemImage: "magnifyingglass") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    // MARK: + New Group

    private var newGroupRow: some View {
        Button {
            newGroupName = ""
            newGroupPromptShown = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .frame(width: 12)
                Text("New Group")
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Create an empty group")
        .accessibilityLabel("New Group")
    }

    // MARK: Icon (mirrors FileRow's kind tinting, monochrome here)

    private func icon(forPath path: String) -> String {
        switch FileKind.detect(filename: (path as NSString).lastPathComponent) {
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
}

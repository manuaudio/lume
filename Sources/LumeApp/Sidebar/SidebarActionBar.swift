import SwiftUI
import LumeCore

/// Slim bottom bar shown when 2+ sidebar rows are selected. Section-agnostic
/// shell; the action SET branches on `model.selectionSection`. Mirrors the
/// per-row context menu (`RowMenu`) but for the whole multi-selection.
struct SidebarActionBar: View {
    let model: AppModel
    let hiddenPaths: Set<String>

    private var count: Int { model.selectedRowIDs.count }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(count) selected")
                .font(.caption).foregroundStyle(.secondary)

            Spacer(minLength: 0)

            // Copy Paths — always available.
            Button { model.copyPaths() } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .help("Copy Paths")

            // Tag… — bulk tag editor (existing MultiTagSheet).
            Button {
                model.notesOpenPath = nil
                model.editingTagsForSelection = true
            } label: {
                Image(systemName: "tag")
            }
            .help("Tag…")

            // Pin/Hide act on real files only — suppress them entirely for an
            // all-group-header/file selection (every id decodes to nil, so they'd
            // no-op). Copy Paths / Tag… stay (Tag… is still meaningful via paths).
            if model.selectionHasRealItems {
                if model.selectionSection == .browser {
                    // Browse: Pin (or Unpin if all already pinned).
                    let allPinned = model.selectionIsAllPinned
                    Button { allPinned ? model.unpinSelection() : model.pinSelection() } label: {
                        Image(systemName: allPinned ? "pin.slash" : "pin")
                    }
                    .help(allPinned ? "Unpin" : "Pin")
                } else {
                    // Favorites: Unpin + Hide/Unhide curation.
                    Button { model.unpinSelection() } label: {
                        Image(systemName: "pin.slash")
                    }
                    .help("Unpin")

                    let allHidden = model.selectionIsAllHidden(hiddenPaths)
                    Button { model.setHiddenForSelection(!allHidden) } label: {
                        Image(systemName: allHidden ? "eye" : "eye.slash")
                    }
                    .help(allHidden ? "Un-hide" : "Hide")
                }
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
    }
}

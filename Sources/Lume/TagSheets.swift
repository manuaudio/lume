import SwiftUI
import LumeKit

private enum TriState { case on, off, mixed }

/// Tag every file in the current selection at once. Existing tags show their
/// applied state across the selection (on / mixed / off); toggling adds or
/// removes that tag from all selected files.
struct MultiTagSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var newTag = ""

    var body: some View {
        let common = app.commonTagNamesInSelection()
        let any = app.anyTagNamesInSelection()
        VStack(alignment: .leading, spacing: 12) {
            Text("Tag \(app.selectedURLs.count) item\(app.selectedURLs.count == 1 ? "" : "s")")
                .font(.headline)

            HStack {
                TextField("New tag", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addNew)
                Button("Add", action: addNew)
                    .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !app.tags.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(app.tags, id: \.name) { tag in
                            let state: TriState = common.contains(tag.name) ? .on
                                : (any.contains(tag.name) ? .mixed : .off)
                            Button {
                                if state == .on { app.removeTagFromSelection(tag.name) }
                                else { app.addTagToSelection(tag.name) }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: box(state))
                                        .foregroundStyle(state == .off ? .secondary : Color.tag(tag.colorIndex))
                                    Circle().fill(Color.tag(tag.colorIndex)).frame(width: 8, height: 8)
                                    Text(tag.name)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func box(_ s: TriState) -> String {
        switch s {
        case .on: return "checkmark.square.fill"
        case .mixed: return "minus.square.fill"
        case .off: return "square"
        }
    }

    private func addNew() {
        let n = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        app.addTagToSelection(n)
        newTag = ""
    }
}

/// Manage every tag: recolor, rename (renaming to an existing name merges),
/// and delete.
struct TagManagerSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: String?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Manage Tags").font(.headline)
            if app.tags.isEmpty {
                Text("No tags yet").foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(app.tags, id: \.name) { tag in
                            row(tag)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            Text("Tip: rename a tag to an existing tag's name to merge them.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 380)
    }

    @ViewBuilder private func row(_ tag: Tag) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(0..<TagPalette.count, id: \.self) { i in
                    Button(TagPalette.swatch(at: i).name) { app.recolorGroup(tag.name, colorIndex: i) }
                }
            } label: {
                Circle().fill(Color.tag(tag.colorIndex)).frame(width: 12, height: 12)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)

            if renaming == tag.name {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        _ = app.renameGroup(tag.name, to: renameText)
                        renaming = nil
                    }
            } else {
                Text(tag.name)
                Spacer()
                Text("\(tag.files.count)").font(.caption).foregroundStyle(.secondary)
                Button("Rename") { renaming = tag.name; renameText = tag.name }
                    .buttonStyle(.borderless)
                Button(role: .destructive) { app.deleteGroup(tag.name) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete tag \(tag.name)")
            }
        }
        .padding(.vertical, 2)
    }
}

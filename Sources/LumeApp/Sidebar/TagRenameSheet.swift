import SwiftUI

/// Identifiable wrapper so a tag name can drive a SwiftUI `.sheet(item:)`.
struct TagRef: Identifiable {
    let id = UUID()
    let name: String
}

/// Rename a tag. Renaming onto an existing tag MERGES them — the merge logic
/// lives in `LibraryStore.renameTag`, this sheet just collects the new name.
struct TagRenameSheet: View {
    let model: AppModel
    let oldName: String
    let onClose: () -> Void

    @State private var newName = ""
    @State private var didInit = false

    private var trimmed: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Tag").font(.headline)
            Text("Renaming to a tag that already exists merges them.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Tag name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || trimmed == oldName)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            // Seed once; `.onAppear` can re-fire and would clobber edits.
            if !didInit { newName = oldName; didInit = true }
        }
    }

    private func commit() {
        // On a successful rename/merge, migrate selection + expanded state so the
        // renamed group's selection and expansion survive the name change.
        if model.store?.renameTag(named: oldName, to: trimmed) == true {
            model.handleGroupRenamed(from: oldName, to: trimmed)
        }
        onClose()
    }
}

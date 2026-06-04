import SwiftUI
import SwiftData
import LumeCore
import LumeUI

struct MultiTagSheet: View {
    let model: AppModel
    @Binding var isPresented: Bool

    @Query private var allTags: [Tag]
    @State private var tagNames: [String] = []

    private func colorIndex(_ name: String) -> Int {
        allTags.first { $0.name == name }?.colorIndex ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Tags for \(model.selectedURLs.count) items")
                .font(.headline)
            Text("Applies to every selected item, replacing their tags.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TagField(names: $tagNames, colorIndex: colorIndex,
                     placeholder: "e.g. work, prod, review")
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    model.applyTagNamesToSelection(tagNames)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                // Replace-semantics: an empty Apply would WIPE every selected
                // file's tags (then orphan-prune the vocabulary). Disable it so an
                // accidental empty Apply can't destroy data. A deliberate
                // "clear all tags" would need its own explicit affordance.
                .disabled(tagNames.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
        // Seed the field with the selection's COMMON tags (intersection of each
        // file's current tags) so the user sees the shared state instead of an
        // empty field. With replace-semantics, intersection (not union) avoids
        // forcing a tag onto files that didn't already carry it.
        .onAppear { tagNames = model.commonTagNamesInSelection() }
    }
}

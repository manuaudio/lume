import SwiftUI
import SwiftData
import LumeCore

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
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

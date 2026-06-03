import SwiftUI

/// A small sheet that applies a comma-separated set of tags to every row in the
/// current multi-selection. The single-row inline editor (RowMetaView) is
/// unchanged; this is the multi-selection path.
struct MultiTagSheet: View {
    let model: AppModel
    @Binding var isPresented: Bool
    @State private var tagText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Tags for \(model.selectedURLs.count) items")
                .font(.headline)
            Text("Comma-separated. Applies to every selected item.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("e.g. work, prod, review", text: $tagText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    model.applyTagsToSelection(tagText)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

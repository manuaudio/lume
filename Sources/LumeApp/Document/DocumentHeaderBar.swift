import SwiftUI

/// One consistent chrome for every document-pane header bar — the tag header,
/// the structured-config header, and the .env header. Same material, padding,
/// and hairline separator so the top of the pane reads as a single continuous
/// toolbar regardless of the open file's type.
extension View {
    func documentHeaderBar() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
    }
}

/// The standard filename title used by every document header: primary color at
/// a semibold callout weight (never bold-but-grayed, which reads as disabled).
struct DocumentHeaderTitle: View {
    let filename: String
    var systemImage: String

    var body: some View {
        Label(filename, systemImage: systemImage)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
    }
}

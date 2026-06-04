import SwiftUI
import SwiftData
import LumeCore
import LumeUI

/// Content of the editor header's "+ add tag" popover. A focused text field
/// prefix-filters existing tags (with their file counts) and offers a
/// "Create '<draft>'" row for novel names. Picking or creating calls `onPick`
/// with the chosen name; the parent is responsible for persisting it onto the
/// file (so this view stays pure and reusable).
struct TagAddPopover: View {
    /// Names already on the file — excluded from suggestions, and used to decide
    /// whether "Create" should appear.
    let existingOnFile: [String]
    /// Called with the chosen (existing) or created (novel) tag name.
    let onPick: (String) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Tag.name) private var allTags: [Tag]
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var allNames: [String] { allTags.map(\.name) }

    private var suggestions: [String] {
        TagSuggest.suggestions(query: draft, allNames: allNames, existingOnFile: existingOnFile)
    }

    private var offersCreate: Bool {
        TagSuggest.shouldOfferCreate(query: draft, allNames: allNames, existingOnFile: existingOnFile)
    }

    /// File count for a tag name, via the store (reactive enough — the popover is
    /// short-lived and reopens fresh).
    private func count(_ name: String) -> Int {
        LibraryStore(context: context).files(taggedWith: name).count
    }

    private func pick(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onPick(trimmed)
        dismiss()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Add tag…", text: $draft)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($focused)
                .padding(8)
                .onSubmit {
                    // Return commits the top suggestion, else creates the draft.
                    if let first = suggestions.first { pick(first) }
                    else if offersCreate { pick(draft) }
                }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions, id: \.self) { name in
                        Button { pick(name) } label: {
                            HStack(spacing: 6) {
                                TagChip(name: name, colorIndex: colorIndex(name))
                                Spacer()
                                Text("\(count(name))")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if offersCreate {
                        if !suggestions.isEmpty { Divider() }
                        Button { pick(draft) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.secondary)
                                Text("Create “\(draft.trimmingCharacters(in: .whitespacesAndNewlines))”")
                                    .font(.callout)
                                Spacer()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if suggestions.isEmpty && !offersCreate {
                        Text(draft.isEmpty ? "No tags yet — type to create one."
                                           : "Already on this file.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .frame(width: 240)
        .onAppear { focused = true }
    }

    /// Live color for a name from the reactive @Query (0 until first saved).
    private func colorIndex(_ name: String) -> Int {
        allTags.first { $0.name == name }?.colorIndex ?? 0
    }
}

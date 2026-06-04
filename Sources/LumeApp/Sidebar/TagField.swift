import SwiftUI
import LumeCore

/// A token field for tags: existing tags render as removable colored chips, and
/// an inline text input commits a new tag on Return or comma. Binds to a
/// `[String]` of names; `colorIndex` resolves each name's color live so recolors
/// elsewhere reflect here. Pure UI — persistence is the caller's job (on change).
struct TagField: View {
    @Binding var names: [String]
    /// name → palette index (look up against a reactive @Query in the parent).
    let colorIndex: (String) -> Int
    var placeholder = "add tag"
    /// When non-nil, each chip's color dot becomes an inline recolor control;
    /// receives (tagName, newColorIndex). Nil = chips are not recolorable here.
    var recolor: ((String, Int) -> Void)? = nil

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(names, id: \.self) { name in
                TagChip(name: name,
                        colorIndex: colorIndex(name),
                        onRemove: { remove(name) },
                        onRecolor: recolor.map { fn in { idx in fn(name, idx) } })
            }
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(minWidth: 70)
                .focused($focused)
                .onSubmit(commitDraft)
                .onChange(of: draft) { _, value in
                    if value.contains(",") { commitDraft() }   // comma commits too
                }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    private func commitDraft() {
        let candidates = draft
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for c in candidates where !names.contains(c) { names.append(c) }
        draft = ""
    }

    private func remove(_ name: String) {
        names.removeAll { $0 == name }
    }
}

/// Minimal wrapping layout (a left-to-right flow that wraps to a new row when it
/// runs out of width). Used to lay out tag chips + the input.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        // In the unbounded case `x` includes a trailing `spacing`; drop it so the
        // reported content width isn't one gap too wide.
        let width = maxWidth == .infinity ? max(0, x - spacing) : maxWidth
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

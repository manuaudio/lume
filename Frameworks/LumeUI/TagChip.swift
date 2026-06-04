import SwiftUI
import LibraryKit

/// Bridge a stored `Tag.colorIndex` to a SwiftUI `Color` via the shared palette.
/// This is the ONLY place index → Color happens in the app.
public func tagColor(_ index: Int) -> Color {
    let s = TagPalette.swatch(at: index)
    return Color(red: s.red, green: s.green, blue: s.blue)
}

/// A compact colored pill for a single tag. When `onRemove` is non-nil an ✕
/// button appears (editable contexts). When `onRecolor` is non-nil the color dot
/// becomes a button that opens a swatch popover for inline recolor.
public struct TagChip: View {
    let name: String
    let colorIndex: Int
    var onRemove: (() -> Void)?
    var onRecolor: ((Int) -> Void)?

    @State private var pickingColor = false

    public init(
        name: String,
        colorIndex: Int,
        onRemove: (() -> Void)? = nil,
        onRecolor: ((Int) -> Void)? = nil
    ) {
        self.name = name
        self.colorIndex = colorIndex
        self.onRemove = onRemove
        self.onRecolor = onRecolor
    }

    public var body: some View {
        HStack(spacing: 4) {
            colorDot
            Text(name).font(.caption).lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove tag")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tagColor(colorIndex).opacity(0.18)))
        .overlay(Capsule().strokeBorder(tagColor(colorIndex).opacity(0.55), lineWidth: 1))
    }

    @ViewBuilder private var colorDot: some View {
        let dot = Circle().fill(tagColor(colorIndex)).frame(width: 7, height: 7)
        if let onRecolor {
            Button { pickingColor = true } label: { dot }
                .buttonStyle(.plain)
                .help("Change color")
                .popover(isPresented: $pickingColor, arrowEdge: .bottom) {
                    TagSwatchPicker(current: colorIndex) { idx in
                        onRecolor(idx)
                        pickingColor = false
                    }
                }
        } else {
            dot
        }
    }
}

/// A horizontal row of the 8 palette swatches. The current color is ringed.
/// Reused by the chip recolor popover and (as a Menu) the sidebar context menu.
public struct TagSwatchPicker: View {
    var current: Int
    let onPick: (Int) -> Void

    public init(current: Int, onPick: @escaping (Int) -> Void) {
        self.current = current
        self.onPick = onPick
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<TagPalette.count, id: \.self) { i in
                Button { onPick(i) } label: {
                    Circle()
                        .fill(tagColor(i))
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle().strokeBorder(
                                .primary,
                                lineWidth: i == TagPalette.wrap(current) ? 2 : 0)
                        )
                }
                .buttonStyle(.plain)
                .help(TagPalette.swatch(at: i).name)
            }
        }
        .padding(8)
    }
}

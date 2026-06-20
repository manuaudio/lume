import SwiftUI
import LumeKit

/// A directional diff between two copies of a config file, with push/pull.
/// `left` is treated as the canonical side; arrows show truth flowing toward
/// the other copy.
struct DriftBandView: View {
    @Environment(AppState.self) private var app
    let left: ConfigFile
    let right: ConfigFile

    @State private var lines: [DiffLine] = []
    @State private var loadFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                sourceLabel(left.ref)
                Text("≠").foregroundStyle(ConfigRadarPalette.drift)
                sourceLabel(right.ref)
                Spacer()
            }
            .font(.system(.caption, design: .monospaced))

            if loadFailed {
                Text("Couldn't read one of the copies.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                diffBody
            }

            HStack(spacing: 12) {
                Button("Push \(app.displayName(for: left.ref.sourceID)) →") {
                    Task { await app.reconcile(from: left.ref, to: right.ref) }
                }
                Button("← Pull \(app.displayName(for: right.ref.sourceID))") {
                    Task { await app.reconcile(from: right.ref, to: left.ref) }
                }
                Spacer()
                Button("Open left") { app.openConfig(left.ref) }
                Button("Open right") { app.openConfig(right.ref) }
            }
            .font(.caption)
            .buttonStyle(.link)
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: "\(left.ref.path)|\(right.ref.path)") { await load() }
    }

    private var diffBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(prefix(line.kind) + line.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(color(line.kind))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxHeight: 180)
    }

    private func sourceLabel(_ ref: ResourceRef) -> some View {
        Text(app.displayName(for: ref.sourceID))
            .foregroundStyle(ConfigRadarPalette.canonical)
    }

    private func prefix(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added:   return "+ "
        case .removed: return "- "
        case .same:    return "  "
        }
    }

    private func color(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added:   return ConfigRadarPalette.added
        case .removed: return ConfigRadarPalette.removed
        case .same:    return .secondary
        }
    }

    private func load() async {
        loadFailed = false
        do {
            let l = try await app.source(for: left.ref.sourceID).read(left.ref.path)
            let r = try await app.source(for: right.ref.sourceID).read(right.ref.path)
            lines = LineDiff.compute(from: l, to: r)
        } catch {
            loadFailed = true
        }
    }
}

import SwiftUI
import LumeKit

/// Unified, colored line diff of `canonical` vs `target`, with an overwrite action.
struct DiffView: View {
    @Environment(AppState.self) private var app
    let canonical: URL
    let target: URL

    @State private var lines: [DiffLine] = []
    @State private var unreadable = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if unreadable {
                ContentUnavailableView("Can't Diff", systemImage: "exclamationmark.triangle",
                    description: Text("This file isn't readable as text."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                diffBody
            }
        }
        .task(id: "\(canonical.path)|\(target.path)") { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
            Text(target.lastPathComponent).font(.headline)
            Text("vs canonical \(canonical.lastPathComponent)")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { app.requestOverwrite(target) } label: {
                Label("Overwrite with canonical", systemImage: "arrow.down.doc")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }

    private var diffBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 8) {
                        Text(gutter(line.kind)).foregroundStyle(.secondary)
                        Text(line.text.isEmpty ? " " : line.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 1)
                    .background(background(line.kind))
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func gutter(_ kind: DiffLine.Kind) -> String {
        switch kind { case .same: return " "; case .added: return "+"; case .removed: return "-" }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .same: return .clear
        case .added: return Color.green.opacity(0.18)
        case .removed: return Color.red.opacity(0.18)
        }
    }

    private func load() async {
        let c = canonical, t = target
        let computed = await Task.detached(priority: .userInitiated) { () -> [DiffLine]? in
            guard let canonText = try? String(contentsOf: c, encoding: .utf8),
                  let targetText = try? String(contentsOf: t, encoding: .utf8) else { return nil }
            return LineDiff.compute(from: targetText, to: canonText)
        }.value
        if let computed { lines = computed; unreadable = false }
        else { lines = []; unreadable = true }
    }
}

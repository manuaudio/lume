import SwiftUI
import AppKit
import LumeKit

/// List + live preview triage screen for an active Scan.
/// ↑↓ moves focus, Space ticks the focused file, buttons copy the ticked set.
struct ScanTriageView: View {
    @Environment(AppState.self) private var app
    @FocusState private var listFocused: Bool
    @State private var preview = ""
    @State private var sizes: [String: Int] = [:]
    @State private var sortBySize = false

    var body: some View {
        HSplitView {
            fileList
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
            previewPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .top) { header }
        .safeAreaInset(edge: .bottom) { actionBar }
        .onAppear { listFocused = true }
        .task(id: app.scanFocusURL) { await loadPreview(app.scanFocusURL) }
        .task(id: app.scanResults) { await loadSizes(app.scanResults) }
        .task(id: "\(app.canonicalURL?.path ?? "none")|\(app.scanResults.map(\.path).joined(separator: "|"))") {
            await app.recomputeSyncStatus()
        }
        .confirmationDialog(
            overwritePrompt,
            isPresented: Binding(
                get: { app.pendingOverwrite != nil },
                set: { if !$0 { app.cancelOverwrite() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Overwrite", role: .destructive) { app.confirmOverwrite() }
            Button("Cancel", role: .cancel) { app.cancelOverwrite() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
            Text(app.activeScan?.name ?? "Scan").font(.headline)
            if app.isScanning { ProgressView().controlSize(.small) }
            Spacer()
            Button { sortBySize.toggle() } label: {
                Label("Sort by size", systemImage: "arrow.up.arrow.down")
            }
            .help(sortBySize ? "Sorting by token size" : "Sort by token size")
            .tint(sortBySize ? .accentColor : nil)
            if app.canonicalURL != nil && !app.differingURLs.isEmpty {
                Button { app.requestOverwriteAllDiffering() } label: {
                    Label("Overwrite all differing (\(app.differingURLs.count))", systemImage: "arrow.down.doc.fill")
                }
            }
            Button { app.rescanActive() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
            Button { app.closeScan() } label: { Label("Close", systemImage: "xmark") }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }

    private var fileList: some View {
        List(selection: Binding(
            get: { app.scanFocusURL },
            set: { app.scanFocusURL = $0 }
        )) {
            ForEach(displayedResults, id: \.self) { url in
                HStack(spacing: 8) {
                    Image(systemName: app.isTicked(url) ? "checkmark.square.fill" : "square")
                        .foregroundStyle(app.isTicked(url) ? Color.accentColor : .secondary)
                        .onTapGesture { app.toggleTick(url) }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            if app.canonicalURL?.path == url.path {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(.tint).font(.caption)
                            }
                            Text(url.lastPathComponent).font(.body)
                                .fontWeight(app.canonicalURL?.path == url.path ? .semibold : .regular)
                        }
                        Text(parentLabel(url)).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if app.canonicalURL != nil {
                        syncBadge(for: url)
                    } else {
                        Text(TokenEstimator.format(sizes[url.path]))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(url)
                .contextMenu {
                    if app.canonicalURL?.path == url.path {
                        Button("Clear Canonical") { app.setCanonical(nil) }
                    } else {
                        Button("Set as Canonical") { app.setCanonical(url) }
                    }
                }
            }
        }
        .focused($listFocused)
        .onKeyPress(.space) { app.toggleTickFocused(); return .handled }
        .overlay {
            if !app.isScanning && app.scanResults.isEmpty {
                ContentUnavailableView("No Matches", systemImage: "magnifyingglass",
                                       description: Text("No files matched this scan's patterns."))
            }
        }
    }

    @ViewBuilder
    private var previewPane: some View {
        if let focus = app.scanFocusURL, let canonical = app.canonicalURL, canonical.path != focus.path {
            DiffView(canonical: canonical, target: focus)
        } else if app.scanFocusURL != nil {
            ScrollView {
                Text(preview)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        } else {
            ContentUnavailableView("Nothing Selected", systemImage: "doc",
                                   description: Text("Pick a file to preview it."))
        }
    }

    private var actionBar: some View {
        HStack {
            Text("\(app.tickedURLs.count) ticked").foregroundStyle(.secondary)
            Spacer()
            Button { app.copyTickedPaths() } label: {
                Label(app.tickedURLs.isEmpty ? "Copy Paths" : "Copy \(app.tickedURLs.count) Paths",
                      systemImage: "doc.on.clipboard")
            }
            .disabled(app.tickedURLs.isEmpty)
            Button { app.copyTickedAsContext() } label: {
                Label("Copy as Context", systemImage: "doc.text")
            }
            .disabled(app.tickedURLs.isEmpty)
            Button { app.copyTickedAsPrompt() } label: {
                Label("Copy as Prompt", systemImage: "text.bubble")
            }
            .disabled(app.tickedURLs.isEmpty)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }

    private func parentLabel(_ url: URL) -> String {
        url.deletingLastPathComponent().lastPathComponent
    }

    private var overwritePrompt: String {
        let n = app.pendingOverwrite?.targets.count ?? 0
        return "Overwrite \(n) file\(n == 1 ? "" : "s") with the canonical file? This rewrites \(n == 1 ? "it" : "them") on disk (⌘Z to undo)."
    }

    @ViewBuilder
    private func syncBadge(for url: URL) -> some View {
        switch app.syncStatus[url.path] {
        case .canonical:
            Text("canonical").font(.caption2).foregroundStyle(.tint)
        case .same:
            Label("same", systemImage: "checkmark").labelStyle(.iconOnly)
                .font(.caption).foregroundStyle(.green).help("Matches canonical")
        case .differs:
            Text("Δ").font(.caption).foregroundStyle(.orange).help("Differs from canonical")
        case .unreadable, .none:
            Text("·").font(.caption).foregroundStyle(.tertiary)
        }
    }

    /// Scan results in display order: by token size (desc) when the toggle is on.
    private var displayedResults: [URL] {
        guard sortBySize else { return app.scanResults }
        return app.scanResults.sorted { (sizes[$0.path] ?? 0) > (sizes[$1.path] ?? 0) }
    }

    private func loadSizes(_ urls: [URL]) async {
        let paths = urls.map(\.path)
        let computed = await detachedValue(priority: .utility) { () -> [String: Int] in
            var out: [String: Int] = [:]
            for p in paths {
                if let t = TokenEstimator.estimateFile(URL(fileURLWithPath: p)) { out[p] = t }
            }
            return out
        }
        guard let computed else { return } // cancelled: a newer scan-results task owns `sizes`
        sizes = computed
    }

    private func loadPreview(_ url: URL?) async {
        guard let url else { preview = ""; return }
        let text = await detachedValue(priority: .userInitiated) { () -> String in
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
                return "(binary or unreadable file — open in Finder to inspect)"
            }
            if raw.isEmpty { return "(empty file)" }
            let cap = 50_000
            return raw.count > cap ? String(raw.prefix(cap)) + "\n\n… (truncated)" : raw
        }
        guard let text else { return } // cancelled: a newer focus owns `preview`
        preview = text
    }
}

import SwiftUI
import AppKit
import LumeKit

/// List + live preview triage screen for an active Scan.
/// ↑↓ moves focus, Space ticks the focused file, buttons copy the ticked set.
struct ScanTriageView: View {
    @Environment(AppState.self) private var app
    @FocusState private var listFocused: Bool

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
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
            Text(app.activeScan?.name ?? "Scan").font(.headline)
            if app.isScanning { ProgressView().controlSize(.small) }
            Spacer()
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
            ForEach(app.scanResults, id: \.self) { url in
                HStack(spacing: 8) {
                    Image(systemName: app.isTicked(url) ? "checkmark.square.fill" : "square")
                        .foregroundStyle(app.isTicked(url) ? Color.accentColor : .secondary)
                        .onTapGesture { app.toggleTick(url) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent).font(.body)
                        Text(parentLabel(url)).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .tag(url)
            }
        }
        .focused($listFocused)
        .onKeyPress(.space) { app.toggleTickFocused(); return .handled }
        .onKeyPress(.upArrow) { app.moveScanFocus(by: -1); return .handled }
        .onKeyPress(.downArrow) { app.moveScanFocus(by: 1); return .handled }
        .overlay {
            if !app.isScanning && app.scanResults.isEmpty {
                ContentUnavailableView("No Matches", systemImage: "magnifyingglass",
                                       description: Text("No files matched this scan's patterns."))
            }
        }
    }

    @ViewBuilder
    private var previewPane: some View {
        if let url = app.scanFocusURL {
            ScrollView {
                Text(previewText(url))
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
                Label("Copy \(app.tickedURLs.count) Paths", systemImage: "doc.on.clipboard")
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

    private func previewText(_ url: URL) -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return text.isEmpty ? "(empty file)" : text
        }
        return "(binary or unreadable file — open in Finder to inspect)"
    }
}

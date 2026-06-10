import SwiftUI
import AppKit
import LumeKit

/// Detail pane for an open ContextBundle: editable name, file list with
/// missing-file markers, a token estimate, and a "Copy as Context" button.
struct BundleView: View {
    @Environment(AppState.self) private var app
    @State private var nameDraft = ""
    @State private var tokenEstimate = 0
    @State private var sizes: [String: Int] = [:]

    private let budgetWarnThreshold = 100_000

    private var bundle: ContextBundle? { app.activeBundle }

    /// URLs in the bundle that still exist on disk.
    private var existingURLs: [URL] {
        (bundle?.paths ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            fileList
            actionBar
        }
        // Re-seed the name draft per bundle identity (not just once on appear),
        // so switching bundles can't rename the previously-open one.
        .task(id: bundle?.id) { nameDraft = bundle?.name ?? "" }
        // Recompute when the path set OR the format changes; do the file I/O off-main.
        .task(id: estimateKey) { await recomputeEstimate() }
        .task(id: bundle?.paths) { await loadSizes(bundle?.paths ?? []) }
    }

    /// Identity for the estimate task: bundle + format + path set.
    private var estimateKey: String {
        "\(bundle?.id.uuidString ?? "")|\(app.contextFormat.rawValue)|\((bundle?.paths ?? []).joined(separator: "|"))"
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox")
            TextField("Bundle name", text: $nameDraft)
                .textFieldStyle(.plain)
                .font(.headline)
                .onSubmit { if let b = bundle { app.renameBundle(b, to: nameDraft) } }
            Spacer()
            Button { app.closeBundle() } label: { Label("Close", systemImage: "xmark") }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }

    private var fileList: some View {
        List {
            ForEach(bundle?.paths ?? [], id: \.self) { path in
                let url = URL(fileURLWithPath: path)
                let exists = FileManager.default.fileExists(atPath: path)
                HStack(spacing: 8) {
                    Image(systemName: exists ? "doc.text" : "exclamationmark.triangle.fill")
                        .foregroundStyle(exists ? Color.secondary : Color.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent).font(.body)
                            .foregroundStyle(exists ? .primary : .secondary)
                        Text(exists ? (path as NSString).abbreviatingWithTildeInPath : "missing — \(path)")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if exists {
                        Text(TokenEstimator.format(sizes[path]))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        if let b = bundle { app.removePath(path, from: b) }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                }
            }
        }
        .overlay {
            if (bundle?.paths ?? []).isEmpty {
                ContentUnavailableView("Empty Bundle", systemImage: "shippingbox",
                    description: Text("Add files via “New Bundle from Selection” or the Context menu."))
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Text("~\(tokenEstimate) tokens · \(existingURLs.count) files")
                .foregroundStyle(tokenEstimate > budgetWarnThreshold ? Color.orange : Color.secondary)
            Spacer()
            Button { app.copyAsContext(urls: existingURLs) } label: {
                Label("Copy as Context", systemImage: "doc.on.clipboard")
            }
            .disabled(existingURLs.isEmpty)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }

    private func recomputeEstimate() async {
        let urls = existingURLs
        let fmt = app.contextFormat
        let estimate = await detachedValue {
            ContextAssembler.assemble(urls, format: fmt).tokenEstimate
        }
        guard let estimate else { return } // cancelled: a newer estimateKey task owns this
        tokenEstimate = estimate
    }

    private func loadSizes(_ paths: [String]) async {
        let computed = await detachedValue(priority: .utility) { () -> [String: Int] in
            var out: [String: Int] = [:]
            for p in paths {
                if let t = TokenEstimator.estimateFile(URL(fileURLWithPath: p)) { out[p] = t }
            }
            return out
        }
        guard let computed else { return } // cancelled: a newer path set owns `sizes`
        sizes = computed
    }
}

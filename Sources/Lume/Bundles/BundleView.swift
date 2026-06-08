import SwiftUI
import AppKit
import LumeKit

/// Detail pane for an open ContextBundle: editable name, file list with
/// missing-file markers, a token estimate, and a "Copy as Context" button.
struct BundleView: View {
    @Environment(AppState.self) private var app
    @State private var nameDraft = ""
    @State private var tokenEstimate = 0

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
        .onAppear { nameDraft = bundle?.name ?? "" }
        .task(id: bundle?.paths) { recomputeEstimate() }
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
                .foregroundStyle(.secondary)
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

    private func recomputeEstimate() {
        tokenEstimate = ContextAssembler.assemble(existingURLs, format: app.contextFormat).tokenEstimate
    }
}

import SwiftUI
import WebKit

/// Read-only web view for `.html`. If the file is a Claude Cowork artifact
/// (needs a live connector bridge that only exists inside Claude), show a
/// native banner explaining why its data won't load — the HTML still renders.
struct HTMLViewer: View {
    let fileURL: URL

    @State private var isCoworkArtifact = false

    var body: some View {
        VStack(spacing: 0) {
            if isCoworkArtifact {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text("Claude artifact — needs live connectors, so its data won't load outside Claude.")
                        .font(.callout)
                    Spacer()
                }
                .foregroundStyle(.primary)
                .padding(8)
                .background(.yellow.opacity(0.18))
                Divider()
            }
            WebContent(fileURL: fileURL)
        }
        .task(id: fileURL) {
            isCoworkArtifact = await Self.detectCowork(at: fileURL)
        }
    }

    /// Reads only the first 8 KB off the main thread — the cowork-artifact-meta
    /// script always sits in <head>, well within that window. Non-UTF8 or
    /// unreadable files simply return false (no banner).
    private static func detectCowork(at url: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? fh.close() }
            let data = (try? fh.read(upToCount: 8192)) ?? Data()
            guard let prefix = String(data: data, encoding: .utf8) else { return false }
            return prefix.contains("id=\"cowork-artifact-meta\"")
                || prefix.contains("window.cowork")
        }.value
    }
}

/// The underlying `WKWebView` (unchanged behavior).
private struct WebContent: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        load(into: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url != fileURL { load(into: view) }
    }

    private func load(into view: WKWebView) {
        let url = fileURL
        ICloudCoordinator.ensureDownloaded(url) { [weak view] in
            view?.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }
}

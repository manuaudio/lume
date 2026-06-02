import SwiftUI
import WebKit

/// Read-only web view for `.html`. If the file is a Claude Cowork artifact
/// (needs a live connector bridge that only exists inside Claude), show a
/// native banner explaining why its data won't load — the HTML still renders.
struct HTMLViewer: View {
    let fileURL: URL

    private var isCoworkArtifact: Bool {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }
        return text.contains("id=\"cowork-artifact-meta\"") || text.contains("window.cowork")
    }

    var body: some View {
        VStack(spacing: 0) {
            if isCoworkArtifact {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text("Claude artifact — needs live connectors, so its data won't load outside Claude.")
                        .font(.callout)
                    Spacer()
                }
                .padding(8)
                .background(.yellow.opacity(0.18))
                Divider()
            }
            WebContent(fileURL: fileURL)
        }
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

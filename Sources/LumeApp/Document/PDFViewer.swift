import SwiftUI
import PDFKit

/// Renders a PDF with PDFKit. Read-only in v1.
struct PDFViewer: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        load(into: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != fileURL {
            load(into: view)
        }
    }

    private func load(into view: PDFView) {
        let url = fileURL
        ICloudCoordinator.ensureDownloaded(url) { [weak view] in
            view?.document = PDFDocument(url: url)
        }
    }
}

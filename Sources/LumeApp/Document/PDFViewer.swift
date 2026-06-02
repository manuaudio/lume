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
        ICloudCoordinator.ensureDownloaded(fileURL)
        view.document = PDFDocument(url: fileURL)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != fileURL {
            ICloudCoordinator.ensureDownloaded(fileURL)
            view.document = PDFDocument(url: fileURL)
        }
    }
}

import AppKit
import QuickLookUI
import SwiftUI

/// Shared Quick Look panel controller. `show(_:)` previews a file URL with the
/// native QLPreviewPanel (same as Finder's Space-bar preview).
@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()
    private var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem {
        MainActor.assumeIsolated {
            (url as NSURL?) ?? (URL(fileURLWithPath: "/") as NSURL)
        }
    }
}

/// Puts a responder-chain participant behind the sidebar so QLPreviewPanel can
/// find a controller and wire its data source at the correct phase.
struct QLHost: NSViewRepresentable {
    let controller: QuickLook
    func makeNSView(context: Context) -> QLHostView { QLHostView(controller: controller) }
    func updateNSView(_ nsView: QLHostView, context: Context) {}
}

@MainActor
final class QLHostView: NSView {
    let controller: QuickLook
    init(controller: QuickLook) {
        self.controller = controller
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = controller
            panel.delegate = controller
        }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}

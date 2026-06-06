import Foundation
import Observation
import LumeKit

@MainActor
@Observable
final class AppState {
    /// The currently open folder (root of the sidebar tree).
    private(set) var rootURL: URL?
    /// Top-level entries of the open folder (computed once on open, not in view body).
    private(set) var rootChildren: [FileNode] = []
    /// The file selected in the sidebar.
    var selectedURL: URL?
    /// The open document's text (bound to the editor). Nil when nothing/binary is selected.
    var documentText: String?
    /// Kind of the current selection, drives which detail view shows.
    private(set) var selectedKind: FileKind = .unsupported
    /// Whether the open document has unsaved edits.
    private(set) var isDirty = false
    /// A user-facing, non-fatal error message for the detail pane.
    private(set) var errorMessage: String?

    private var loadedText: String?
    private let files = FileService()

    /// Kinds Lume edits as plain text in the editor (others get a viewer/placeholder).
    static let textEditableKinds: Set<FileKind> = [.markdown, .env, .code]

    /// Open a folder as the new root. Persists it for next launch.
    func openFolder(_ url: URL) {
        rootURL = url
        selectedURL = nil
        documentText = nil
        errorMessage = nil
        rootChildren = children(of: url)
        Preferences.saveLastFolder(url)
    }

    /// Restore the last folder, if its bookmark still resolves.
    func restoreLastFolder() {
        guard let url = Preferences.loadLastFolder() else { return }
        _ = url.startAccessingSecurityScopedResource()
        openFolder(url)
    }

    /// Scan one directory level. Returns [] on failure (logged via errorMessage).
    func children(of url: URL) -> [FileNode] {
        do { return try files.enumerate(url) }
        catch {
            errorMessage = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
            return []
        }
    }

    /// Choose a file from the sidebar: highlight immediately, then load.
    func choose(_ url: URL) {
        selectedURL = url
        Task { await select(url) }
    }

    /// Select a file: load text if it's textual, else mark as non-text.
    func select(_ url: URL) async {
        selectedURL = url
        errorMessage = nil
        let kind = FileKind.detect(filename: url.lastPathComponent)
        selectedKind = kind
        let isConfig = ConfigRegistry.format(forFilename: url.lastPathComponent) != nil
        guard Self.textEditableKinds.contains(kind) || isConfig else {
            documentText = nil
            loadedText = nil
            isDirty = false
            return
        }
        do {
            let doc = try await TextDocument.load(url)
            documentText = doc.text
            loadedText = doc.text
            isDirty = false
        } catch {
            documentText = nil
            loadedText = nil
            errorMessage = "Couldn't open \(url.lastPathComponent) as text."
        }
    }

    /// Called by the editor when text changes.
    func documentTextChanged(_ newText: String) {
        documentText = newText
        isDirty = (newText != loadedText)
    }

    /// The currently-loaded on-disk text (for structured editors to parse).
    var currentText: String { documentText ?? "" }

    /// Save the open document back to disk.
    func save() {
        guard let url = selectedURL, let text = documentText, isDirty else { return }
        do {
            try TextDocument(url: url, text: text).save()
            loadedText = text
            isDirty = false
        } catch {
            errorMessage = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

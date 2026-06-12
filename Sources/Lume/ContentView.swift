import SwiftUI
import AppKit
import LumeKit

struct ContentView: View {
    @Environment(AppState.self) private var app
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            DetailView()
                .overlay(alignment: .top) {
                    VStack(spacing: 6) {
                        NoticeBanner()
                        PersistenceErrorBanner()
                    }
                }
                .animation(.easeOut(duration: 0.2), value: app.notice)
        }
        .modifier(ModifierPeekMonitor())
        // Route file-ops undo through the window's undo manager so the default
        // Edit ▸ Undo/Redo items (responder-chain based) can reach it.
        .onChange(of: undoManager, initial: true) { _, manager in
            app.attachUndoManager(manager)
        }
        .confirmationDialog(
            "This selection looks like it includes secrets (a sensitive filename, or credential-shaped content). Copy anyway?",
            isPresented: Binding(
                get: { app.pendingContextCopy != nil },
                set: { if !$0 { app.cancelPendingContextCopy() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Copy Anyway", role: .destructive) { app.confirmPendingContextCopy() }
            Button("Cancel", role: .cancel) { app.cancelPendingContextCopy() }
        }
    }
}

/// Transient overlay banner for `AppState.notice` (file-op failures, save
/// errors, overwrite reports). AppState auto-clears it; ✕ dismisses early.
private struct NoticeBanner: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let notice = app.notice {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(notice)
                    .font(.callout)
                    .lineLimit(3)
                    .truncationMode(.middle)
                Button { app.dismissNotice() } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Non-fatal "your library may not be persisting" banner, fed by
/// `LibraryStore.lastPersistenceError` (set by the save funnel).
private struct PersistenceErrorBanner: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let failure = app.library?.lastPersistenceError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
                Text("Your library couldn't save (\(failure.operation)): changes may not persist.")
                    .font(.callout)
                    .lineLimit(2)
                Button { app.library?.clearPersistenceError() } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Tracks the ⌃ key so the sidebar can briefly reveal hidden items while held.
private struct ModifierPeekMonitor: ViewModifier {
    @Environment(AppState.self) private var app
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    app.peeking = event.modifierFlags.contains(.control)
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

/// Chooses the right viewer for the current selection (DocumentRouter-style).
private struct DetailView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            if app.activeScan != nil {
                ScanTriageView()
            } else if app.activeBundle != nil {
                BundleView()
            } else if let message = app.errorMessage {
                ContentUnavailableView("Can't Open", systemImage: "exclamationmark.triangle", description: Text(message))
            } else if let remotePath = app.selectedRemotePath {
                remoteViewer(forPath: remotePath)
            } else if let url = app.selectedURL {
                VStack(spacing: 0) {
                    if app.showEditorTags {
                        DocumentTagBar(url: url)
                        Divider()
                    }
                    viewer(for: url)
                }
            } else {
                ContentUnavailableView("No File Selected", systemImage: "doc", description: Text("Pick a file in the sidebar."))
            }
        }
        .alert(
            "File Changed on GitHub",
            isPresented: Binding(
                get: { app.pendingConflictReloadPath != nil },
                set: { if !$0 { app.pendingConflictReloadPath = nil } }
            ),
            presenting: app.pendingConflictReloadPath
        ) { path in
            Button("Reload (Discard My Edits)", role: .destructive) {
                app.confirmConflictReload(path)
            }
            Button("Keep Editing", role: .cancel) {}
        } message: { path in
            Text("\((path as NSString).lastPathComponent) changed on GitHub since you opened it. Reload to get the latest version — your unsaved edits will be discarded. Keep editing to copy your changes out first.")
        }
    }

    @ViewBuilder
    private func viewer(for url: URL) -> some View {
        switch DocumentRouter.viewer(forFilename: url.lastPathComponent) {
        case .envEditor:
            EnvEditorView()
        case .configEditor:
            ConfigEditorView()
        case .markdownEditor, .codeViewer:
            if app.documentText != nil { EditorView() } else { loading }
        case .pdf:
            PDFViewer(url: url)
        case .image:
            ImageViewer(url: url)
        case .html:
            HTMLViewer(url: url)
        case .quickLook:
            QuickLookViewer(url: url)
        }
    }

    /// Remote files reuse the text-backed editors (they render `documentText`,
    /// which `selectRemote` filled). URL-backed viewers (PDF/image/HTML/
    /// QuickLook) need a local file — out of scope for the SSH MVP.
    @ViewBuilder
    private func remoteViewer(forPath path: String) -> some View {
        let name = (path as NSString).lastPathComponent
        Group {
            switch DocumentRouter.viewer(forFilename: name) {
            case .envEditor:
                EnvEditorView()
            case .configEditor:
                ConfigEditorView()
            case .markdownEditor, .codeViewer:
                if app.documentText != nil { EditorView() } else { loading }
            case .pdf, .image, .html, .quickLook:
                ContentUnavailableView(
                    "Text Files Only",
                    systemImage: "doc.text",
                    description: Text("\(name) can't be previewed on a remote source — only text and config files open remotely.")
                )
            }
        }
        .overlay(alignment: .topTrailing) {
            if app.isRemoteSaving {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Saving…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .padding(10)
            }
        }
    }

    private var loading: some View {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

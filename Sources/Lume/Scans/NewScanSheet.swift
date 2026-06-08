import SwiftUI
import AppKit
import LumeKit

/// Create or edit a Scan recipe: name, comma-separated patterns, and root folders.
struct NewScanSheet: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 16) {
            Text(app.editingScan == nil ? "New Scan" : "Edit Scan")
                .font(.headline)

            Form {
                TextField("Name", text: $app.scanDraftName, prompt: Text("My CLAUDE rules"))
                TextField("Patterns", text: $app.scanDraftPatterns,
                          prompt: Text("CLAUDE.md, memory.md, *.env"))
                    .help("Comma-separated filenames or globs (use * as a wildcard).")
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Roots").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Add Folder…") { addRoot() }
                }
                if app.scanDraftRoots.isEmpty {
                    Text("Add at least one folder to search.")
                        .font(.callout).foregroundStyle(.tertiary)
                } else {
                    ForEach(app.scanDraftRoots, id: \.self) { root in
                        HStack {
                            Image(systemName: "folder")
                            Text(root.path).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button {
                                app.scanDraftRoots.removeAll { $0 == root }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                        .font(.callout)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { app.presentingScanEditor = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { app.commitScanEditor() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(app.scanDraftRoots.isEmpty
                              || app.scanDraftPatterns.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !app.scanDraftRoots.contains(url) {
                app.scanDraftRoots.append(url)
            }
        }
    }
}

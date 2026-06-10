import SwiftUI
import LumeKit

/// The tag header shown above the open document: a chip per tag (removable) plus
/// an add-tag popover that suggests existing groups or creates a new one.
struct DocumentTagBar: View {
    let url: URL
    @Environment(AppState.self) private var app
    @State private var adding = false
    @State private var showingNotes = false

    var body: some View {
        let tags = app.tags(forPath: url.path)
        HStack(spacing: 6) {
            ForEach(tags, id: \.name) { tag in
                TagChip(tag: tag) { app.removeTag(tag.name, fromPath: url.path) }
            }
            Button { adding = true } label: {
                Label("Add Tag", systemImage: "tag").font(.caption)
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $adding, arrowEdge: .bottom) {
                AddTagPopover(url: url)
                    .id(url)   // reset popover state when the selection changes
            }
            Spacer()
            Button { showingNotes = true } label: {
                Label("Notes", systemImage: app.info(forPath: url.path).isEmpty ? "note.text" : "note.text.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Notes for this file")
            .popover(isPresented: $showingNotes, arrowEdge: .bottom) {
                NotesPopover(url: url)
                    .id(url)   // a selection change replaces (saves + reloads) the popover
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Free-text notes (FileMeta.info) for a file. Saved when the popover closes —
/// against the URL the notes were LOADED from, never whatever is selected at
/// dismissal (changing selection with the popover open must not cross-write
/// file A's notes onto file B).
private struct NotesPopover: View {
    let url: URL
    @Environment(AppState.self) private var app
    @State private var text = ""
    @State private var loadedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(width: 320, height: 160)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
        }
        .padding(12)
        .onAppear {
            if loadedURL == nil {
                text = app.info(forPath: url.path)
                loadedURL = url
            }
        }
        .onDisappear {
            if let loadedURL { app.setInfo(text, forPath: loadedURL.path) }
        }
    }
}

private struct TagChip: View {
    let tag: Tag
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(tag.name).font(.caption)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove tag \(tag.name)")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(Color.tag(tag.colorIndex))
        .background(Capsule().fill(Color.tag(tag.colorIndex).opacity(0.18)))
        .overlay(Capsule().stroke(Color.tag(tag.colorIndex).opacity(0.5), lineWidth: 1))
    }
}

private struct AddTagPopover: View {
    let url: URL
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("New or existing tag", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { commit(text) }

            let suggestions = filtered
            if !suggestions.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(suggestions, id: \.name) { tag in
                            Button { commit(tag.name) } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(Color.tag(tag.colorIndex)).frame(width: 8, height: 8)
                                    Text(tag.name)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
        .padding(12)
    }

    private var filtered: [Tag] {
        let all = app.tagSuggestions(forPath: url.path)
        let q = text.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private func commit(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        app.addTag(n, toPath: url.path)
        dismiss()
    }
}

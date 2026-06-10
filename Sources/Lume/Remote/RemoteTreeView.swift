import SwiftUI
import LumeKit

/// The sidebar when an SSH source is active: connection states, a go-to-path
/// field, per-host recent files, and a lazily-expanding remote tree.
struct RemoteTreeView: View {
    @Environment(AppState.self) private var app
    @State private var pathField = ""

    var body: some View {
        if let remote = app.remote {
            VStack(spacing: 0) {
                switch remote.phase {
                case .connecting:
                    Spacer()
                    ProgressView("Connecting to \(remote.host.alias)…")
                        .controlSize(.small)
                    Spacer()
                case .failed(let message):
                    Spacer()
                    ContentUnavailableView {
                        Label("Can't Connect", systemImage: "bolt.horizontal")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Retry") { Task { await remote.connect() } }
                            .buttonStyle(.borderedProminent)
                        Button("Disconnect") { app.disconnectRemote() }
                    }
                    Spacer()
                case .ready:
                    goToBar
                    Divider()
                    List {
                        if !recentFiles.isEmpty {
                            Section("Recent") {
                                ForEach(recentFiles, id: \.self) { path in
                                    Button {
                                        app.chooseRemote(path)
                                    } label: {
                                        Label {
                                            Text((path as NSString).lastPathComponent)
                                                .lineLimit(1)
                                        } icon: {
                                            Image(systemName: "clock")
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .help(path)
                                }
                            }
                        }
                        Section(remote.rootPath) {
                            RemoteChildrenRows(directory: remote.rootPath, depth: 0)
                        }
                    }
                    .listStyle(.sidebar)
                    .onChange(of: remote.lastError) { _, error in
                        if let error {
                            app.showNotice(error)
                            remote.lastError = nil
                        }
                    }
                }
            }
        }
    }

    private var recentFiles: [String] {
        guard let alias = app.remote?.host.alias else { return [] }
        return app.connections.state.hostState[alias]?.recentFiles ?? []
    }

    private var goToBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.right.circle")
                .foregroundStyle(.secondary)
            TextField("Go to path (/etc/nginx/nginx.conf)", text: $pathField)
                .textFieldStyle(.plain)
                .onSubmit {
                    app.goToRemotePath(pathField)
                    pathField = ""
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// One directory's rows; shows an inline spinner the first time a directory
/// is expanded (children load lazily, exactly like the local tree).
private struct RemoteChildrenRows: View {
    @Environment(AppState.self) private var app
    let directory: String
    let depth: Int

    var body: some View {
        if let remote = app.remote {
            if let nodes = remote.children[directory] {
                ForEach(nodes) { node in
                    RemoteNodeRow(node: node, depth: depth)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Loading…").foregroundStyle(.secondary)
                }
                .padding(.leading, CGFloat(depth) * 14)
                .task { await remote.loadChildren(of: directory) }
            }
        }
    }
}

private struct RemoteNodeRow: View {
    @Environment(AppState.self) private var app
    let node: ResourceNode
    let depth: Int

    var body: some View {
        if let remote = app.remote {
            if node.isDirectory {
                Button {
                    remote.toggleExpand(node.ref.path)
                } label: {
                    row(systemImage: "folder",
                        chevron: remote.expanded.contains(node.ref.path) ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)
                if remote.expanded.contains(node.ref.path) {
                    RemoteChildrenRows(directory: node.ref.path, depth: depth + 1)
                }
            } else {
                Button {
                    app.chooseRemote(node.ref.path)
                } label: {
                    row(systemImage: node.isSymlink ? "link" : "doc", chevron: nil)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var isSelected: Bool { app.selectedRemotePath == node.ref.path }

    private func row(systemImage: String, chevron: String?) -> some View {
        HStack(spacing: 5) {
            if let chevron {
                Image(systemName: chevron)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: systemImage)
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            Text(node.name)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .contentShape(Rectangle())
    }
}

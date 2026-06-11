import SwiftUI
import LumeKit

/// Compact header above the sidebar tree: shows the active source and switches
/// between Local, ~/.ssh/config hosts, saved manual connections, and new ones.
struct SourceSwitcherView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Button {
                    app.showLocalSource()
                } label: {
                    Label(localTitle, systemImage: "internaldrive")
                }
                if let remote = app.remote, !app.showingRemote {
                    Button {
                        app.showRemoteSource()
                    } label: {
                        Label(remote.host.alias, systemImage: "bolt.horizontal")
                    }
                }
                if !app.sshConfigAliases.isEmpty {
                    Section("~/.ssh/config") {
                        ForEach(app.sshConfigAliases, id: \.self) { alias in
                            Button(alias) { app.connectSSH(SSHHost(alias: alias)) }
                        }
                    }
                }
                if !app.connections.state.manualHosts.isEmpty {
                    Section("Saved Connections") {
                        ForEach(app.connections.state.manualHosts) { host in
                            Button(host.alias) { app.connectSSH(host) }
                        }
                    }
                }
                Divider()
                Button("New SSH Connection…") { app.presentingNewConnection = true }
                if app.remote != nil {
                    Button("Disconnect", role: .destructive) { app.disconnectRemote() }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: app.showingRemote ? "bolt.horizontal.circle.fill" : "internaldrive")
                        .foregroundStyle(app.showingRemote ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    Text(title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .onAppear { app.loadSSHConfigAliases() }

            Spacer(minLength: 4)
            statusAccessory
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var localTitle: String {
        if let root = app.rootURL { return "Local — \(root.lastPathComponent)" }
        return "Local"
    }

    private var title: String {
        if app.showingRemote, let remote = app.remote { return remote.host.alias }
        return localTitle
    }

    @ViewBuilder private var statusAccessory: some View {
        if app.showingRemote, let remote = app.remote {
            switch remote.phase {
            case .connecting:
                ProgressView().controlSize(.small)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("Connection failed")
            case .ready:
                EmptyView()
            }
        }
    }
}

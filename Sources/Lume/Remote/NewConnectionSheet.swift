import SwiftUI
import LumeKit

/// Manual connection entry for hosts not in ~/.ssh/config. Saved to the
/// ConnectionStore, then connected immediately.
struct NewConnectionSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var hostname = ""
    @State private var user = ""
    @State private var port = ""
    @State private var identityFile = ""
    @State private var alias = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New SSH Connection")
                .font(.headline)
            Form {
                TextField("Host", text: $hostname, prompt: Text("server.example.com"))
                TextField("User", text: $user, prompt: Text("optional — defaults to your ssh config"))
                TextField("Port", text: $port, prompt: Text("22"))
                TextField("Identity file", text: $identityFile, prompt: Text("~/.ssh/id_ed25519 (optional)"))
                TextField("Name", text: $alias, prompt: Text("defaults to the host"))
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(hostname.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func connect() {
        let trimmedHost = hostname.trimmingCharacters(in: .whitespaces)
        let name = alias.trimmingCharacters(in: .whitespaces)
        let host = SSHHost(
            alias: name.isEmpty ? trimmedHost : name,
            hostname: trimmedHost,
            user: user.isEmpty ? nil : user.trimmingCharacters(in: .whitespaces),
            port: Int(port.trimmingCharacters(in: .whitespaces)),
            identityFile: identityFile.isEmpty ? nil
                : NSString(string: identityFile.trimmingCharacters(in: .whitespaces)).expandingTildeInPath
        )
        app.connections.addManualHost(host)
        app.connectSSH(host)
        dismiss()
    }
}

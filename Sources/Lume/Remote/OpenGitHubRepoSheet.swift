import SwiftUI
import LumeKit

/// Manual repo entry: an "owner/repo" slug or a pasted github.com URL.
struct OpenGitHubRepoSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""

    private var parsed: GitHubRepoRef? { GitHubRepoRef(parsing: input) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open GitHub Repo")
                .font(.headline)
            TextField("owner/repo or github.com URL", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit(open)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open") { open() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func open() {
        guard let ref = parsed else { return }
        app.connectGitHub(ref)
        dismiss()
    }
}

import SwiftUI
import LumeKit

/// Searchable picker over the signed-in user's repos (`gh repo list`).
struct RepoBrowserSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var repos: [GitHubRepoSummary] = []
    @State private var filter = ""
    @State private var phase: Phase = .loading

    enum Phase: Equatable { case loading, ready, failed(String) }

    private var filtered: [GitHubRepoSummary] {
        guard !filter.isEmpty else { return repos }
        return repos.filter { $0.slug.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your GitHub Repos")
                .font(.headline)
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
            Group {
                switch phase {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Can't Load Repos", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    }
                case .ready:
                    List(filtered) { repo in
                        Button {
                            if let ref = GitHubRepoRef(parsing: repo.slug) {
                                app.connectGitHub(ref)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Text(repo.slug).lineLimit(1)
                                Spacer()
                                if repo.isPrivate {
                                    Image(systemName: "lock.fill")
                                        .foregroundStyle(.secondary)
                                        .help("Private")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minHeight: 280)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 420)
        .task {
            do {
                repos = try await app.githubClient.listUserRepos()
                phase = .ready
            } catch {
                phase = .failed((error as? GitHubError)?.userMessage ?? error.localizedDescription)
            }
        }
    }
}

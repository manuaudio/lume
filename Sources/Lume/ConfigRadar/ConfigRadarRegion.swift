import SwiftUI

/// Sidebar entry that opens the Config Radar triage surface.
struct ConfigRadarRegion: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Section {
            Button {
                app.startConfigRadar()
            } label: {
                Label("Config Radar", systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(.plain)
        }
    }
}

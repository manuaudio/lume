import SwiftUI
import LumeKit

struct ConfigTriageView: View {
    @Environment(AppState.self) private var app

    private var actionable: [ConfigFinding] { app.configFindings.filter { $0.severity == .drift } }
    private var resolved: [ConfigFinding] { app.configFindings.filter { $0.severity != .drift } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if app.isScanningConfig && app.configFindings.isEmpty {
                ProgressView("Scanning sources…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if app.configFindings.isEmpty {
                ContentUnavailableView(
                    "Everything's in sync",
                    systemImage: "checkmark.seal",
                    description: Text("No config files found yet. Open a folder or connect a remote, then rescan.")
                )
            } else {
                List {
                    if !actionable.isEmpty {
                        Section("Needs you") {
                            ForEach(actionable) { DriftRowView(finding: $0) }
                        }
                    }
                    if !resolved.isEmpty {
                        Section("\(resolved.count) in sync") {
                            ForEach(resolved) { finding in
                                InSyncRowView(finding: finding)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Config Radar").font(.headline)
            Spacer()
            Text("\(resolved.count) in sync · \(actionable.count) need you")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Button {
                Task { await app.runConfigRadar() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(app.isScanningConfig)
        }
        .padding(12)
    }
}

/// A quiet row for in-sync / lone findings (no drift band).
struct InSyncRowView: View {
    @Environment(AppState.self) private var app
    let finding: ConfigFinding

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(finding.severity == .inSync ? ConfigRadarPalette.canonical : ConfigRadarPalette.gap)
                .frame(width: 7, height: 7)
            Text(finding.group.key)
                .font(.system(.body, design: .monospaced))
            Spacer()
            Text(finding.severity == .inSync
                 ? "\(finding.group.copies.count) copies match"
                 : "1 copy")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let ref = finding.group.copies.first?.ref { app.openConfig(ref) }
        }
    }
}

/// Minimal placeholder — Task 7 replaces this with the full drift band
/// (expandable diff). For now the row shows severity dot + title only.
struct DriftRowView: View {
    let finding: ConfigFinding
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(ConfigRadarPalette.drift).frame(width: 7, height: 7)
            Text(finding.group.key).font(.system(.body, design: .monospaced))
            Spacer()
            Text("\(finding.group.copies.count) copies differ").font(.caption).foregroundStyle(.secondary)
        }
    }
}

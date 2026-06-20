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

struct DriftRowView: View {
    @Environment(AppState.self) private var app
    let finding: ConfigFinding

    private var isExpanded: Bool { app.expandedFindingKeys.contains(finding.group.key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if isExpanded { app.expandedFindingKeys.remove(finding.group.key) }
                else { app.expandedFindingKeys.insert(finding.group.key) }
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(ConfigRadarPalette.drift).frame(width: 7, height: 7)
                    Text("DRIFT")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(ConfigRadarPalette.drift)
                    Text(finding.group.key)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Text("\(finding.group.copies.count) copies differ")
                        .font(.caption).foregroundStyle(.secondary)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                // One band per adjacent pair of copies (first copy is the anchor).
                ForEach(Array(finding.group.copies.dropFirst().enumerated()), id: \.offset) { _, copy in
                    DriftBandView(left: finding.group.copies[0], right: copy)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

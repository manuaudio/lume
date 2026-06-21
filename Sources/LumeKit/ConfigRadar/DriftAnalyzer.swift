import Foundation

/// A classified config group: what state are its copies in?
public struct ConfigFinding: Identifiable, Sendable {
    public enum Severity: Sendable, Equatable {
        case drift    // 2+ readable copies that differ
        case lone     // fewer than 2 readable copies (nothing to compare)
        case inSync   // 2+ readable copies, all identical
    }

    public let group: ConfigGroup
    public let severity: Severity

    public init(group: ConfigGroup, severity: Severity) {
        self.group = group
        self.severity = severity
    }

    public var id: String { group.key }
}

public enum DriftAnalyzer {
    /// Reads each copy via `read` and classifies the group. Copies whose read
    /// throws are excluded. Fewer than 2 readable copies → `.lone`; all equal
    /// → `.inSync`; otherwise `.drift`.
    public static func analyze(
        _ group: ConfigGroup,
        read: (ResourceRef) async throws -> String
    ) async -> ConfigFinding {
        var texts: [String] = []
        for copy in group.copies {
            if let text = try? await read(copy.ref) {
                texts.append(text)
            }
        }
        let severity: ConfigFinding.Severity
        if texts.count < 2 {
            severity = .lone
        } else if texts.dropFirst().allSatisfy({ $0 == texts[0] }) {
            severity = .inSync
        } else {
            severity = .drift
        }
        return ConfigFinding(group: group, severity: severity)
    }
}

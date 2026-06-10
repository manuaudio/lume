import Foundation

/// One connectable host. A pure-config host carries only `alias` (ssh resolves
/// user/port/keys from ~/.ssh/config); a manual host carries explicit fields.
public struct SSHHost: Codable, Hashable, Sendable, Identifiable {
    public var alias: String         // display name + ControlPath key
    public var hostname: String?     // nil → alias is resolved by ssh config
    public var user: String?
    public var port: Int?
    public var identityFile: String?

    public var id: String { alias }

    public init(alias: String, hostname: String? = nil, user: String? = nil,
                port: Int? = nil, identityFile: String? = nil) {
        self.alias = alias
        self.hostname = hostname
        self.user = user
        self.port = port
        self.identityFile = identityFile
    }

    /// The destination argument: "user@host" for manual hosts, bare alias otherwise.
    public var destination: String {
        let target = hostname ?? alias
        if let user, !user.isEmpty { return "\(user)@\(target)" }
        return target
    }

    /// Explicit CLI flags. The port flag differs by tool: ssh uses "-p",
    /// sftp uses "-P" — the caller passes the right spelling.
    public func flags(portFlag: String) -> [String] {
        var flags: [String] = []
        if let port { flags += [portFlag, String(port)] }
        if let identityFile, !identityFile.isEmpty { flags += ["-i", identityFile] }
        return flags
    }
}

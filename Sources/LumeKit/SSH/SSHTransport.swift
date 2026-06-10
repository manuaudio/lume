import Foundation

/// One host's connection: establishes an ssh ControlMaster (auth happens once,
/// natively prompted if needed) and runs sftp batches that multiplex over it.
public actor SSHTransport {
    public let host: SSHHost
    private let runner: CommandRunning
    private let controlDir: URL

    public static var defaultControlDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lume/ssh", isDirectory: true)
    }

    public init(host: SSHHost, runner: CommandRunning = ProcessRunner(),
                controlDir: URL = SSHTransport.defaultControlDir) {
        self.host = host
        self.runner = runner
        self.controlDir = controlDir
    }

    /// Control socket filename must be filesystem-safe whatever the alias is.
    /// Replaces `/` and `:` with `-`.
    private static func socketName(for alias: String) -> String {
        alias
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            + ".sock"
    }

    private var controlPath: String {
        controlDir.appendingPathComponent(Self.socketName(for: host.alias)).path
    }

    /// -o options shared by ssh and sftp: every process multiplexes over the
    /// one authenticated master keyed by this host's control socket.
    private var controlOptions: [String] {
        ["-o", "ControlMaster=auto",
         "-o", "ControlPath=\(controlPath)",
         "-o", "ControlPersist=600",
         "-o", "ConnectTimeout=15"]
    }

    /// Establish (or reuse) the master. `-fN` backgrounds after auth, so this
    /// returns once the connection is usable. Generous timeout: the user may
    /// be typing a passphrase into the askpass prompt.
    public func connect() async throws {
        try? FileManager.default.createDirectory(at: controlDir, withIntermediateDirectories: true)
        let args = controlOptions + host.flags(portFlag: "-p") + ["-fN", host.destination]
        let result = try await runner.run("/usr/bin/ssh", args, stdin: nil,
                                          environment: Self.askpassEnvironment(controlDir: controlDir),
                                          timeout: 120)
        guard result.exitCode == 0 else {
            throw SSHError.map(exitCode: result.exitCode, stderr: result.stderr, path: nil)
        }
    }

    /// Run an sftp batch over the master and return its stdout. If the master
    /// died underneath us, reconnect once transparently, then surface errors.
    /// `path` attributes file-level failures (permission denied / not found).
    public func sftp(_ commands: [String], path: String? = nil,
                     timeout: TimeInterval = 30) async throws -> String {
        do {
            return try await sftpOnce(commands, path: path, timeout: timeout)
        } catch SSHError.connectionLost {
            try await connect()
            return try await sftpOnce(commands, path: path, timeout: timeout)
        }
    }

    private func sftpOnce(_ commands: [String], path: String?,
                          timeout: TimeInterval) async throws -> String {
        let batch = commands.joined(separator: "\n") + "\n"
        let args = controlOptions + host.flags(portFlag: "-P")
            + ["-q", "-b", "-", host.destination]
        let result = try await runner.run("/usr/bin/sftp", args, stdin: Data(batch.utf8),
                                          environment: nil, timeout: timeout)
        guard result.exitCode == 0 else {
            throw SSHError.map(exitCode: result.exitCode, stderr: result.stderr, path: path)
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    /// Whether the master is still alive (`ssh -O check`).
    public func isAlive() async -> Bool {
        let args = controlOptions + ["-O", "check", host.destination]
        let result = try? await runner.run("/usr/bin/ssh", args, stdin: nil,
                                           environment: nil, timeout: 10)
        return result?.exitCode == 0
    }

    /// Tear down the master (`ssh -O exit`). Best-effort.
    public func disconnect() async {
        let args = controlOptions + ["-O", "exit", host.destination]
        _ = try? await runner.run("/usr/bin/ssh", args, stdin: nil,
                                  environment: nil, timeout: 10)
    }

    /// Native passphrase/password prompting: ssh has no TTY here, so point
    /// SSH_ASKPASS at a tiny osascript helper (written once, chmod 755).
    /// "prefer" lets ssh-agent answer silently when it can.
    static func askpassEnvironment(controlDir: URL) -> [String: String] {
        let script = controlDir.appendingPathComponent("lume-askpass.sh")
        if !FileManager.default.fileExists(atPath: script.path) {
            // NOTE: the osascript invocation is on one line to avoid any
            // ambiguity with backslash line-continuation inside a Swift
            // multi-line string literal. The \" sequences below survive Swift
            // string processing and land in the script file as literal \" so
            // the shell sees properly quoted osascript arguments.
            let body = """
            #!/bin/sh
            # Lume's SSH askpass: native dialog for passphrases/passwords.
            PROMPT=$(printf '%s' "$1" | tr '"' "'")
            exec /usr/bin/osascript -e "display dialog \\"$PROMPT\\" default answer \\"\\" with hidden answer with title \\"Lume — SSH\\" buttons {\\"Cancel\\",\\"OK\\"} default button \\"OK\\"" -e 'text returned of result'
            """
            try? FileManager.default.createDirectory(at: controlDir, withIntermediateDirectories: true)
            try? body.write(to: script, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: script.path)
        }
        return ["SSH_ASKPASS": script.path, "SSH_ASKPASS_REQUIRE": "prefer"]
    }
}

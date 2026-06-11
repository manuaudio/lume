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

    /// Options for control commands (-O check / -O exit) that talk to an
    /// existing master only. Omits ControlMaster=auto + ControlPersist to
    /// avoid accidentally spawning a new master on a stale socket.
    private var controlCommandOptions: [String] {
        ["-o", "ControlPath=\(controlPath)"]
    }

    /// Establish (or reuse) the master. `-fN` backgrounds after auth, so this
    /// returns once the connection is usable. Generous timeout: the user may
    /// be typing a passphrase into the askpass prompt.
    public func connect() async throws {
        try? FileManager.default.createDirectory(at: controlDir, withIntermediateDirectories: true)
        // Fix 1: "--" prevents a destination beginning with "-" from being
        // parsed as an ssh flag (e.g. alias "-oProxyCommand=evil").
        let args = controlOptions + host.flags(portFlag: "-p") + ["-fN", "--", host.destination]
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
        // Fix 1: "--" end-of-options guard before destination.
        let args = controlOptions + host.flags(portFlag: "-P")
            + ["-q", "-b", "-", "--", host.destination]
        // Fix 5: pass askpass env so auth can proceed if ControlMaster=auto
        // silently respawns a master during an sftp call.
        let result = try await runner.run("/usr/bin/sftp", args, stdin: Data(batch.utf8),
                                          environment: Self.askpassEnvironment(controlDir: controlDir),
                                          timeout: timeout)
        guard result.exitCode == 0 else {
            throw SSHError.map(exitCode: result.exitCode, stderr: result.stderr, path: path)
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    /// Whether the master is still alive (`ssh -O check`).
    public func isAlive() async -> Bool {
        // Fix 4: use controlCommandOptions (no ControlMaster=auto) so we only
        // probe the existing master and never spawn a fresh one.
        let args = controlCommandOptions + ["-O", "check", "--", host.destination]
        let result = try? await runner.run("/usr/bin/ssh", args, stdin: nil,
                                           environment: nil, timeout: 10)
        return result?.exitCode == 0
    }

    /// Tear down the master (`ssh -O exit`). Best-effort.
    public func disconnect() async {
        // Fix 4: same as isAlive — control commands only; no ControlMaster=auto.
        let args = controlCommandOptions + ["-O", "exit", "--", host.destination]
        _ = try? await runner.run("/usr/bin/ssh", args, stdin: nil,
                                  environment: nil, timeout: 10)
    }

    /// Native passphrase/password prompting: ssh has no TTY here, so point
    /// SSH_ASKPASS at a tiny osascript helper (written once, chmod 755).
    /// "prefer" lets ssh-agent answer silently when it can.
    static func askpassEnvironment(controlDir: URL) -> [String: String] {
        let script = controlDir.appendingPathComponent("lume-askpass.sh")
        if !FileManager.default.fileExists(atPath: script.path) {
            // Fix 2: prompt is passed as argv[1] — never interpolated into the
            // shell command string. The heredoc form <<'LUME_EOF' passes it to
            // osascript via stdin with no variable expansion, so $(...),
            // backticks, and backslashes in the prompt cannot execute or escape.
            let body = """
            #!/bin/sh
            # Lume's SSH askpass: native dialog. Prompt passes as argv — never interpolated.
            exec /usr/bin/osascript - "$1" <<'LUME_EOF'
            on run argv
                set p to item 1 of argv
                display dialog p default answer "" with hidden answer with title "Lume — SSH" buttons {"Cancel", "OK"} default button "OK"
                return text returned of result
            end run
            LUME_EOF
            """
            try? FileManager.default.createDirectory(at: controlDir, withIntermediateDirectories: true)
            try? body.write(to: script, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: script.path)
        }
        // Fix 3: older macOS / vendored OpenSSH checks DISPLAY before
        // honouring SSH_ASKPASS_REQUIRE; inject a fallback when not set.
        var env: [String: String] = ["SSH_ASKPASS": script.path, "SSH_ASKPASS_REQUIRE": "prefer"]
        if ProcessInfo.processInfo.environment["DISPLAY"] == nil {
            env["DISPLAY"] = ":0"
        }
        return env
    }
}

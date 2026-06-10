import Foundation

/// The exit state of one finished subprocess.
public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Subprocess seam for the SSH layer: everything above this protocol is
/// unit-testable with a fake; only `ProcessRunner` touches real processes.
public protocol CommandRunning: Sendable {
    /// Run `executable` with `arguments`; feed `stdin` (then close it); merge
    /// `environment` over the inherited one. Throws `SSHError.timeout` if the
    /// process outlives `timeout` seconds (it gets terminated).
    func run(_ executable: String, _ arguments: [String], stdin: Data?,
             environment: [String: String]?, timeout: TimeInterval) async throws -> CommandResult
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], stdin: Data?,
                    environment: [String: String]?, timeout: TimeInterval) async throws -> CommandResult {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try box.launchAndWait(executable: executable, arguments: arguments,
                                      stdin: stdin, environment: environment, timeout: timeout)
            }.value
        } onCancel: {
            box.terminate()
        }
    }
}

/// Wraps `Process` so termination can be requested across threads.
/// @unchecked: `terminate()` is thread-safe; the lock guards our own fields.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var timedOut = false

    func terminate() {
        lock.lock(); defer { lock.unlock() }
        process?.terminate()
    }

    private func markTimedOutAndTerminate() {
        lock.lock(); defer { lock.unlock() }
        timedOut = true
        process?.terminate()
    }

    func launchAndWait(executable: String, arguments: [String], stdin: Data?,
                       environment: [String: String]?, timeout: TimeInterval) throws -> CommandResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let environment {
            p.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, new in new }
        }
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = inPipe

        lock.lock(); process = p; lock.unlock()
        try p.run()

        if let stdin { try? inPipe.fileHandleForWriting.write(contentsOf: stdin) }
        try? inPipe.fileHandleForWriting.close()

        // Deadline watchdog — waitUntilExit has no timeout of its own.
        let watchdog = DispatchWorkItem { [weak self] in self?.markTimedOutAndTerminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // Drain stderr concurrently so a full pipe buffer (>64 KB) can't
        // deadlock against our sequential stdout read.
        let stderrBox = DataBox()
        let stderrDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            stderrBox.data = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            stderrDone.signal()
        }
        let stdout = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        stderrDone.wait()
        p.waitUntilExit()
        watchdog.cancel()

        lock.lock()
        let didTimeOut = timedOut
        process = nil
        lock.unlock()
        if didTimeOut { throw SSHError.timeout(executable: executable) }
        return CommandResult(exitCode: p.terminationStatus, stdout: stdout, stderr: stderrBox.data)
    }
}

/// Mutable Data crossing a queue boundary; ordering guaranteed by the semaphore.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

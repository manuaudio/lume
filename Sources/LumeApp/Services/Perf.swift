import Foundation
import os

/// TEMPORARY perf instrumentation for diagnosing open-path latency.
/// `log show --last 2m --predicate 'subsystem == "com.lume.perf"' --info` shows
/// the marks. Remove once profiled.
enum Perf {
    static let logger = Logger(subsystem: "com.lume.perf", category: "open")

    static func mark(_ label: String) {
        let ms = ProcessInfo.processInfo.systemUptime * 1000
        logger.log("\(String(format: "%10.1f", ms), privacy: .public)ms | \(label, privacy: .public)")
        print("PERF \(String(format: "%10.1f", ms))ms | \(label)")
        fflush(stdout)
    }

    @discardableResult
    static func measure<T>(_ label: String, _ body: () -> T) -> T {
        let t0 = ProcessInfo.processInfo.systemUptime
        let r = body()
        let dt = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        logger.log("\(String(format: "%8.1f", dt), privacy: .public)ms (dur) | \(label, privacy: .public)")
        return r
    }
}

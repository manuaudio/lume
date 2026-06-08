import Testing
import Foundation
@testable import LumeKit

private func makeTempTree() throws -> URL {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("scan-test-\(UUID().uuidString)")
    let projA = root.appendingPathComponent("projA")
    let projB = root.appendingPathComponent("projB/nested")
    let noise = root.appendingPathComponent("projA/node_modules/pkg")
    let git = root.appendingPathComponent("projA/.git")
    for dir in [projA, projB, noise, git] {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    try "a".write(to: projA.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
    try "b".write(to: projA.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    try "c".write(to: projB.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
    try "d".write(to: projA.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try "e".write(to: noise.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8) // ignored dir
    try "f".write(to: git.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)   // ignored dir
    return root
}

@Test func sweepFindsMatchesAcrossRootsSkippingIgnoredDirs() throws {
    let root = try makeTempTree()
    defer { try? FileManager.default.removeItem(at: root) }

    let results = ScanEngine.run(patterns: ["CLAUDE.md", "*.env"], roots: [root])
    let names = results.map { $0.lastPathComponent }

    // Two CLAUDE.md (projA, projB/nested) + one .env. README excluded.
    // node_modules and .git CLAUDE.md excluded.
    #expect(results.count == 3)
    #expect(names.filter { $0 == "CLAUDE.md" }.count == 2)
    #expect(names.contains(".env"))
    #expect(!results.contains { $0.path.contains("node_modules") })
    #expect(!results.contains { $0.path.contains(".git/") })
}

@Test func emptyPatternsMatchNothing() throws {
    let root = try makeTempTree()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(ScanEngine.run(patterns: [], roots: [root]).isEmpty)
}

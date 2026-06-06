import Testing
import Foundation
@testable import LumeKit

struct FolderScannerTests {
    /// Build a temp directory tree and return its root URL.
    private func makeTree() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("lume-scan-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("zeta-dir"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("alpha-dir"), withIntermediateDirectories: true)
        try "hi".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "hi".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "hi".write(to: root.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        return root
    }

    @Test func sortsDirectoriesFirstThenName() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let nodes = try FolderScanner().scan(root)
        #expect(nodes.map(\.name) == ["alpha-dir", "zeta-dir", "a.txt", "b.txt"])
        #expect(nodes.first?.isDirectory == true)
    }

    @Test func skipsHiddenByDefault() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let nodes = try FolderScanner().scan(root)
        #expect(!nodes.contains { $0.name == ".hidden" })
    }

    @Test func includesHiddenWhenAsked() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let nodes = try FolderScanner().scan(root, includeHidden: true)
        #expect(nodes.contains { $0.name == ".hidden" })
    }
}

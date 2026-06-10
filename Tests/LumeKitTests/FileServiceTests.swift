import Testing
import Foundation
@testable import LumeKit

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("LumeFileServiceTest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func symlinkedDirectoryIsListedAsLeafNotDirectory() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let target = dir.appendingPathComponent("real", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try "x".write(to: target.appendingPathComponent("inner.md"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
        at: dir.appendingPathComponent("link"), withDestinationURL: target)

    let nodes = try FileService().enumerate(dir, includeHidden: false)

    let link = try #require(nodes.first { $0.name == "link" })
    #expect(link.isSymlink)
    // Leaf row: the sidebar only enumerates nodes with isDirectory == true,
    // so the link's target can never be expanded in the browser.
    #expect(!link.isDirectory)

    let real = try #require(nodes.first { $0.name == "real" })
    #expect(real.isDirectory)
    #expect(!real.isSymlink)
}

@Test func symlinkedFileIsStillListedAndMarked() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("a.md")
    try "x".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
        at: dir.appendingPathComponent("alias.md"), withDestinationURL: file)

    let nodes = try FileService().enumerate(dir, includeHidden: false)
    #expect(nodes.map(\.name).contains("alias.md"))
    let alias = try #require(nodes.first { $0.name == "alias.md" })
    #expect(alias.isSymlink)
    #expect(!alias.isDirectory)
}

@Test func regularNodesAreNotMarkedSymlink() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try "x".write(to: dir.appendingPathComponent("plain.md"), atomically: true, encoding: .utf8)

    let nodes = try FileService().enumerate(dir, includeHidden: false)
    #expect(nodes.allSatisfy { !$0.isSymlink })
}

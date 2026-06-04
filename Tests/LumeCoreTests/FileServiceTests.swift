import Testing
import Foundation
@testable import FileSystemKit

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("LumeTest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func readWriteRoundTrip() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("note.md")
    let service = FileService()

    try service.write("# Hello", to: file)
    #expect(try service.read(file) == "# Hello")

    try service.write("# Changed", to: file)
    #expect(try service.read(file) == "# Changed")
}

@Test func enumerateFiltersNoiseAndSortsFoldersFirst() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fm = FileManager.default
    try "x".write(to: dir.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
    try "x".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    try "x".write(to: dir.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
    try "x".write(to: dir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    try fm.createDirectory(at: dir.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
    try fm.createDirectory(at: dir.appendingPathComponent("clients"), withIntermediateDirectories: true)

    let nodes = try FileService().enumerate(dir)
    let names = nodes.map { $0.url.lastPathComponent }

    // node_modules, .DS_Store, .gitignore are filtered; .env is kept.
    #expect(!names.contains("node_modules"))
    #expect(!names.contains(".DS_Store"))
    #expect(!names.contains(".gitignore"))
    #expect(names.contains(".env"))
    // Folders first (alpha), then files (alpha): clients, .env, b.md
    #expect(names == ["clients", ".env", "b.md"])
    #expect(nodes.first?.isDirectory == true)
}

@Test func enumerateIncludeHiddenRevealsDotfilesButNotNoise() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fm = FileManager.default
    try "x".write(to: dir.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
    try "x".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    try "x".write(to: dir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    try "x".write(to: dir.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
    try fm.createDirectory(at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    try fm.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try fm.createDirectory(at: dir.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
    try fm.createDirectory(at: dir.appendingPathComponent("clients"), withIntermediateDirectories: true)

    let names = try FileService().enumerate(dir, includeHidden: true).map { $0.url.lastPathComponent }

    // Dotfiles/dotfolders are now revealed…
    #expect(names.contains(".claude"))
    #expect(names.contains(".gitignore"))
    #expect(names.contains(".env"))
    // …but explicit noise stays filtered even when showing hidden.
    #expect(!names.contains(".DS_Store"))
    #expect(!names.contains("node_modules"))
    #expect(!names.contains(".git"))
    #expect(!names.contains(".build"))
    // Folders first (alpha incl. dotfolders), then files (alpha).
    #expect(names == [".claude", "clients", ".env", ".gitignore", "b.md"])
}

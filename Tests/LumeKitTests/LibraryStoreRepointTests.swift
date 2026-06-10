import Testing
import SwiftData
@testable import LumeKit

@MainActor @Test func repointMovesFileMetaAndFavorite() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/p/a.md", info: "note", tagNames: ["work"], displayName: "A")
    store.addFavorite(path: "/p/a.md", kind: .markdown)
    store.setHidden(true, paths: ["/p/a.md"])

    store.repointPath(from: "/p/a.md", to: "/p/renamed.md")

    #expect(store.meta(for: "/p/a.md") == nil)
    let moved = try #require(store.meta(for: "/p/renamed.md"))
    #expect(moved.info == "note")
    #expect(moved.displayName == "A")
    #expect(moved.hidden == true)
    #expect(moved.tags.map(\.name) == ["work"])
    #expect(store.isFavorite(path: "/p/a.md") == false)
    #expect(store.isFavorite(path: "/p/renamed.md") == true)
}

@MainActor @Test func repointDirectoryMovesDescendantsButNotPrefixSiblings() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/a/b", info: "dir itself", tagNames: [])
    store.setMeta(path: "/a/b/deep/x.md", info: "descendant", tagNames: [])
    store.setMeta(path: "/a/bc/y.md", info: "prefix sibling", tagNames: [])
    store.addFavoriteFolder(path: "/a/b")

    store.repointPath(from: "/a/b", to: "/a/z")

    #expect(store.meta(for: "/a/z")?.info == "dir itself")
    #expect(store.meta(for: "/a/z/deep/x.md")?.info == "descendant")
    // "/a/bc" merely shares the "/a/b" character prefix — untouched.
    #expect(store.meta(for: "/a/bc/y.md")?.info == "prefix sibling")
    #expect(store.isFavorite(path: "/a/z") == true)
}

@MainActor @Test func repointUpdatesScanRootsCanonicalAndBundlePaths() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }

    let scan = store.addScan(name: "S", patterns: ["CLAUDE.md"], roots: ["/old/root", "/other"])
    store.setCanonical("/old/root/CLAUDE.md", for: scan)
    let bundle = store.addBundle(name: "B", paths: ["/old/root/CLAUDE.md", "/other/.env"])

    store.repointPath(from: "/old/root", to: "/new/root")

    #expect(scan.roots == ["/new/root", "/other"])
    #expect(scan.canonicalPath == "/new/root/CLAUDE.md")
    #expect(bundle.paths == ["/new/root/CLAUDE.md", "/other/.env"])
}

@MainActor @Test func repointResolvesDestinationClashInFavorOfMovedRow() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/dst.md", info: "stale destination", tagNames: [])
    store.setMeta(path: "/src.md", info: "rich source", tagNames: ["keep"])

    store.repointPath(from: "/src.md", to: "/dst.md")

    let survivor = try #require(store.meta(for: "/dst.md"))
    #expect(survivor.info == "rich source")
    #expect(survivor.tags.map(\.name) == ["keep"])
    #expect(store.meta(for: "/src.md") == nil)
}

@MainActor @Test func repointNoOpsOnDegenerateInput() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }

    store.setMeta(path: "/a.md", info: "x", tagNames: [])
    store.repointPath(from: "/a.md", to: "/a.md")   // same path
    store.repointPath(from: "", to: "/b.md")        // empty source
    #expect(store.meta(for: "/a.md")?.info == "x")
    #expect(store.lastPersistenceError == nil)
}

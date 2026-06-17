import Testing
import SwiftData
@testable import LumeKit

@MainActor @Test func addAndQueryRemoteFavorite() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }
    #expect(store.isRemoteFavorite(ref: "ssh:web1:/etc/x") == false)
    store.addRemoteFavorite(ref: "ssh:web1:/etc/x", sourceKind: "ssh",
                            sourceKey: "web1", path: "/etc/x", isDirectory: false)
    #expect(store.isRemoteFavorite(ref: "ssh:web1:/etc/x"))
    #expect(store.remoteFavorites().map(\.path) == ["/etc/x"])
}

@MainActor @Test func addRemoteFavoriteIsIdempotentOnRef() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }
    store.addRemoteFavorite(ref: "github:o/r:/a.md", sourceKind: "github",
                            sourceKey: "o/r", path: "/a.md", isDirectory: false)
    store.addRemoteFavorite(ref: "github:o/r:/a.md", sourceKind: "github",
                            sourceKey: "o/r", path: "/a.md", isDirectory: false)
    #expect(store.remoteFavorites().count == 1)
}

@MainActor @Test func removeRemoteFavorite() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }
    store.addRemoteFavorite(ref: "ssh:web1:/a", sourceKind: "ssh",
                            sourceKey: "web1", path: "/a", isDirectory: true)
    store.removeRemoteFavorite(ref: "ssh:web1:/a")
    #expect(store.remoteFavorites().isEmpty)
}

@MainActor @Test func twoHostsSamePathAreDistinct() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }
    store.addRemoteFavorite(ref: "ssh:web1:/etc/nginx.conf", sourceKind: "ssh",
                            sourceKey: "web1", path: "/etc/nginx.conf", isDirectory: false)
    store.addRemoteFavorite(ref: "ssh:web2:/etc/nginx.conf", sourceKind: "ssh",
                            sourceKey: "web2", path: "/etc/nginx.conf", isDirectory: false)
    #expect(store.remoteFavorites().count == 2)
}

@MainActor @Test func reorderAllFavoritesRewritesSharedSortIndex() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }
    store.addFavorite(path: "/local.md", kind: .markdown)                  // sortIndex 0
    store.addRemoteFavorite(ref: "ssh:web1:/r", sourceKind: "ssh",
                            sourceKey: "web1", path: "/r", isDirectory: false)  // sortIndex 1
    // Interleave: remote first, then local.
    store.reorderAllFavorites([.remote(ref: "ssh:web1:/r"), .local(path: "/local.md")])
    #expect(store.remoteFavorites().first?.sortIndex == 0)
    #expect(store.favorites().first?.sortIndex == 1)
}

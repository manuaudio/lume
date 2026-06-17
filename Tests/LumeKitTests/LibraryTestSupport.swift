import SwiftData
@testable import LumeKit

// NOTE: `makeLibrary()` returns the `ModelContainer` alongside the store, and
// each test pins it with `defer { withExtendedLifetime(container) {} }` for its
// whole body. `LibraryStore` only holds a `ModelContext`, and on this toolchain
// (Apple Swift 6.3.2, macOS 26 SDK) a `ModelContext` whose owning in-memory
// `ModelContainer` has been deallocated crashes with SIGTRAP on the next
// SwiftData operation. In the real app the container is owned by the SwiftUI
// `.modelContainer` scene for the app's lifetime, so this only affects the test
// helper — hence the lifetime is pinned at call sites rather than changing the
// `LibraryStore(context:)` public API.
//
// The container registers the FULL versioned schema (LumeSchemaV2), never a
// subset: per-file model subsets are what let three helpers drift apart, and
// the app never runs against a partial schema anyway.
@MainActor
func makeLibrary() throws -> (store: LibraryStore, container: ModelContainer) {
    let container = try ModelContainer(
        for: Schema(versionedSchema: LumeSchemaV2.self),
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
    )
    return (LibraryStore(context: container.mainContext), container)
}

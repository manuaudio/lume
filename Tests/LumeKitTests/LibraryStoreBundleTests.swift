import Testing
import SwiftData
@testable import LumeKit

@MainActor @Test func bundleModelPersistsFields() throws {
    let (_, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }
    let context = container.mainContext

    let bundle = ContextBundle(name: "Prod context", paths: ["/p/CLAUDE.md", "/p/.env"])
    context.insert(bundle)
    try context.save()

    let fetched = try context.fetch(FetchDescriptor<ContextBundle>())
    #expect(fetched.count == 1)
    #expect(fetched.first?.name == "Prod context")
    #expect(fetched.first?.paths == ["/p/CLAUDE.md", "/p/.env"])
}

@MainActor @Test func bundleCRUDViaStore() throws {
    let (store, container) = try makeLibrary()
    defer { withExtendedLifetime(container) {} }

    let a = store.addBundle(name: "A", paths: ["/x/CLAUDE.md"])
    let b = store.addBundle(name: "B", paths: ["/y/.env"])
    #expect(store.bundles().map(\.name) == ["A", "B"])
    #expect(b.sortIndex == 1)

    store.renameBundle(a, to: "A2")
    store.setBundlePaths(["/x/CLAUDE.md", "/x/memory.md"], for: a)
    let updated = store.bundles().first { $0.id == a.id }
    #expect(updated?.name == "A2")
    #expect(updated?.paths == ["/x/CLAUDE.md", "/x/memory.md"])

    store.removeBundle(b)
    #expect(store.bundles().map(\.name) == ["A2"])
}

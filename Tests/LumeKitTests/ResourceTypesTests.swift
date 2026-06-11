import Testing
import Foundation
@testable import LumeKit

struct ResourceTypesTests {
    @Test func refNameIsLastPathComponent() {
        let ref = ResourceRef(sourceID: .ssh(alias: "web1"), path: "/etc/nginx/nginx.conf")
        #expect(ref.name == "nginx.conf")
    }

    @Test func nodeIdentityIsItsRef() {
        let ref = ResourceRef(sourceID: .local, path: "/tmp/a.md")
        let node = ResourceNode(ref: ref, isDirectory: false)
        #expect(node.id == ref)
        #expect(node.name == "a.md")
        #expect(node.children == nil)
    }

    @Test func sourceIDsDistinguishHosts() {
        #expect(SourceID.ssh(alias: "a") != SourceID.ssh(alias: "b"))
        #expect(SourceID.local == SourceID.local)
    }
}

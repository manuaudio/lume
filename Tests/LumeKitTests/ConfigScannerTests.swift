import Testing
import Foundation
@testable import LumeKit

@Test func findsConfigsAtRootAndNested() async {
    let src = FakeFileSource(
        id: .local,
        dirs: [
            "/proj": [node(.local, "/proj/CLAUDE.md", dir: false),
                      node(.local, "/proj/src", dir: true),
                      node(.local, "/proj/readme.txt", dir: false)],
            "/proj/src": [node(.local, "/proj/src/.env", dir: false)],
        ],
        files: ["/proj/CLAUDE.md": "a", "/proj/src/.env": "K=V"]
    )
    let found = await ConfigScanner.scan(source: src, roots: ["/proj"])
    let paths = found.map(\.ref.path)
    #expect(paths == ["/proj/CLAUDE.md", "/proj/src/.env"])
}

@Test func skipsIgnoredDirectories() async {
    let src = FakeFileSource(
        id: .local,
        dirs: [
            "/proj": [node(.local, "/proj/node_modules", dir: true),
                      node(.local, "/proj/CLAUDE.md", dir: false)],
            "/proj/node_modules": [node(.local, "/proj/node_modules/CLAUDE.md", dir: false)],
        ],
        files: ["/proj/CLAUDE.md": "a", "/proj/node_modules/CLAUDE.md": "b"]
    )
    let found = await ConfigScanner.scan(source: src, roots: ["/proj"])
    #expect(found.map(\.ref.path) == ["/proj/CLAUDE.md"])
}

@Test func skipsSymlinkedDirectories() async {
    let src = FakeFileSource(
        id: .local,
        dirs: [
            "/proj": [node(.local, "/proj/link", dir: true, symlink: true)],
            "/proj/link": [node(.local, "/proj/link/CLAUDE.md", dir: false)],
        ],
        files: ["/proj/link/CLAUDE.md": "a"]
    )
    let found = await ConfigScanner.scan(source: src, roots: ["/proj"])
    #expect(found.isEmpty)
}

@Test func matchesEnvVariantsNotUnrelatedFiles() async {
    let src = FakeFileSource(
        id: .local,
        dirs: ["/p": [node(.local, "/p/.env", dir: false),
                      node(.local, "/p/.env.local", dir: false),
                      node(.local, "/p/notes.md", dir: false),
                      node(.local, "/p/.environment", dir: false)]],
        files: ["/p/.env": "", "/p/.env.local": "", "/p/notes.md": "", "/p/.environment": ""]
    )
    let found = await ConfigScanner.scan(source: src, roots: ["/p"])
    #expect(found.map(\.ref.path) == ["/p/.env", "/p/.env.local"])
}

@Test func recordsSizeFromStat() async {
    let src = FakeFileSource(
        id: .local,
        dirs: ["/p": [node(.local, "/p/CLAUDE.md", dir: false)]],
        files: ["/p/CLAUDE.md": "hello"]
    )
    let found = await ConfigScanner.scan(source: src, roots: ["/p"])
    #expect(found.first?.size == 5)
}

import Testing
import Foundation
@testable import LumeKit

@Test func scannerFindsPathScopedConfig() async {
    let src = FakeFileSource(
        id: .local,
        dirs: [
            "/proj": [node(.local, "/proj/.claude", dir: true),
                      node(.local, "/proj/settings.json", dir: false)],  // bare — must be ignored
            "/proj/.claude": [node(.local, "/proj/.claude/settings.json", dir: false)],
        ],
        files: ["/proj/settings.json": "{}", "/proj/.claude/settings.json": "{\"x\":1}"]
    )
    let found = await ConfigScanner.scan(source: src, roots: ["/proj"])
    let paths = found.map(\.ref.path)
    #expect(paths.contains("/proj/.claude/settings.json"))
    #expect(!paths.contains("/proj/settings.json"))
}

@Test func scannerFindsNewFilenamePatterns() async {
    let src = FakeFileSource(
        id: .local,
        dirs: ["/p": [node(.local, "/p/.nvmrc", dir: false),
                      node(.local, "/p/llms.txt", dir: false),
                      node(.local, "/p/.windsurfrules", dir: false),
                      node(.local, "/p/random.txt", dir: false)]],
        files: ["/p/.nvmrc": "20", "/p/llms.txt": "x", "/p/.windsurfrules": "y", "/p/random.txt": "z"]
    )
    let found = await ConfigScanner.scan(source: src, roots: ["/p"])
    let paths = found.map(\.ref.path)
    #expect(paths.contains("/p/.nvmrc"))
    #expect(paths.contains("/p/llms.txt"))
    #expect(paths.contains("/p/.windsurfrules"))
    #expect(!paths.contains("/p/random.txt"))
}

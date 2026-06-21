import Testing
import Foundation
@testable import LumeKit

private func file(_ id: SourceID, _ path: String) -> ConfigFile {
    ConfigFile(ref: ResourceRef(sourceID: id, path: path), size: nil)
}

@Test func singleCopyIsLone() async {
    let group = ConfigGroup(key: "claude.md", copies: [file(.local, "/a/CLAUDE.md")])
    let finding = await DriftAnalyzer.analyze(group) { _ in "x" }
    #expect(finding.severity == .lone)
}

@Test func identicalCopiesAreInSync() async {
    let group = ConfigGroup(key: "claude.md", copies: [
        file(.local, "/a/CLAUDE.md"),
        file(.ssh(alias: "prod"), "/srv/CLAUDE.md"),
    ])
    let finding = await DriftAnalyzer.analyze(group) { _ in "same" }
    #expect(finding.severity == .inSync)
}

@Test func differingCopiesAreDrift() async {
    let group = ConfigGroup(key: "claude.md", copies: [
        file(.local, "/a/CLAUDE.md"),
        file(.ssh(alias: "prod"), "/srv/CLAUDE.md"),
    ])
    let finding = await DriftAnalyzer.analyze(group) { ref in
        ref.path == "/a/CLAUDE.md" ? "local" : "remote"
    }
    #expect(finding.severity == .drift)
}

@Test func unreadableCopyIsExcludedLeavingLone() async {
    let group = ConfigGroup(key: "claude.md", copies: [
        file(.local, "/a/CLAUDE.md"),
        file(.ssh(alias: "prod"), "/srv/CLAUDE.md"),
    ])
    let finding = await DriftAnalyzer.analyze(group) { ref in
        if ref.path == "/srv/CLAUDE.md" { throw CancellationError() }
        return "local"
    }
    #expect(finding.severity == .lone)
}

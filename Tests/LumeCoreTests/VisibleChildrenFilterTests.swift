import Foundation
import Testing
import FileSystemKit

@Suite("VisibleChildrenFilter")
struct VisibleChildrenFilterTests {
    private func node(_ path: String, dir: Bool = false) -> FileNode {
        FileNode(url: URL(fileURLWithPath: path), isDirectory: dir)
    }

    @Test("filesOnly drops directories")
    func filesOnly() {
        let out = VisibleChildrenFilter.apply(
            [node("/a.md"), node("/sub", dir: true)],
            filesOnly: true, isPinned: false,
            showPinnedHidden: false, hiddenPaths: [], browseFilter: "")
        #expect(out.map(\.url.path) == ["/a.md"])
    }

    @Test("pinned section hides hidden paths unless reveal is on")
    func pinnedHidden() {
        let nodes = [node("/keep.md"), node("/secret.md")]
        let hidden: Set<String> = ["/secret.md"]
        let off = VisibleChildrenFilter.apply(nodes, filesOnly: false, isPinned: true,
                                              showPinnedHidden: false, hiddenPaths: hidden, browseFilter: "")
        #expect(off.map(\.url.path) == ["/keep.md"])
        let on = VisibleChildrenFilter.apply(nodes, filesOnly: false, isPinned: true,
                                             showPinnedHidden: true, hiddenPaths: hidden, browseFilter: "")
        #expect(on.map(\.url.path) == ["/keep.md", "/secret.md"])
    }

    @Test("browser section never applies the pinned-hidden filter")
    func browserIgnoresHidden() {
        let out = VisibleChildrenFilter.apply(
            [node("/keep.md"), node("/secret.md")],
            filesOnly: false, isPinned: false,
            showPinnedHidden: false, hiddenPaths: ["/secret.md"], browseFilter: "")
        #expect(out.map(\.url.path) == ["/keep.md", "/secret.md"])
    }

    @Test("text filter keeps directories and case-insensitive name matches")
    func textFilter() {
        let out = VisibleChildrenFilter.apply(
            [node("/Notes.md"), node("/todo.txt"), node("/dir", dir: true)],
            filesOnly: false, isPinned: false,
            showPinnedHidden: false, hiddenPaths: [], browseFilter: "note")
        #expect(out.map(\.url.path) == ["/Notes.md", "/dir"])
    }
}

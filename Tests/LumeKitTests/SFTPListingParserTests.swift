import Testing
@testable import LumeKit

struct SFTPListingParserTests {
    @Test func parsesDirsFilesAndModes() {
        let output = """
        sftp> ls -la /etc/nginx
        drwxr-xr-x    5 root     wheel        4096 Jun  9 10:00 conf.d
        -rw-r--r--    1 root     wheel        2049 Jun  9 10:00 nginx.conf
        -rwxr-x---    1 root     wheel         512 Jan  3  2025 reload.sh
        """
        let entries = SFTPListingParser.parse(output)
        #expect(entries.count == 3)
        #expect(entries[0] == .init(name: "conf.d", isDirectory: true, isSymlink: false, size: 4096, mode: 0o755))
        #expect(entries[1] == .init(name: "nginx.conf", isDirectory: false, isSymlink: false, size: 2049, mode: 0o644))
        #expect(entries[2].mode == 0o750)
    }

    @Test func skipsDotDotDotTotalAndEcho() {
        let output = """
        sftp> ls -la .
        drwxr-xr-x    9 manu     staff         288 Jun  9 10:00 .
        drwxr-xr-x    4 manu     staff         128 Jun  9 10:00 ..
        -rw-r--r--    1 manu     staff           5 Jun  9 10:00 real.md
        """
        #expect(SFTPListingParser.parse(output).map(\.name) == ["real.md"])
    }

    @Test func handlesSpacesInNamesAndSymlinks() {
        let output = """
        -rw-r--r--    1 manu     staff          10 Jun  9 10:00 my notes file.md
        lrwxrwxrwx    1 root     wheel          20 Jun  9 10:00 current -> releases/v2
        """
        let entries = SFTPListingParser.parse(output)
        #expect(entries[0].name == "my notes file.md")
        #expect(entries[1].name == "current")
        #expect(entries[1].isSymlink)
        #expect(!entries[1].isDirectory)   // symlinks render as leaves, like the local tree
    }

    @Test func extendedAttributeMarkerTolerated() {
        // macOS sshd: trailing '@' (xattrs) / '+' (ACLs) on the perms column.
        let output = "-rw-r--r--@   1 manu     staff         100 Jun  9 10:00 tagged.md"
        let entries = SFTPListingParser.parse(output)
        #expect(entries.first?.name == "tagged.md")
        #expect(entries.first?.mode == 0o644)
    }

    @Test func symlinkToDirectoryIsALeaf() {
        // Common on modern Linux roots: /bin -> usr/bin. Stays a leaf (never expandable).
        let output = "lrwxrwxrwx    1 root     wheel           7 Jun  9 10:00 bin -> usr/bin"
        let entries = SFTPListingParser.parse(output)
        #expect(entries == [.init(name: "bin", isDirectory: false, isSymlink: true, size: 7, mode: 0o777)])
    }

    @Test func parsesPwdOutput() {
        let output = "sftp> pwd\nRemote working directory: /home/manu\n"
        #expect(SFTPListingParser.workingDirectory(in: output) == "/home/manu")
    }
}

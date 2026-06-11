import Testing
@testable import LumeKit

struct SSHConfigParserTests {
    @Test func extractsConcreteAliases() {
        let config = """
        # personal boxes
        Host web1
            HostName 10.0.0.5
            User deploy

        Host db1 db2
          Port 2222
        """
        #expect(SSHConfigParser.aliases(in: config) == ["web1", "db1", "db2"])
    }

    @Test func skipsWildcardsNegationsAndComments() {
        let config = """
        Host *
            ServerAliveInterval 60
        Host *.internal !bastion deploy-??
        # Host commented-out
        Host real
        """
        #expect(SSHConfigParser.aliases(in: config) == ["real"])
    }

    @Test func caseInsensitiveKeywordAndTabs() {
        #expect(SSHConfigParser.aliases(in: "host\tlower") == ["lower"])
        #expect(SSHConfigParser.aliases(in: "HOST UPPER") == ["UPPER"])
    }

    @Test func dedupesRepeatedAliases() {
        let config = "Host a\nHost a b"
        #expect(SSHConfigParser.aliases(in: config) == ["a", "b"])
    }

    @Test func followsIncludesOneLevel() {
        let main = """
        Include conf.d/work
        Host top
        """
        // Included content is appended after the main text, so main-file hosts
        // appear first regardless of where the Include line sits.
        let aliases = SSHConfigParser.aliases(configText: main) { path in
            path == "conf.d/work" ? "Host included1\nHost included2" : nil
        }
        #expect(aliases == ["top", "included1", "included2"])
    }

    @Test func equalsSignSyntax() {
        #expect(SSHConfigParser.aliases(in: "Host=eq1") == ["eq1"])
        let main = "Include=conf.d/work\nHost top"
        let aliases = SSHConfigParser.aliases(configText: main) { path in
            path == "conf.d/work" ? "Host inc1" : nil
        }
        #expect(aliases == ["top", "inc1"])
    }
}

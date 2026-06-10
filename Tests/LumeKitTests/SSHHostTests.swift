import Testing
@testable import LumeKit

struct SSHHostTests {
    @Test func configAliasHostHasBareDestinationAndNoFlags() {
        let host = SSHHost(alias: "web1")
        #expect(host.destination == "web1")
        #expect(host.flags(portFlag: "-p").isEmpty)
    }

    @Test func manualHostBuildsDestinationAndFlags() {
        let host = SSHHost(alias: "prod", hostname: "10.0.0.5", user: "deploy",
                           port: 2222, identityFile: "/Users/manu/.ssh/id_prod")
        #expect(host.destination == "deploy@10.0.0.5")
        #expect(host.flags(portFlag: "-p") == ["-p", "2222", "-i", "/Users/manu/.ssh/id_prod"])
        #expect(host.flags(portFlag: "-P") == ["-P", "2222", "-i", "/Users/manu/.ssh/id_prod"])
    }
}

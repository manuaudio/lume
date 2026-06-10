import Testing
import Foundation
@testable import LumeKit

struct SSHErrorTests {
    private func map(_ stderr: String, path: String? = nil) -> SSHError {
        SSHError.map(exitCode: 1, stderr: Data(stderr.utf8), path: path)
    }

    @Test func authBeforeGenericPermissionDenied() {
        // ssh's auth failure also contains "Permission denied" — must map to auth.
        #expect(map("manu@web1: Permission denied (publickey,password).") == .authFailed)
    }

    @Test func sftpPermissionDeniedIsFileLevel() {
        #expect(map(#"remote open("/etc/shadow"): Permission denied"#, path: "/etc/shadow")
                == .permissionDenied(path: "/etc/shadow"))
    }

    @Test func notFound() {
        #expect(map("Couldn't stat remote file: No such file or directory", path: "/nope")
                == .notFound(path: "/nope"))
    }

    @Test func unreachableHostsAreConnectFailures() {
        #expect(map("ssh: connect to host web1 port 22: Connection refused")
                == .connectFailed(detail: "ssh: connect to host web1 port 22: Connection refused"))
        #expect(map("ssh: Could not resolve hostname web1: nodename nor servname provided")
                == .connectFailed(detail: "ssh: Could not resolve hostname web1: nodename nor servname provided"))
    }

    @Test func droppedMasterIsConnectionLost() {
        #expect(map("Connection closed by remote host") == .connectionLost)
        #expect(map("mux_client_request_session: session request failed") == .connectionLost)
    }

    @Test func unknownFallsBackToProtocolFailure() {
        #expect(map("something nobody expected") == .protocolFailure(detail: "something nobody expected"))
    }

    @Test func messagesAreHuman() {
        #expect(SSHError.permissionDenied(path: "/etc/nginx/nginx.conf").userMessage
                == "The remote user can't write /etc/nginx/nginx.conf.")
        #expect(SSHError.authFailed.userMessage.contains("Authentication failed"))
    }
}

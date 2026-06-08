import Testing
import Foundation
@testable import LumeKit

@Test func flagsEnvFamily() {
    #expect(SecretDetector.isSensitive(".env"))
    #expect(SecretDetector.isSensitive(".env.local"))
    #expect(SecretDetector.isSensitive(".env.production"))
}

@Test func flagsKeysAndCredentials() {
    #expect(SecretDetector.isSensitive("server.pem"))
    #expect(SecretDetector.isSensitive("id_rsa"))
    #expect(SecretDetector.isSensitive("my-secret.txt"))
    #expect(SecretDetector.isSensitive("aws_credentials"))
}

@Test func doesNotFlagOrdinaryConfig() {
    #expect(!SecretDetector.isSensitive("CLAUDE.md"))
    #expect(!SecretDetector.isSensitive("config.json"))
    #expect(!SecretDetector.isSensitive("README.md"))
}

@Test func sensitiveFilesFiltersURLs() {
    let urls = [
        URL(fileURLWithPath: "/p/CLAUDE.md"),
        URL(fileURLWithPath: "/p/.env"),
        URL(fileURLWithPath: "/p/key.pem"),
    ]
    #expect(SecretDetector.sensitiveFiles(in: urls).map(\.lastPathComponent) == [".env", "key.pem"])
}

@Test func flagsMoreSSHKeyTypesAndIsCaseInsensitive() {
    #expect(SecretDetector.isSensitive("id_ed25519"))
    #expect(SecretDetector.isSensitive("id_ecdsa"))
    #expect(SecretDetector.isSensitive(".ENV"))
    #expect(SecretDetector.isSensitive("Server.PEM"))
}

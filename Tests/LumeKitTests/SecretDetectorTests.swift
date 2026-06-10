import Testing
import Foundation
@testable import LumeKit

// MARK: - Filename heuristics

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

@Test func flagsKeyMaterialExtensions() {
    #expect(SecretDetector.isSensitive("server.key"))
    #expect(SecretDetector.isSensitive("AuthKey_AB12CD34EF.p8"))
    #expect(SecretDetector.isSensitive("identity.p12"))
    #expect(SecretDetector.isSensitive("cert.pfx"))
    #expect(SecretDetector.isSensitive("release.jks"))
    #expect(SecretDetector.isSensitive("debug.keystore"))
    #expect(SecretDetector.isSensitive("putty.ppk"))
}

@Test func flagsCredentialDotfilesAndServiceAccounts() {
    #expect(SecretDetector.isSensitive(".netrc"))
    #expect(SecretDetector.isSensitive(".npmrc"))
    #expect(SecretDetector.isSensitive(".pgpass"))
    #expect(SecretDetector.isSensitive(".git-credentials"))
    #expect(SecretDetector.isSensitive("service-account.json"))
    #expect(SecretDetector.isSensitive("service-account-prod.json"))
}

@Test func doesNotFlagOrdinaryConfig() {
    #expect(!SecretDetector.isSensitive("CLAUDE.md"))
    #expect(!SecretDetector.isSensitive("config.json"))
    #expect(!SecretDetector.isSensitive("README.md"))
}

@Test func doesNotFlagLookalikeNames() {
    // False-positive guards: substrings of secret-ish words must NOT match.
    #expect(!SecretDetector.isSensitive("secretary.md"))
    #expect(!SecretDetector.isSensitive("dotenv.md"))
    #expect(!SecretDetector.isSensitive("pemberton.txt"))
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

// MARK: - Content heuristics

@Test func contentFlagsAWSAccessKey() {
    let body = "aws_access_key_id = AKIAIOSFODNN7EXAMPLE"
    #expect(SecretDetector.firstContentMatch(in: body) == .awsAccessKeyID)
    #expect(SecretDetector.containsLikelySecret(body))
}

@Test func contentFlagsPrivateKeyBlocks() {
    #expect(SecretDetector.firstContentMatch(
        in: "-----BEGIN PRIVATE KEY-----\nMIIEv…") == .privateKeyBlock)
    #expect(SecretDetector.firstContentMatch(
        in: "-----BEGIN RSA PRIVATE KEY-----") == .privateKeyBlock)
    #expect(SecretDetector.firstContentMatch(
        in: "-----BEGIN OPENSSH PRIVATE KEY-----") == .privateKeyBlock)
}

@Test func contentFlagsPlatformTokens() {
    #expect(SecretDetector.firstContentMatch(
        in: "token: ghp_16C7e42F292c6912E7710c838347Ae178B4a") == .gitHubToken)
    #expect(SecretDetector.firstContentMatch(
        in: "SLACK=xoxb-test-fixture-not-a-real-token") == .slackToken)
    #expect(SecretDetector.firstContentMatch(
        in: "OPENAI_API_KEY short ref sk-proj-AbCdEfGhIjKlMnOpQrStUvWxYz12") == .skAPIKey)
}

@Test func contentFlagsHighEntropyAssignment() {
    let hexValue = "api_key=f3a9c2e84b7d165091a2b3c4d5e6f708"            // 32 hex chars
    let b64Value = "SECRET_TOKEN: dGhpc2lzYXZlcnlsb25nYmFzZTY0c3RyaW5nIQ=="
    #expect(SecretDetector.firstContentMatch(in: hexValue) == .highEntropyAssignment)
    #expect(SecretDetector.firstContentMatch(in: b64Value) == .highEntropyAssignment)
}

@Test func contentDoesNotFlagOrdinaryCodeOrProse() {
    let swiftSource = """
    let tokenEstimate = TokenEstimator.estimate(text)
    let key = "contextFormat"
    // password handling lives elsewhere; see SecretDetector
    """
    let prose = "The secret to good token budgets: keep keys short. key: abc123"
    #expect(!SecretDetector.containsLikelySecret(swiftSource))
    #expect(!SecretDetector.containsLikelySecret(prose))
    #expect(SecretDetector.firstContentMatch(in: "") == nil)
}

@Test func contentScanIsLinearOnAdversarialInput() {
    // Near-miss flood for the assignment rule: must finish instantly (no ReDoS).
    let adversarial = String(repeating: "key= " + String(repeating: "A", count: 31) + "! ", count: 2_000)
    let start = Date()
    _ = SecretDetector.containsLikelySecret(adversarial)
    #expect(Date().timeIntervalSince(start) < 1.0)
}

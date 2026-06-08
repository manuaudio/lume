import Foundation

/// Flags filenames that likely contain secrets, so the UI can warn before
/// their *contents* are copied into a chatbot paste.
public enum SecretDetector {

    public static func sensitiveFiles(in urls: [URL]) -> [URL] {
        urls.filter { isSensitive($0.lastPathComponent) }
    }

    public static func isSensitive(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        if lower == ".env" || lower.hasPrefix(".env.") { return true }
        if lower.hasSuffix(".pem") { return true }
        if lower.hasPrefix("id_rsa") || lower.hasPrefix("id_ecdsa")
            || lower.hasPrefix("id_ed25519") || lower.hasPrefix("id_dsa") { return true }
        if lower.contains("secret") || lower.contains("credential") { return true }
        return false
    }
}

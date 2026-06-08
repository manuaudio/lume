import Foundation

/// Flags filenames that likely contain secrets, so the UI can warn before
/// their *contents* are copied into a chatbot paste.
public enum SecretDetector {

    public static func sensitiveFiles(in urls: [URL]) -> [URL] {
        urls.filter { isSensitive($0.lastPathComponent) }
    }

    public static func isSensitive(_ filename: String) -> Bool {
        if filename == ".env" || filename.hasPrefix(".env.") { return true }
        let lower = filename.lowercased()
        if lower.hasSuffix(".pem") { return true }
        if lower == "id_rsa" || lower.hasPrefix("id_rsa") { return true }
        if lower.contains("secret") || lower.contains("credential") { return true }
        return false
    }
}

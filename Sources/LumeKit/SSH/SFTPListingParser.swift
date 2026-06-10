import Foundation

/// Parses OpenSSH `sftp` batch output: long `ls -la` listings and `pwd`.
/// Batch mode echoes each command as an "sftp> …" line — those, `total`
/// headers, and `.`/`..` are noise and skipped.
public enum SFTPListingParser {
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let isDirectory: Bool
        public let isSymlink: Bool
        public let size: Int64?
        public let mode: UInt16?

        public init(name: String, isDirectory: Bool, isSymlink: Bool, size: Int64?, mode: UInt16?) {
            self.name = name
            self.isDirectory = isDirectory
            self.isSymlink = isSymlink
            self.size = size
            self.mode = mode
        }
    }

    public static func parse(_ text: String) -> [Entry] {
        text.split(separator: "\n").compactMap { parseLine(String($0)) }
    }

    /// One long-format line:
    /// `-rw-r--r--    1 root     wheel        2049 Jun  9 10:00 nginx.conf`
    /// Fields 0–7 are fixed; everything after field 7 is the (spaceable) name.
    static func parseLine(_ line: String) -> Entry? {
        let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard fields.count == 9 else { return nil }
        var perms = fields[0]
        // macOS ls appends '@' (xattrs) or '+' (ACLs) to the mode column.
        if perms.count == 11, perms.hasSuffix("@") || perms.hasSuffix("+") {
            perms = perms.dropLast()
        }
        guard perms.count == 10 else { return nil }
        let typeChar = perms.first!
        guard typeChar == "d" || typeChar == "-" || typeChar == "l" else { return nil }

        var name = String(fields[8])
        if typeChar == "l", let arrow = name.range(of: " -> ") {
            name = String(name[..<arrow.lowerBound])
        }
        if name == "." || name == ".." { return nil }

        return Entry(
            name: name,
            isDirectory: typeChar == "d",
            isSymlink: typeChar == "l",
            size: Int64(fields[4]),
            mode: parseMode(perms.dropFirst())
        )
    }

    /// "rw-r--r--" → 0o644. Setuid/sticky letters grant the underlying bit
    /// when lowercase ('s'/'t'); uppercase ('S'/'T') means the bit without
    /// execute — close enough for a writability hint.
    static func parseMode(_ rwx: Substring) -> UInt16? {
        guard rwx.count == 9 else { return nil }
        var mode: UInt16 = 0
        for (i, char) in rwx.enumerated() {
            if char == "-" || char == "S" || char == "T" { continue }
            mode |= 1 << (8 - i)
        }
        return mode
    }

    /// Extracts the path from sftp's `pwd` response
    /// ("Remote working directory: /home/manu").
    public static func workingDirectory(in text: String) -> String? {
        for line in text.split(separator: "\n") {
            if let range = line.range(of: "Remote working directory: ") {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

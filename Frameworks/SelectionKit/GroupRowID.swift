import Foundation

/// Row-id grammar for the GROUPS region, kept PURE (no SwiftUI/SwiftData) so it
/// is unit-testable. The unified sidebar packs several row kinds into one
/// `Set<String>` selection; GROUPS adds two:
///
///   • a group HEADER row   →  "group|g|<tagName>"
///   • a FILE under a group →  "groupfile|f|<tagName>|<path>"
///
/// The owning tag name is part of the file id, so the SAME real file under two
/// different groups produces two DISTINCT ids (required: a multi-tag file appears
/// under multiple groups simultaneously). Paths (and, defensively, tag names) may
/// contain "|", so decoding splits off a fixed number of leading separators and
/// keeps the final field verbatim.
public enum GroupRowID: Equatable, Sendable {
    case header(tagName: String)
    case file(tagName: String, path: String)

    /// Encode a group-header id.
    public static func headerID(tagName: String) -> String {
        "group|g|\(tagName)"
    }

    /// Encode a file-under-group id.
    public static func fileID(tagName: String, path: String) -> String {
        "groupfile|f|\(tagName)|\(path)"
    }

    /// Decode a GROUPS row id, or nil if it isn't one (browser/pinned/garbage).
    public static func decode(_ id: String) -> GroupRowID? {
        if id.hasPrefix("group|g|") {
            // "group|g|<tagName>" — one payload field, keep the remainder whole.
            let parts = id.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "group", parts[1] == "g" else { return nil }
            return .header(tagName: String(parts[2]))
        }
        if id.hasPrefix("groupfile|f|") {
            // "groupfile|f|<tagName>|<path>" — two payload fields; the FIRST is the
            // tag name (no "|" in practice but tolerated below by the path winning
            // the remainder), the LAST is the path (may contain "|").
            let parts = id.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4, parts[0] == "groupfile", parts[1] == "f" else { return nil }
            return .file(tagName: String(parts[2]), path: String(parts[3]))
        }
        return nil
    }

    /// The real file URL for a file-under-group id, or nil for a header id or any
    /// non-GROUPS id. Lets the app reuse one collection (e.g. Copy Paths) across
    /// group-file rows without special-casing.
    public static func fileURL(forID id: String) -> URL? {
        if case let .file(_, path) = decode(id) { return URL(fileURLWithPath: path) }
        return nil
    }
}

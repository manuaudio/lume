import Foundation

/// Pure, view-free autocomplete math for the editor's "+ add tag" popover.
/// Lives in LumeCore so it can be unit-tested without any SwiftUI/SwiftData
/// dependency. Names are matched case-insensitively by prefix; tags already on
/// the file are never suggested (no point re-adding them).
public enum TagSuggest {

    /// Existing tag names to offer, given the current draft text.
    /// - Prefix-filtered (case-insensitive) by the trimmed `query` (empty query = all).
    /// - Excludes any name already on the file (case-insensitive).
    /// - Deduplicated and sorted case-insensitively.
    public static func suggestions(
        query: String,
        allNames: [String],
        existingOnFile: [String]
    ) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let onFile = Set(existingOnFile.map { $0.lowercased() })
        var seen = Set<String>()
        let filtered = allNames.filter { name in
            let lower = name.lowercased()
            guard !onFile.contains(lower) else { return false }
            guard q.isEmpty || lower.hasPrefix(q) else { return false }
            return seen.insert(lower).inserted
        }
        return filtered.sorted { $0.lowercased() < $1.lowercased() }
    }

    /// Whether to show a "Create '<draft>'" row: the draft is non-blank, and not
    /// already an existing tag name or already on the file (both case-insensitive).
    public static func shouldOfferCreate(
        query: String,
        allNames: [String],
        existingOnFile: [String]
    ) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        let lower = q.lowercased()
        if allNames.contains(where: { $0.lowercased() == lower }) { return false }
        if existingOnFile.contains(where: { $0.lowercased() == lower }) { return false }
        return true
    }
}

import Foundation

/// Pure ordering for the files inside a GROUP (a tag-folder). Files are sorted by
/// their EFFECTIVE display name — the user override if present, else the filename
/// — case-insensitively, tie-broken by full path so same-named files in different
/// folders keep a stable, deterministic order. Never touches disk or SwiftData;
/// the caller supplies display-name overrides via the closure.
public enum GroupSort {
    public static func sorted(_ paths: [String],
                              displayNameForPath: (String) -> String?) -> [String] {
        func key(_ path: String) -> String {
            let name = displayNameForPath(path) ?? (path as NSString).lastPathComponent
            return name
        }
        return paths.sorted { lhs, rhs in
            let lk = key(lhs), rk = key(rhs)
            let cmp = lk.localizedCaseInsensitiveCompare(rk)
            if cmp == .orderedSame { return lhs < rhs }   // tie-break by path
            return cmp == .orderedAscending
        }
    }
}

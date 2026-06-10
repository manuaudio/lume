import Foundation

/// Overwrites scan-result files with a canonical file's text. Pure file-level
/// logic (no app state) so the destructive path is unit-testable and can run
/// off the main actor; the caller applies the returned outcome (undo
/// registration, cache invalidation, error reporting) back on main.
public enum CanonicalOverwrite {

    /// One reversible write: the file overwritten and its previous text.
    public struct Restore: Equatable, Sendable {
        public let url: URL
        public let text: String
        public init(url: URL, text: String) {
            self.url = url
            self.text = text
        }
    }

    public struct Outcome: Equatable, Sendable {
        public let restores: [Restore]
        public let skipped: [String]
        public init(restores: [Restore], skipped: [String]) {
            self.restores = restores
            self.skipped = skipped
        }
    }

    /// Overwrite each target with `canonical`'s text. Returns nil when the
    /// canonical file itself can't be read as UTF-8.
    public static func run(targets: [URL], canonical: URL) -> Outcome? {
        guard let canonText = try? String(contentsOf: canonical, encoding: .utf8) else {
            return nil
        }
        var restores: [Restore] = []
        var skipped: [String] = []
        for target in targets where target.path != canonical.path {
            // Only overwrite files we can read back as UTF-8 text. A binary or
            // non-UTF-8 target has no faithful undo (we'd capture "" and restore an
            // empty file), so skip it entirely rather than risk destroying data.
            guard let old = try? String(contentsOf: target, encoding: .utf8) else {
                skipped.append(target.lastPathComponent)
                continue
            }
            do {
                try TextDocument(url: target, text: canonText).save()
                restores.append(Restore(url: target, text: old))
            } catch {
                skipped.append(target.lastPathComponent)
            }
        }
        return Outcome(restores: restores, skipped: skipped)
    }
}

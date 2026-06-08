import Foundation

/// Rough token estimates using the chars≈tokens÷4 heuristic shared with ContextAssembler.
public enum TokenEstimator {
    /// Token estimate for in-memory text: chars ÷ 4.
    public static func estimate(_ text: String) -> Int {
        Int(ceil(Double(text.count) / 4.0))
    }

    /// Fast per-file estimate from on-disk byte size ÷ 4 (no file read). nil if unavailable.
    public static func estimateFile(_ url: URL) -> Int? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        else { return nil }
        return Int(ceil(Double(size) / 4.0))
    }

    /// Compact label: "~512", "~1.2k", "~45k"; nil → "—".
    public static func format(_ tokens: Int?) -> String {
        guard let t = tokens else { return "—" }
        if t < 1000 { return "~\(t)" }
        let k = Double(t) / 1000.0
        return k < 10 ? "~\(String(format: "%.1f", k))k" : "~\(Int(k))k"
    }
}

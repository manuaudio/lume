import Foundation

/// The centralized tag color palette. Colors are stored as raw RGB so `LumeCore`
/// stays free of any SwiftUI dependency — the app layer bridges `Swatch → Color`
/// (see `TagChip.swift`). A `Tag` persists only a small `colorIndex` into this
/// table, so re-theming all tags is a one-file change here.
public enum TagPalette {
    public struct Swatch: Sendable, Equatable {
        public let name: String
        public let red: Double
        public let green: Double
        public let blue: Double
        public init(name: String, red: Double, green: Double, blue: Double) {
            self.name = name
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// The 8 canonical tag colors (index 0…7).
    public static let swatches: [Swatch] = [
        Swatch(name: "Slate",  red: 0.42, green: 0.45, blue: 0.50),
        Swatch(name: "Red",    red: 0.90, green: 0.27, blue: 0.27),
        Swatch(name: "Orange", red: 0.96, green: 0.55, blue: 0.19),
        Swatch(name: "Yellow", red: 0.92, green: 0.76, blue: 0.18),
        Swatch(name: "Green",  red: 0.30, green: 0.69, blue: 0.39),
        Swatch(name: "Teal",   red: 0.20, green: 0.62, blue: 0.62),
        Swatch(name: "Blue",   red: 0.25, green: 0.50, blue: 0.90),
        Swatch(name: "Purple", red: 0.60, green: 0.38, blue: 0.82),
    ]

    public static var count: Int { swatches.count }

    /// Wrap any integer (possibly negative or out of range) into `0…count-1`, so
    /// a stored `colorIndex` can never index out of bounds even if the palette
    /// later shrinks.
    public static func wrap(_ raw: Int) -> Int {
        let c = count
        return ((raw % c) + c) % c
    }

    public static func swatch(at index: Int) -> Swatch {
        swatches[wrap(index)]
    }
}

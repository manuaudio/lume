import Testing
@testable import LumeCore

@Test func paletteHasEightSwatches() {
    #expect(TagPalette.count == 8)
    #expect(TagPalette.swatches.count == 8)
}

@Test func wrapKeepsIndexInRange() {
    #expect(TagPalette.wrap(0) == 0)
    #expect(TagPalette.wrap(7) == 7)
    #expect(TagPalette.wrap(8) == 0)
    #expect(TagPalette.wrap(9) == 1)
    #expect(TagPalette.wrap(-1) == 7)
}

@Test func swatchAtWrapsOutOfRangeIndexes() {
    #expect(TagPalette.swatch(at: 9) == TagPalette.swatches[1])
    #expect(TagPalette.swatch(at: -1) == TagPalette.swatches[7])
}

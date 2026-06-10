import Testing
@testable import LumeKit

@Test func freshTokenIsCurrent() {
    var gen = Generation()
    let token = gen.advance()
    #expect(gen.isCurrent(token))
}

@Test func advanceInvalidatesEarlierTokens() {
    var gen = Generation()
    let first = gen.advance()
    let second = gen.advance()
    #expect(!gen.isCurrent(first))
    #expect(gen.isCurrent(second))
}

@Test func staleLoadScenarioDropsOnlyTheSupersededCompletion() {
    // Models AUDIT C1: click file A (slow load), then file B before A finishes.
    var gen = Generation()
    let loadA = gen.advance()
    let loadB = gen.advance()
    #expect(!gen.isCurrent(loadA))   // A's late completion must be dropped
    #expect(gen.isCurrent(loadB))    // B's completion applies
}

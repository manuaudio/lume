import Testing
@testable import LumeCore

@Test func packageExposesVersion() {
    #expect(LumeCore.version == "0.1.0")
}

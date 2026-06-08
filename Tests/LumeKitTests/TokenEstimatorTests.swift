import Testing
import Foundation
@testable import LumeKit

private func tokTempFile(_ name: String, bytes: Int) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tok-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try String(repeating: "x", count: bytes).write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Test func estimateIsCharsOverFour() {
    #expect(TokenEstimator.estimate("") == 0)
    #expect(TokenEstimator.estimate("abcd") == 1)
    #expect(TokenEstimator.estimate("abcde") == 2)
}

@Test func estimateFileFromByteSize() throws {
    let url = try tokTempFile("a.txt", bytes: 40)
    #expect(TokenEstimator.estimateFile(url) == 10)
    #expect(TokenEstimator.estimateFile(URL(fileURLWithPath: "/nope/\(UUID().uuidString).txt")) == nil)
}

@Test func formatCompacts() {
    #expect(TokenEstimator.format(nil) == "—")
    #expect(TokenEstimator.format(512) == "~512")
    #expect(TokenEstimator.format(1200) == "~1.2k")
    #expect(TokenEstimator.format(45000) == "~45k")
}

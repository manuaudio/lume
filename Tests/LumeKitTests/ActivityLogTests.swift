import Testing
import Foundation
@testable import LumeKit

@Test func recordsNewestFirstAndDedupes() {
    var log = ActivityLog(limit: 10)
    let t0 = Date(timeIntervalSince1970: 0)
    log.record("/a", at: t0)
    log.record("/b", at: t0.addingTimeInterval(1))
    #expect(log.entries.map(\.path) == ["/b", "/a"])
    log.record("/a", at: t0.addingTimeInterval(2))
    #expect(log.entries.map(\.path) == ["/a", "/b"])
    #expect(log.entries.count == 2)
}

@Test func capsToLimit() {
    var log = ActivityLog(limit: 2)
    let t = Date(timeIntervalSince1970: 0)
    log.record("/a", at: t)
    log.record("/b", at: t)
    log.record("/c", at: t)
    #expect(log.entries.map(\.path) == ["/c", "/b"])
}

@Test func clearEmpties() {
    var log = ActivityLog()
    log.record("/a", at: Date(timeIntervalSince1970: 0))
    log.clear()
    #expect(log.entries.isEmpty)
}

@Test func ignoresVendorDirs() {
    #expect(ActivityLog.isIgnored("/proj/node_modules/x.js"))
    #expect(ActivityLog.isIgnored("/proj/.git/HEAD"))
    #expect(!ActivityLog.isIgnored("/proj/CLAUDE.md"))
    #expect(!ActivityLog.isIgnored("/proj/.env"))
}

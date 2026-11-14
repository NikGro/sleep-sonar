import Foundation
import XCTest
@testable import SonarDSP

final class AlarmLedgerTests: XCTestCase {
    let item = UUID(), other = UUID()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testMainReplacement() {
        var l = AlarmLedger()
        let a = UUID(), b = UUID()
        XCTAssertNil(l.setMain(a, for: item))
        XCTAssertNil(l.setMain(a, for: item), "derselbe Systemwecker: nichts abzubestellen")
        XCTAssertEqual(l.setMain(b, for: item), a)
        XCTAssertEqual(l.mainKit(for: item), b)
        XCTAssertEqual(l.removeMain(for: item), b)
        XCTAssertNil(l.mainKit(for: item))
    }

    func testExtrasDedupeAndKeep() {
        var l = AlarmLedger()
        let e1 = UUID(), e2 = UUID()
        l.addExtra(e1, for: item, at: t0)
        XCTAssertTrue(l.hasExtra(for: item, at: t0))
        XCTAssertFalse(l.hasExtra(for: item, at: t0.addingTimeInterval(60)))
        XCTAssertFalse(l.hasExtra(for: other, at: t0))
        l.addExtra(e2, for: item, at: t0.addingTimeInterval(7 * 86400))
        // e1 klingelt gerade: bleibt eingetragen
        XCTAssertEqual(l.removeExtras(for: item, keeping: [e1]), [e2])
        XCTAssertEqual(l.kits(of: item), [e1])
        XCTAssertEqual(Set(l.removeExtras(for: item)), [e1])
        XCTAssertTrue(l.kits(of: item).isEmpty)
    }

    func testPruneKeepsLiveOnly() {
        var l = AlarmLedger()
        let m = UUID(), old = UUID(), live = UUID()
        l.setMain(m, for: item)
        l.addExtra(old, for: item, at: t0)                              // gültig bis t0 + 1 h
        l.addExtra(live, for: other, at: t0.addingTimeInterval(86400))
        l.rang[item] = t0.addingTimeInterval(1800)
        let keep = l.prune(now: t0.addingTimeInterval(2 * 3600))
        XCTAssertEqual(keep, [m, live])
        XCTAssertTrue(l.rang.isEmpty)
        XCTAssertEqual(l.kits(of: item), [m])
    }

    func testRemoveAllAndCoding() throws {
        var l = AlarmLedger()
        let m = UUID(), e = UUID()
        l.setMain(m, for: item)
        l.addExtra(e, for: item, at: t0)
        l.rang[item] = t0
        let data = try JSONEncoder().encode(l)
        XCTAssertEqual(try JSONDecoder().decode(AlarmLedger.self, from: data), l)
        XCTAssertEqual(Set(l.removeAll(for: item)), [m, e])
        XCTAssertEqual(l, AlarmLedger())
    }
}

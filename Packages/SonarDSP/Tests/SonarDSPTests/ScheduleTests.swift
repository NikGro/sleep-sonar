import Foundation
import XCTest
@testable import SonarDSP

final class ScheduleTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testOnceTodayOrTomorrow() {
        // 22:00 abends, Wecker 6:30 → morgen früh
        XCTAssertEqual(AlarmTimes.next(wakeMinutes: 390, repeatDays: [], after: date(2026, 11, 13, 22, 0), calendar: cal),
                       date(2026, 11, 14, 6, 30))
        // 5:00 früh → heute
        XCTAssertEqual(AlarmTimes.next(wakeMinutes: 390, repeatDays: [], after: date(2026, 11, 14, 5, 0), calendar: cal),
                       date(2026, 11, 14, 6, 30))
        // genau zur Weckzeit: nicht dieselbe Minute noch einmal
        XCTAssertEqual(AlarmTimes.next(wakeMinutes: 390, repeatDays: [], after: date(2026, 11, 14, 6, 30), calendar: cal),
                       date(2026, 11, 15, 6, 30))
    }

    func testRepeatSkipsWeekend() {
        // Freitag 13.11.2026, 23:00; nur Mo–Fr (2…6) → Montag 16.11.
        let next = AlarmTimes.next(wakeMinutes: 420, repeatDays: [2, 3, 4, 5, 6], after: date(2026, 11, 13, 23, 0), calendar: cal)
        XCTAssertEqual(next, date(2026, 11, 16, 7, 0))
        // nur ein Tag in der Woche, gerade vorbei → eine Woche später
        let weekly = AlarmTimes.next(wakeMinutes: 420, repeatDays: [6], after: date(2026, 11, 13, 7, 1), calendar: cal)
        XCTAssertEqual(weekly, date(2026, 11, 20, 7, 0))
    }

    func testDaylightSaving() {
        // Umstellung auf Sommerzeit am 29.3.2026 (2:00 → 3:00): 7:00 bleibt 7:00 Ortszeit
        let spring = AlarmTimes.next(wakeMinutes: 420, repeatDays: [], after: date(2026, 3, 28, 23, 0), calendar: cal)!
        XCTAssertEqual(cal.dateComponents([.day, .hour, .minute], from: spring), DateComponents(day: 29, hour: 7, minute: 0))
        XCTAssertEqual(spring.timeIntervalSince(date(2026, 3, 28, 23, 0)), 7 * 3600)   // eine Stunde weniger Nacht
        // Wecker in der ausgefallenen Stunde (2:30) liefert trotzdem eine Zeit
        XCTAssertNotNil(AlarmTimes.next(wakeMinutes: 150, repeatDays: [], after: date(2026, 3, 28, 23, 0), calendar: cal))
        // Folgewecker über die Umstellung im Herbst (25.10.2026) behalten die Uhrzeit
        let ups = AlarmTimes.followUps(after: date(2026, 10, 19, 6, 30), weeks: 4, calendar: cal)
        XCTAssertEqual(ups.count, 4)
        for (i, d) in ups.enumerated() {
            XCTAssertEqual(cal.dateComponents([.hour, .minute], from: d), DateComponents(hour: 6, minute: 30))
            XCTAssertEqual(cal.component(.weekday, from: d), cal.component(.weekday, from: date(2026, 10, 19, 6, 30)))
            XCTAssertEqual(cal.dateComponents([.day], from: date(2026, 10, 19, 0, 0), to: d).day, 7 * (i + 1))
        }
    }

    func testSoundMasks() {
        // an bei 100 s, aus bei 200 s → 98 s … 235 s
        XCTAssertEqual(MaskRanges.sounds([(seconds: 200, on: false), (seconds: 100, on: true)]), [980..<2350])
        // doppeltes „an“ zählt einmal, „aus“ ohne „an“ wird übergangen
        XCTAssertEqual(MaskRanges.sounds([(seconds: 10, on: false), (seconds: 50, on: true), (seconds: 60, on: true),
                                          (seconds: 70, on: false)]), [480..<1050])
        // „aus“ fehlt: höchstens 3 h
        XCTAssertEqual(MaskRanges.sounds([(seconds: 10, on: true)]), [80..<(10 + 10800) * 10])
        // kaputte Werte stürzen nicht ab
        XCTAssertEqual(MaskRanges.sounds([(seconds: .nan, on: true), (seconds: .infinity, on: false)]), [])
    }

    func testGapMasks() {
        let csv = "from_s,to_s\n120.0,180.5\nkaputt\n300,200\n-5,10\n400,460\n"
        XCTAssertEqual(MaskRanges.gaps(csv: csv), [1200..<1805, 4000..<4600])
        XCTAssertEqual(MaskRanges.gaps(csv: "from_s,to_s\n"), [])
    }

    func testTimestampGaps() {
        let t0 = Date(timeIntervalSince1970: 0)
        let normal = (0..<100).map { t0.addingTimeInterval(Double($0)) }
        XCTAssertEqual(MaskRanges.timestampGaps(normal), 0)
        // eine Lücke von 61 s zwischen zwei Sekundenwerten → 60 s fehlen
        let gap = normal + [t0.addingTimeInterval(160)]
        XCTAssertEqual(MaskRanges.timestampGaps(gap), 60, accuracy: 0.001)
    }
}

import XCTest
@testable import SonarDSP

final class SleepStagingTests: XCTestCase {
    /// Synthetische Nacht: 20 min wach (Rascheln), dann 6 h Schlaf, 15 min wach am Ende.
    /// Im Schlaf: Atemperiode 4 s (Kern), 60–150 min 5 s und leiser (Tief),
    /// 230–290 min 3 s und unregelmäßig (REM), nach 200 min 5 min Unruhe.
    func makeNight() -> (seconds: [SleepStaging.Second?], motion: [Double?]) {
        var rng = SplitMix64(state: 7)
        let total = 20 * 60 + 6 * 3600 + 15 * 60
        var sec: [SleepStaging.Second?] = []
        var mot: [Double?] = []
        for t in 0..<total {
            let m = t / 60
            let awake = m < 20 || t >= 20 * 60 + 6 * 3600
            let restless = m >= 200 && m < 205
            let deep = m >= 60 && m < 150
            let rem = m >= 230 && m < 290
            var base = (deep ? -63.0 : -60.0) + rng.gaussian() * 0.5
            let period = deep ? 5.0 : rem ? 3.0 : 4.0
            let breath = 3 * sin(2 * Double.pi * Double(t) / period) + rng.gaussian() * (rem ? 0.6 : 0.3)
            var high = -70 + breath
            if (awake || restless) && rng.uniform() < 0.4 { base += 15; high += 18 }
            sec.append(.init(rms: base, mid: base + breath * 0.5, high: high))
            mot.append(m < 5 ? 0.05 : 0.001)
        }
        return (sec, mot)
    }

    func testWakeSleepStructure() {
        let night = makeNight()
        let epochs = SleepStaging.estimate(seconds: night.seconds, motion: night.motion)
        XCTAssertEqual(epochs.count, (20 * 60 + 6 * 3600 + 15 * 60) / 30)
        XCTAssertTrue(epochs.prefix(20).allSatisfy { $0.stage == .wake })
        XCTAssertTrue(epochs.suffix(20).allSatisfy { $0.stage == .wake })
        // langsamer, leiser Atem → Tief; schneller, unregelmäßiger → REM; dazwischen Kern
        XCTAssertEqual(epochs[105 * 2].stage, .deep)
        XCTAssertEqual(epochs[260 * 2].stage, .rem)
        XCTAssertEqual(epochs[40 * 2].stage, .core)
        let late = epochs[(300 * 2)..<(345 * 2)]
        XCTAssertGreaterThan(late.filter { $0.stage == .core }.count, late.filter { $0.stage == .rem }.count)
        // Unruhe nach 200 min → wach
        XCTAssertEqual(epochs[202 * 2 + 1].stage, .wake)
        let sleepHours = Double(epochs.filter { $0.stage != .wake }.count) * 30 / 3600
        XCTAssertGreaterThan(sleepHours, 5.5)
        XCTAssertLessThan(sleepHours, 6.2)
    }

    func testShortWakeBlipsBecomeSleep() {
        // ein einzelner Raschler (1 Epoche) mitten im Kernschlaf ist kein Aufwachen
        var night = makeNight()
        let a = 40 * 60
        for t in a..<(a + 30) { night.seconds[t]?.high += 25 }
        let epochs = SleepStaging.estimate(seconds: night.seconds, motion: night.motion)
        XCTAssertNotEqual(epochs[a / 30].stage, .wake)
    }

    func testGapsAreWake() {
        var night = makeNight()
        for t in (20 * 60 + 3600)..<(20 * 60 + 3600 + 600) { night.seconds[t] = nil }
        let epochs = SleepStaging.estimate(seconds: night.seconds, motion: night.motion)
        XCTAssertEqual(epochs[(20 * 60 + 3600 + 300) / 30].stage, .wake)
        XCTAssertFalse(epochs[(20 * 60 + 3600 + 300) / 30].hasData)
    }

    func testSnoringCountsAsSleep() {
        // Nacht mit lautem, regelmäßigem Schnarchen in der Mitte (1 h): ohne Geräusch-Info
        // hält die Regel das für Unruhe/wach, mit Schnarch-Markierung für Schlaf.
        var night = makeNight()
        let a = 20 * 60 + 4 * 3600, b = a + 3600
        var snore = Set<Int>()
        for t in a..<b where t % 4 < 2 {
            night.seconds[t]?.rms += 20
            night.seconds[t]?.high += 20
            snore.insert(t)
        }
        let probe = (a + 1800) / 30
        let plain = SleepStaging.estimate(seconds: night.seconds, motion: night.motion)
        XCTAssertEqual(plain[probe].stage, .wake)
        let aware = SleepStaging.estimate(seconds: night.seconds, motion: night.motion, sleepSounds: snore)
        XCTAssertNotEqual(aware[probe].stage, .wake)
        // Sprechen zählt als Unruhe, auch wenn es leise ist
        let talk = Set((a - 1200)..<(a - 600))
        let talking = SleepStaging.estimate(seconds: night.seconds, motion: night.motion, sleepSounds: snore,
                                            wakeSounds: talk)
        XCTAssertEqual(talking[(a - 900) / 30].stage, .wake)
    }

    func testAgreement() {
        let a: [SleepStaging.Stage?] = [.wake, .core, .deep, .rem, nil]
        let b: [SleepStaging.Stage?] = [.wake, .core, .core, .wake, .core]
        let r = SleepStaging.agreement(a, b)
        XCTAssertEqual(r.epochs, 4)
        XCTAssertEqual(r.fourClass, 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.sleepWake, 0.75, accuracy: 1e-9)
    }
}

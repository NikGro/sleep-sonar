import XCTest
@testable import SonarDSP

final class SleepStagingTests: XCTestCase {
    /// Synthetische Nacht: 20 min unruhig (wach), dann 6 h ruhig mit regelmäßigem
    /// Atemrhythmus in der ersten Hälfte, einer Unruhe-Phase nach 3 h, 15 min wach am Ende.
    func makeNight() -> (seconds: [SleepStaging.Second?], motion: [Double?]) {
        var rng = SplitMix64(state: 7)
        let total = 20 * 60 + 6 * 3600 + 15 * 60
        var sec: [SleepStaging.Second?] = []
        var mot: [Double?] = []
        for t in 0..<total {
            let awakeStart = t < 20 * 60
            let awakeEnd = t >= 20 * 60 + 6 * 3600
            let restless = t >= 20 * 60 + 3 * 3600 && t < 20 * 60 + 3 * 3600 + 5 * 60
            let base = -60.0 + rng.gaussian() * 0.5
            var rms = base
            if (awakeStart || awakeEnd || restless) && rng.uniform() < 0.4 { rms += 15 }
            // Atemrauschen: regelmäßig (Periode 4 s) in der ersten Schlafhälfte, sonst zufällig
            let firstHalf = t >= 20 * 60 && t < 20 * 60 + 2 * 3600
            let breath = firstHalf ? 3 * sin(2 * Double.pi * Double(t) / 4) : rng.gaussian() * 3
            sec.append(.init(rms: rms, mid: base, high: -70 + breath))
            mot.append(awakeStart && t < 300 ? 0.05 : 0.001)
        }
        return (sec, mot)
    }

    func testWakeSleepStructure() {
        let night = makeNight()
        let epochs = SleepStaging.estimate(seconds: night.seconds, motion: night.motion)
        XCTAssertEqual(epochs.count, (20 * 60 + 6 * 3600 + 15 * 60) / 30)
        // erste 10 min wach
        XCTAssertTrue(epochs.prefix(20).allSatisfy { $0.stage == .wake })
        // Mitte der Nacht schläft
        let mid = epochs[(20 * 60 + 90 * 60) / 30]
        XCTAssertNotEqual(mid.stage, .wake)
        // letzte 10 min wach
        XCTAssertTrue(epochs.suffix(20).allSatisfy { $0.stage == .wake })
        // regelmäßiger Atem früh → es gibt Tiefschlaf
        XCTAssertTrue(epochs.contains { $0.stage == .deep })
        // Gesamtschlaf grob 5,5–6,2 h
        let sleepHours = Double(epochs.filter { $0.stage != .wake }.count) * 30 / 3600
        XCTAssertGreaterThan(sleepHours, 5.5)
        XCTAssertLessThan(sleepHours, 6.2)
    }

    func testGapsAreWake() {
        var night = makeNight()
        for t in (20 * 60 + 3600)..<(20 * 60 + 3600 + 600) { night.seconds[t] = nil }
        let epochs = SleepStaging.estimate(seconds: night.seconds, motion: night.motion)
        XCTAssertEqual(epochs[(20 * 60 + 3600 + 300) / 30].stage, .wake)
        XCTAssertFalse(epochs[(20 * 60 + 3600 + 300) / 30].hasData)
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

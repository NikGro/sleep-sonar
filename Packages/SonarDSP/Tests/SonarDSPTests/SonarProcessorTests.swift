import XCTest
@testable import SonarDSP

/// Synthetisches Mikrofonsignal: direkter Schall + Körperecho mit Atmung/Puls + Rauschen.
/// Entspricht prototype/sonar_proto.py.
struct Scenario {
    var seconds = 35
    var sampleRate = 48_000.0
    var carrier = 20_000.0
    var breathsPerMinute = 15.0
    var heartBPM = 68.0
    var breathMM = 4.0
    var heartMM = 0.15
    var harmonic = 0.0
    var bodyAmplitude = 0.005
    var noise = 0.01
    /// Bewegung um 10 cm im Zeitraum (Start, Ende) in s
    var move: (Double, Double)? = nil
    var seed: UInt64 = 2
}

struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func gaussian() -> Double {
        let u1 = max(uniform(), 1e-300), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// Lässt das Szenario laufen; ruft `check` jede volle Sekunde mit (Sekunde, Ergebnis) auf.
func simulate(_ s: Scenario, chunk: Int = 4096, check: ((Int, SonarReading) -> Void)? = nil) -> SonarReading {
    let p = SonarProcessor(sampleRate: s.sampleRate, carrierHz: s.carrier)
    var rng = SplitMix64(state: s.seed)
    let lambda = SonarProcessor.speedOfSound / s.carrier
    let total = Int(Double(s.seconds) * s.sampleRate)
    var buf = [Float](repeating: 0, count: chunk)
    var pos = 0
    var nextSecond = 1
    while pos < total {
        let n = min(chunk, total - pos)
        for i in 0..<n {
            let t = Double(pos + i) / s.sampleRate
            let ph = 2 * Double.pi * s.breathsPerMinute / 60 * t
            let b = sin(ph) + s.harmonic * sin(2 * ph + 0.5) + s.harmonic * 0.5 * sin(3 * ph + 1.0)
            var d = 0.5 + s.breathMM / 1000 * b + s.heartMM / 1000 * sin(2 * .pi * s.heartBPM / 60 * t)
            if let (a, e) = s.move {
                let ramp = min(max((t - a) / (e - a), 0), 1)
                d += 0.10 * (0.5 - 0.5 * cos(.pi * ramp))
            }
            let carrierPhase = 2 * Double.pi * s.carrier * t
            let direct = 0.1 * cos(carrierPhase + 0.7)
            let body = s.bodyAmplitude * cos(carrierPhase - 4 * .pi * d / lambda + 1.3)
            buf[i] = Float(direct + body + s.noise * rng.gaussian())
        }
        buf.withUnsafeBufferPointer { p.process(UnsafeBufferPointer(rebasing: $0[0..<n]), sampleTime: Int64(pos)) }
        pos += n
        if let check, pos >= Int(Double(nextSecond) * s.sampleRate) {
            check(nextSecond, p.analyze())
            nextSecond += 1
        }
    }
    return p.analyze()
}

final class SonarProcessorTests: XCTestCase {
    func testBaseline() {
        let r = simulate(Scenario())
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.breathsPerMinute ?? 0, 15, accuracy: 0.5)
        XCTAssertTrue(r.isBreathReliable)
        XCTAssertEqual(r.breathAmplitudeMM ?? 0, 8, accuracy: 1.5)
        XCTAssertEqual(r.heartBPM ?? 0, 68, accuracy: 2)
        XCTAssertTrue(r.isHeartReliable)
        XCTAssertLessThan(r.movementMMPerSecond, SonarProcessor.movementThreshold)
        XCTAssertGreaterThan(r.snr, 3)
        XCTAssertEqual(r.waveform.count, 300)
    }

    func testFastBreathingAndPulse() {
        let r = simulate(Scenario(breathsPerMinute: 22, heartBPM: 92))
        XCTAssertEqual(r.breathsPerMinute ?? 0, 22, accuracy: 0.7)
        XCTAssertEqual(r.heartBPM ?? 0, 92, accuracy: 3)
    }

    func testSlowBreathing() {
        let r = simulate(Scenario(breathsPerMinute: 9, heartBPM: 62))
        XCTAssertEqual(r.breathsPerMinute ?? 0, 9, accuracy: 0.5)
    }

    func testIrregularBreathingDoesNotFoolPulse() {
        let r = simulate(Scenario(harmonic: 0.4))
        XCTAssertEqual(r.breathsPerMinute ?? 0, 15, accuracy: 0.5)
        XCTAssertEqual(r.heartBPM ?? 0, 68, accuracy: 3)
    }

    func testShallowBreathing() {
        let r = simulate(Scenario(breathMM: 1.5))
        XCTAssertEqual(r.breathsPerMinute ?? 0, 15, accuracy: 0.5)
        XCTAssertEqual(r.breathAmplitudeMM ?? 0, 3, accuracy: 1)
    }

    func testEmptyBedReportsNoEcho() {
        let r = simulate(Scenario(bodyAmplitude: 0))
        XCTAssertEqual(r.status, .noEcho)
        XCTAssertNil(r.breathsPerMinute)
    }

    func testMovementDetectedAndRecovers() {
        var during: SonarReading?
        var after: SonarReading?
        _ = simulate(Scenario(seconds: 60, move: (40, 42))) { sec, r in
            if sec == 42 { during = r }
            if sec == 58 { after = r }
        }
        XCTAssertEqual(during?.status, .moving)
        XCTAssertGreaterThan(during?.movementMMPerSecond ?? 0, 30)
        XCTAssertEqual(after?.status, .ok)
        XCTAssertEqual(after?.breathsPerMinute ?? 0, 15, accuracy: 0.5)
        XCTAssertGreaterThan(after?.quietSeconds ?? 0, 12)
    }

    func testOddChunkSizesAndNilSampleTime() {
        // Ungerade Blockgrößen dürfen nichts ändern
        let p = SonarProcessor()
        let s = Scenario()
        var rng = SplitMix64(state: 2)
        let lambda = SonarProcessor.speedOfSound / s.carrier
        var pos = 0
        let total = Int(35 * s.sampleRate)
        while pos < total {
            let n = min(1777, total - pos)
            var buf = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = Double(pos + i) / s.sampleRate
                let d = 0.5 + 0.004 * sin(2 * .pi * 0.25 * t)
                buf[i] = Float(0.1 * cos(2 * .pi * s.carrier * t + 0.7)
                               + 0.005 * cos(2 * .pi * s.carrier * t - 4 * .pi * d / lambda + 1.3)
                               + 0.01 * rng.gaussian())
            }
            p.process(buf)   // ohne sampleTime
            pos += n
        }
        let r = p.analyze()
        XCTAssertEqual(r.breathsPerMinute ?? 0, 15, accuracy: 0.5)
    }

    func testCircleFit() {
        let pts = (0..<100).map { i -> Complex in
            let a = Double(i) / 100 * 1.2
            return Complex(3 + 0.5 * cos(a), -2 + 0.5 * sin(a))
        }
        let fit = DSP.circleFit(pts[...])
        XCTAssertNotNil(fit)
        XCTAssertEqual(fit?.center.re ?? 0, 3, accuracy: 1e-6)
        XCTAssertEqual(fit?.center.im ?? 0, -2, accuracy: 1e-6)
        XCTAssertEqual(fit?.radius ?? 0, 0.5, accuracy: 1e-6)
    }
}

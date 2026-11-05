import XCTest
@testable import SonarDSP

/// Vergleich mit torchaudio (training/convert_coreml.py-Pipeline): Werte aus /tmp/melref.py
final class LogMelTests: XCTestCase {
    func signal() -> [Float] {
        let sr = 16000, n = 1260 * sr
        var s: UInt64 = 12345
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n {
            s = (1_103_515_245 &* s &+ 12345) % 2_147_483_648
            let noise = Double(s) / 2_147_483_648 - 0.5
            let t = Double(i) / Double(sr)
            x[i] = Float(0.2 * sin(2 * .pi * 220 * t) + 0.05 * sin(2 * .pi * 3100 * t + 0.3)
                         + 0.02 * sin(2 * .pi * 0.25 * t) * sin(2 * .pi * 800 * t) + 0.01 * noise)
        }
        return x
    }

    func testMatchesTorchaudio() {
        let x = signal()
        let mel = LogMel()
        let raw = mel.segment(Array(x[0..<(600 * 16000)]))
        XCTAssertEqual(raw.count, 6000)
        XCTAssertEqual(raw[0][0], 4.04744815826416, accuracy: 2e-3)
        XCTAssertEqual(raw[5][10], -4.413867473602295, accuracy: 2e-3)
        XCTAssertEqual(raw[1205][40], -3.9941630363464355, accuracy: 2e-3)
        let night = mel.night(x)
        XCTAssertEqual(night.epochs, 42)
        func v(_ e: Int, _ b: Int, _ k: Int) -> Float { night.values[(e * 64 + b) * 300 + k] }
        let ref: [(Int, Int, Int, Float)] = [(0, 0, 0, 16.889524459838867), (0, 10, 5, 0.9254330992698669),
            (3, 40, 299, 0.01212246809154749), (20, 63, 150, 0.21522851288318634),
            (41, 5, 200, -0.006133245769888163), (19, 32, 299, -0.04440304636955261), (20, 32, 0, 0.8754733204841614)]
        for (e, b, k, want) in ref { XCTAssertEqual(v(e, b, k), want, accuracy: 3e-3, "\(e),\(b),\(k)") }
        let mean = night.values.reduce(0, +) / Float(night.values.count)
        XCTAssertEqual(mean, -0.06450903415679932, accuracy: 1e-3)
    }
}

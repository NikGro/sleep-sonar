import Foundation

/// Kleine komplexe Zahl ohne Abhängigkeiten.
public struct Complex: Equatable, Sendable {
    public var re: Double
    public var im: Double

    public init(_ re: Double, _ im: Double) {
        self.re = re
        self.im = im
    }

    public static let zero = Complex(0, 0)
    public static func + (a: Complex, b: Complex) -> Complex { Complex(a.re + b.re, a.im + b.im) }
    public static func - (a: Complex, b: Complex) -> Complex { Complex(a.re - b.re, a.im - b.im) }
    public static func / (a: Complex, d: Double) -> Complex { Complex(a.re / d, a.im / d) }
    public var magnitude: Double { (re * re + im * im).squareRoot() }
    public var magnitudeSquared: Double { re * re + im * im }
    public var angle: Double { atan2(im, re) }
}

enum DSP {
    /// Kausaler gleitender Mittelwert (am Anfang kürzeres Fenster, kein Null-Padding).
    static func movingAverage(_ x: [Double], _ n: Int) -> [Double] {
        guard n > 1, !x.isEmpty else { return x }
        var out = [Double](repeating: 0, count: x.count)
        var sum = 0.0
        for i in 0..<x.count {
            sum += x[i]
            if i >= n { sum -= x[i - n] }
            out[i] = sum / Double(min(i + 1, n))
        }
        return out
    }

    /// Entfernt eine Gerade (kleinste Quadrate).
    static func detrend(_ x: [Double]) -> [Double] {
        let n = Double(x.count)
        guard x.count > 1 else { return x }
        var st = 0.0, sx = 0.0, stt = 0.0, stx = 0.0
        for (i, v) in x.enumerated() {
            let t = Double(i)
            st += t; sx += v; stt += t * t; stx += t * v
        }
        let den = n * stt - st * st
        let slope = den != 0 ? (n * stx - st * sx) / den : 0
        let icpt = (sx - slope * st) / n
        return x.enumerated().map { $0.element - (icpt + slope * Double($0.offset)) }
    }

    /// Phase entfalten (Sprünge > pi korrigieren).
    static func unwrap(_ p: [Double]) -> [Double] {
        guard var prev = p.first else { return p }
        var out = [prev]
        out.reserveCapacity(p.count)
        var offset = 0.0
        for v in p.dropFirst() {
            var d = v - prev
            if d > .pi { offset -= 2 * .pi; d -= 2 * .pi }
            if d < -.pi { offset += 2 * .pi; d += 2 * .pi }
            out.append(v + offset)
            prev = v
        }
        return out
    }

    /// Algebraischer Kreisfit (Kasa). Liefert Mittelpunkt und Radius.
    static func circleFit(_ z: ArraySlice<Complex>) -> (center: Complex, radius: Double)? {
        // Normalgleichungen für x^2+y^2 + D x + E y + F = 0
        var sxx = 0.0, sxy = 0.0, syy = 0.0, sx = 0.0, sy = 0.0, n = 0.0
        var sxb = 0.0, syb = 0.0, sb = 0.0
        // Zentrieren für numerische Stabilität
        var mx = 0.0, my = 0.0
        for v in z { mx += v.re; my += v.im }
        let cnt = Double(z.count)
        guard cnt >= 10 else { return nil }
        mx /= cnt; my /= cnt
        for v in z {
            let x = v.re - mx, y = v.im - my
            let b = -(x * x + y * y)
            sxx += x * x; sxy += x * y; syy += y * y
            sx += x; sy += y; n += 1
            sxb += x * b; syb += y * b; sb += b
        }
        let a: [[Double]] = [[sxx, sxy, sx], [sxy, syy, sy], [sx, sy, n]]
        guard let sol = solve3(a, [sxb, syb, sb]) else { return nil }
        let cx = -sol[0] / 2, cy = -sol[1] / 2
        let r2 = cx * cx + cy * cy - sol[2]
        guard r2 > 0, r2.isFinite else { return nil }
        return (Complex(cx + mx, cy + my), r2.squareRoot())
    }

    /// 3x3-Gleichungssystem (Cramer).
    static func solve3(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        func det(_ m: [[Double]]) -> Double {
            m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
                - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        }
        let d = det(a)
        guard abs(d) > 1e-300, d.isFinite else { return nil }
        var res = [Double](repeating: 0, count: 3)
        for col in 0..<3 {
            var m = a
            for row in 0..<3 { m[row][col] = b[row] }
            res[col] = det(m) / d
        }
        return res
    }

    /// Autokorrelation: erstes deutliches Maximum (> 0.3) im Bereich, sonst globales.
    /// Gibt (Lag mit Interpolation, Korrelation) zurück.
    static func autocorrPeak(_ sig: [Double], lagMin: Int, lagMax: Int) -> (lag: Double, value: Double)? {
        let mean = sig.reduce(0, +) / Double(max(sig.count, 1))
        let x = sig.map { $0 - mean }
        let denom = x.reduce(0) { $0 + $1 * $1 }
        let hi = min(lagMax, x.count - 2)
        guard denom > 0, hi > lagMin else { return nil }
        var vals = [Double](repeating: 0, count: hi + 2)
        for lag in lagMin...hi {
            var s = 0.0
            for i in 0..<(x.count - lag) { s += x[i] * x[i + lag] }
            vals[lag] = s / denom
        }
        var best = -1
        if lagMin + 1 < hi {
            for l in (lagMin + 1)..<hi where vals[l] > vals[l - 1] && vals[l] >= vals[l + 1] && vals[l] > 0.3 {
                best = l
                break
            }
        }
        if best < 0 {
            best = lagMin
            for l in lagMin...hi where vals[l] > vals[best] { best = l }
        }
        var lag = Double(best)
        if best > lagMin && best < hi {
            let a = vals[best - 1], b = vals[best], c = vals[best + 1]
            let den = a - 2 * b + c
            if den != 0 { lag += max(-0.5, min(0.5, 0.5 * (a - c) / den)) }
        }
        return (lag, vals[best])
    }

    /// Spektrales Maximum auf einem BPM-Raster (Hann-Fenster).
    /// Konfidenz = Peak-Leistung / mittlere Leistung im erlaubten Band.
    static func spectralPeak(_ sig: [Double], fs: Double, bpmLow: Double, bpmHigh: Double,
                             step: Double = 0.5, exclude: [Double] = [], excludeWidth: Double = 5)
        -> (bpm: Double, confidence: Double)? {
        let n = sig.count
        guard n > 16 else { return nil }
        let mean = sig.reduce(0, +) / Double(n)
        var x = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let w = 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1))
            x[i] = (sig[i] - mean) * w
        }
        var bestBPM = -1.0, bestP = -1.0, sumP = 0.0, count = 0.0
        var bpm = bpmLow
        while bpm <= bpmHigh + 1e-9 {
            defer { bpm += step }
            if exclude.contains(where: { abs($0 - bpm) <= excludeWidth }) { continue }
            let w = 2 * .pi * bpm / 60 / fs
            // Rotation statt sin/cos pro Sample
            let cw = cos(w), sw = sin(w)
            var c = 1.0, s = 0.0, re = 0.0, im = 0.0
            for i in 0..<n {
                re += x[i] * c
                im -= x[i] * s
                let nc = c * cw - s * sw
                s = s * cw + c * sw
                c = nc
            }
            let p = re * re + im * im
            sumP += p; count += 1
            if p > bestP { bestP = p; bestBPM = bpm }
        }
        guard count > 0, bestBPM > 0 else { return nil }
        return (bestBPM, bestP / (sumP / count + 1e-30))
    }
}

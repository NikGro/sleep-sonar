import Foundation

/// Regelbasierte Schlafphasen-Schätzung aus Raumgeräuschen und Handy-Bewegung (Version 5).
///
/// Eingabe: je Sekunde Gesamtpegel und Bandpegel (dBFS) sowie optional die Beschleunigung
/// des iPhones. Ausgabe: 30-s-Epochen mit Wach/Kern/Tief/REM.
///
/// Grundlage (an zwei Nächten mit Apple Watch geprüft, in beiden gleich):
/// - **Atemtempo:** Im Tiefschlaf ist die Atmung am langsamsten (Periode ~4,8–5 s), im REM am
///   schnellsten (~3,4 s), Kern liegt dazwischen.
/// - **Ruhe:** Tiefschlaf ist am leisesten und ruhigsten.
/// - **Regelmäßigkeit:** Im REM ist die Atmung am unregelmäßigsten.
/// - **Wach** wird nur aus *hellen* Geräuschen (Rascheln der Decke, ~4,5 kHz) erkannt. Dumpfe
///   Geräusche wie Schritte oder Rumpeln von Nachbarn zählen nicht.
/// Alle Schwellen sind relativ zur jeweiligen Nacht (Abweichung vom Median in Standardabweichungen),
/// damit Mikrofon, Abstand und Raum keine Rolle spielen.
public enum SleepStaging {
    public enum Stage: Int, CaseIterable, Sendable {
        case wake = 0, rem = 1, core = 2, deep = 3

        public var name: String {
            switch self {
            case .wake: "Wach"
            case .rem: "REM"
            case .core: "Kern"
            case .deep: "Tief"
            }
        }
    }

    public struct Second: Sendable {
        public var rms: Double
        public var mid: Double
        public var high: Double
        public init(rms: Double, mid: Double, high: Double) {
            self.rms = rms; self.mid = mid; self.high = high
        }
    }

    public struct Epoch: Sendable {
        public var index: Int
        public var stage: Stage
        public var events: Int
        public var regularity: Double
        /// geschätzte Atemperiode in Sekunden (0 = unbekannt)
        public var breathPeriod: Double
        public var handled: Bool
        public var hasData: Bool
    }

    public struct Parameters: Sendable {
        public var epochSeconds = 30
        /// Unruhe für die Ruhe-Bewertung: Gesamtpegel so viele dB über dem Grundpegel
        public var eventDB = 12.0
        /// Unruhe für Wach/Schlaf: helles Band (Rascheln) so viele dB über seinem Grundpegel
        public var wakeDB = 14.0
        /// Handy gilt als angefasst ab dieser mittleren Beschleunigung (g)
        public var handledG = 0.02
        /// Aktivitätsschwelle für „wach“ (gewichtete Unruhe-Sekunden)
        public var wakeScore = 14.0
        /// Nach dem Anfassen des Handys gilt man noch ± so viele Epochen als wach
        public var handledPadEpochs = 2
        /// Nach einem Wach-Rascheln bleibt man meist noch kurz still wach: so viele Epochen danach
        public var wakeTailEpochs = 4
        /// Einschlafen/Aufwachen: Fenster von so vielen Epochen …
        public var onsetWindowEpochs = 40
        /// … in dem mindestens so viele Epochen Schlaf sind (still wach liegen ist meist kürzer)
        public var onsetSleepEpochs = 36
        /// Kurze Wach-Abschnitte mitten im Schlaf (kürzer als so viele Epochen) → Schlaf
        public var minWakeEpochs = 4
        /// Mittelung der Merkmale: ± so viele Epochen
        public var smoothEpochs = 5
        /// Tief, wenn Tief-Wert über dieser Schwelle (Standardabweichungen)
        public var deepThreshold = 1.06
        /// REM, wenn REM-Wert über dieser Schwelle
        public var remThreshold = 0.37
        public var weightBreathPeriod = 0.89
        public var weightLevel = 0.85
        public var weightUnrest = 1.18
        public var weightIrregularity = 0.60
        /// REM frühestens so viele Epochen nach dem Einschlafen
        public var remDelayEpochs = 74
        /// Mehrheitsglättung: ± so viele Epochen
        public var majorityEpochs = 10
        /// Tief/REM-Blöcke kürzer als so viele Epochen → Kern
        public var minBlockEpochs = 13
        public init() {}
    }

    /// - Parameters:
    ///   - seconds: ein Eintrag je Sekunde ab Start; `nil` = Lücke (keine Daten)
    ///   - motion: Beschleunigung je Sekunde (gleiche Zeitachse), `nil` = unbekannt
    ///   - sleepSounds: Sekunden mit Schlafgeräuschen (z. B. Schnarchen) – zählen nicht als Unruhe
    ///   - wakeSounds: Sekunden mit Wachgeräuschen (z. B. Husten) – zählen immer als Unruhe
    public static func estimate(seconds: [Second?], motion: [Double?] = [],
                                sleepSounds: Set<Int> = [], wakeSounds: Set<Int> = [],
                                parameters p: Parameters = Parameters()) -> [Epoch] {
        let ep = p.epochSeconds
        let n = seconds.count / ep
        guard n > 0 else { return [] }

        // 1) Grundpegel (20-%-Quantil in ±150 s) für Gesamtpegel und helles Band
        let rms = seconds.map { $0?.rms }
        let high = seconds.map { $0?.high }
        let mid = seconds.map { $0?.mid }
        let baseRMS = baselines(rms, n: n, ep: ep)
        let baseHigh = baselines(high, n: n, ep: ep)

        // 2) Je Epoche: Unruhe, angefasst, Pegel, Atemtempo, Regelmäßigkeit
        var epochs: [Epoch] = []
        epochs.reserveCapacity(n)
        var wakeUnrest = [Double](repeating: 0, count: n)
        var level = [Double](repeating: 0, count: n)
        for e in 0..<n {
            let a = e * ep, b = a + ep
            var events = 0, valid = 0, sum = 0.0, wakeEvents = 0
            for s in a..<b {
                guard let v = rms[s] else { continue }
                valid += 1
                sum += v
                if v - baseRMS[e] > p.eventDB { events += 1 }
                if wakeSounds.contains(s) {
                    wakeEvents += 1
                } else if let h = high[s], h - baseHigh[e] > p.wakeDB, !sleepSounds.contains(s) {
                    wakeEvents += 1
                }
            }
            var handled = false
            if !motion.isEmpty {
                for s in a..<min(b, motion.count) where (motion[s] ?? 0) > p.handledG { handled = true; break }
            }
            let c = a + ep / 2
            let periods = [breathPeriod(mid, center: c),
                           breathPeriod(high, center: c)].compactMap { $0 }
            let period = periods.isEmpty ? 0 : periods.reduce(0, +) / Double(periods.count)
            let reg = autocorrelation(high, center: c, half: 150, lags: 2...12)?.best ?? 0
            wakeUnrest[e] = Double(wakeEvents)
            level[e] = valid > 0 ? sum / Double(valid) : -120
            epochs.append(Epoch(index: e, stage: .core, events: events, regularity: reg, breathPeriod: period,
                                handled: handled, hasData: valid >= ep / 2))
        }

        // 3) Wach/Schlaf mit gewichteter Nachbarschaft (ähnlich Aktigraphie)
        let weights: [(Int, Double)] = [(-4, 0.15), (-3, 0.15), (-2, 0.15), (-1, 0.3), (0, 1.0), (1, 0.3), (2, 0.15)]
        var burst = [Bool](repeating: false, count: n)
        for e in 0..<n {
            var score = 0.0
            for (k, w) in weights where e + k >= 0 && e + k < n { score += w * wakeUnrest[e + k] }
            burst[e] = score > p.wakeScore
        }
        // sicher wach: Handy angefasst oder still nach einem Wach-Rascheln – jeweils ± ein wenig Rand
        var marked = epochs.map(\.handled)
        if p.wakeTailEpochs > 0 {
            for e in 0..<n where !burst[e] {
                if (max(0, e - p.wakeTailEpochs)..<e).contains(where: { burst[$0] }) { marked[e] = true }
            }
        }
        var handled = marked
        if p.handledPadEpochs > 0 {
            for e in 0..<n where marked[e] {
                for k in max(0, e - p.handledPadEpochs)...min(n - 1, e + p.handledPadEpochs) { handled[k] = true }
            }
        }
        var asleep = [Bool](repeating: false, count: n)
        for e in 0..<n where epochs[e].hasData && !handled[e] { asleep[e] = !burst[e] }
        // kurze Schlafinseln (< 1,5 min) zwischen Wach → wach
        var i = 0
        while i < n {
            guard asleep[i] else { i += 1; continue }
            var j = i
            while j < n && asleep[j] { j += 1 }
            if j - i < 3 && i > 0 && j < n { for k in i..<j { asleep[k] = false } }
            i = j
        }
        // Einschlafen / Aufwachen: 20-min-Fenster mit ≥ 90 % Schlaf
        let win = p.onsetWindowEpochs, need = p.onsetSleepEpochs
        var onset = n, offset = -1
        if n >= win {
            for s in 0...(n - win) where asleep[s..<(s + win)].filter({ $0 }).count >= need { onset = s; break }
            for s in stride(from: n - win, through: 0, by: -1)
            where asleep[s..<(s + win)].filter({ $0 }).count >= need { offset = s + win - 1; break }
        }
        for e in 0..<n where e < onset || e > offset { asleep[e] = false }
        // kurze Wach-Striche mitten im Schlaf → Schlaf (Watch-ähnlich ruhiger)
        i = max(onset, 0)
        while i <= offset && i < n {
            if asleep[i] { i += 1; continue }
            var j = i
            while j <= offset && !asleep[j] { j += 1 }
            let touched = (i..<j).contains { handled[$0] || !epochs[$0].hasData }
            if j - i < p.minWakeEpochs && !touched { for k in i..<j { asleep[k] = true } }
            i = j
        }

        // 4) Phasen innerhalb des Schlafs über relative Merkmale
        let sleepIdx = (0..<n).filter { asleep[$0] }
        var stages = [Stage](repeating: .wake, count: n)
        if sleepIdx.count >= 20 {
            let k = p.smoothEpochs
            let knownPeriods = sleepIdx.map { epochs[$0].breathPeriod }.filter { $0 > 0 }.sorted()
            let fallback = knownPeriods.isEmpty ? 4 : knownPeriods[knownPeriods.count / 2]
            func z(_ raw: [Double]) -> [Double] {
                let x = movingMean(raw, k)
                let vals = sleepIdx.map { x[$0] }.sorted()
                let median = vals[vals.count / 2]
                let mean = vals.reduce(0, +) / Double(vals.count)
                let sd = (vals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(vals.count)).squareRoot() + 1e-9
                return x.map { ($0 - median) / sd }
            }
            let zPeriod = z(epochs.map { $0.breathPeriod > 0 ? $0.breathPeriod : fallback })
            let zLevel = z(level)
            let zUnrest = z(epochs.map { Double($0.events) })
            let zReg = z(epochs.map(\.regularity))
            let onsetIdx = sleepIdx[0]
            for e in sleepIdx {
                let deepScore = p.weightBreathPeriod * zPeriod[e] - p.weightLevel * zLevel[e] - p.weightUnrest * zUnrest[e]
                let remScore = -p.weightBreathPeriod * zPeriod[e] - p.weightIrregularity * zReg[e]
                if deepScore > p.deepThreshold {
                    stages[e] = .deep
                } else if remScore > p.remThreshold && e - onsetIdx >= p.remDelayEpochs {
                    stages[e] = .rem
                } else {
                    stages[e] = .core
                }
            }
        }
        stages = smooth(stages, asleep: asleep, majority: p.majorityEpochs, minBlock: p.minBlockEpochs)
        for e in 0..<n { epochs[e].stage = stages[e] }
        return epochs
    }

    static func baselines(_ x: [Double?], n: Int, ep: Int) -> [Double] {
        (0..<n).map { e in
            let c = e * ep + ep / 2
            let lo = max(0, c - 150), hi = min(x.count, c + 150)
            let vals = x[lo..<hi].compactMap { $0 }.sorted()
            return vals.isEmpty ? -120 : vals[vals.count / 5]
        }
    }

    /// Autokorrelation des Pegels in [center−half, center+half): bestes Maximum und dessen Lag.
    static func autocorrelation(_ x: [Double?], center: Int, half: Int,
                                lags: ClosedRange<Int>) -> (best: Double, lag: Int, r: [Int: Double])? {
        let lo = center - half, hi = center + half
        guard lo >= 0, hi <= x.count else { return nil }
        let w = x[lo..<hi]
        guard w.allSatisfy({ $0 != nil }) else { return nil }
        let v = w.map { $0! }
        let m = v.reduce(0, +) / Double(v.count)
        let d = v.map { $0 - m }
        let denom = d.reduce(0) { $0 + $1 * $1 }
        guard denom > 1e-9 else { return nil }
        var r: [Int: Double] = [:]
        var best = -1.0, bestLag = lags.lowerBound
        for lag in (lags.lowerBound - 1)...(lags.upperBound + 1) where lag >= 1 && lag < d.count {
            var s = 0.0
            for i in 0..<(d.count - lag) { s += d[i] * d[i + lag] }
            r[lag] = s / denom
            if lags.contains(lag), r[lag]! > best { best = r[lag]!; bestLag = lag }
        }
        return (max(best, 0), bestLag, r)
    }

    /// Atemperiode (s): Maximum der Autokorrelation (2–12 s) im 2-min-Fenster, per Parabel verfeinert.
    static func breathPeriod(_ x: [Double?], center: Int) -> Double? {
        guard let a = autocorrelation(x, center: center, half: 60, lags: 2...12),
              let y0 = a.r[a.lag - 1], let y1 = a.r[a.lag], let y2 = a.r[a.lag + 1] else { return nil }
        let den = y0 - 2 * y1 + y2
        let off = abs(den) > 1e-9 ? min(0.5, max(-0.5, 0.5 * (y0 - y2) / den)) : 0
        return Double(a.lag) + off
    }

    /// Atemregelmäßigkeit (für Anzeige/Tests): Autokorrelations-Maximum des hellen Bandes, 2 min um `center`.
    static func regularity(_ seconds: [Second?], center: Int) -> Double {
        autocorrelation(seconds.map { $0?.high }, center: center, half: 60, lags: 3...10)?.best ?? 0
    }

    static func movingMean(_ x: [Double], _ k: Int) -> [Double] {
        (0..<x.count).map { i in
            let lo = max(0, i - k), hi = min(x.count - 1, i + k)
            return x[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
    }

    /// Glättung: Mehrheit im Fenster ±`majority`, zu kurze Tief/REM-Blöcke → Kern.
    static func smooth(_ s: [Stage], asleep: [Bool], majority: Int, minBlock: Int) -> [Stage] {
        var out = s
        for i in 0..<s.count where asleep[i] {
            var counts = [Stage: Int]()
            for k in -majority...majority where i + k >= 0 && i + k < s.count && asleep[i + k] { counts[s[i + k], default: 0] += 1 }
            if let best = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key.rawValue > $1.key.rawValue) })?.key {
                out[i] = best
            }
        }
        var i = 0
        while i < out.count {
            let st = out[i]
            var j = i
            while j < out.count && out[j] == st { j += 1 }
            if (st == .deep || st == .rem) && j - i < minBlock { for k in i..<j { out[k] = .core } }
            i = j
        }
        return out
    }

    /// Übereinstimmung zweier Hypnogramme (nur Epochen, wo beide etwas haben).
    public static func agreement(_ a: [Stage?], _ b: [Stage?]) -> (fourClass: Double, sleepWake: Double, epochs: Int) {
        var same = 0, sw = 0, total = 0
        for (x, y) in zip(a, b) {
            guard let x, let y else { continue }
            total += 1
            if x == y { same += 1 }
            if (x == .wake) == (y == .wake) { sw += 1 }
        }
        guard total > 0 else { return (0, 0, 0) }
        return (Double(same) / Double(total), Double(sw) / Double(total), total)
    }
}

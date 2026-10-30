import Foundation

/// Erste, regelbasierte Schlafphasen-Schätzung aus Raumgeräuschen und Handy-Bewegung.
///
/// Eingabe: je Sekunde Gesamtpegel und Bandpegel (dBFS) sowie optional die
/// Beschleunigung des iPhones. Ausgabe: 30-s-Epochen mit Wach/Kern/Tief/REM.
///
/// Idee (bewusst einfach, wird mit echten Watch-Nächten nachjustiert):
/// - Geräuschereignisse = Sekunden deutlich über dem ruhigen Grundpegel (Rascheln, Bewegung, Husten …)
/// - Wach = viele Ereignisse in der Umgebung (wie Aktigraphie) oder iPhone angefasst
/// - Einschlafen/Aufwachen = erstes/letztes Fenster mit 10 min überwiegend Schlaf
/// - Tief = lange ganz ruhig + regelmäßiger Atemrhythmus (im Hochton-Band), eher früh in der Nacht
/// - REM = ruhig, aber unregelmäßig, frühestens 60 min nach dem Einschlafen
/// - sonst Kern
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
        public var handled: Bool
        public var hasData: Bool
    }

    public struct Parameters: Sendable {
        public var epochSeconds = 30
        /// Ereignis: so viele dB über dem ruhigen Grundpegel
        public var eventDB = 6.0
        /// Handy gilt als angefasst ab dieser mittleren Beschleunigung (g)
        public var handledG = 0.02
        /// Aktivitätsschwelle für „wach“ (gewichtete Ereignissekunden)
        public var wakeScore = 6.0
        public var deepRegularity = 0.45
        public var remMaxRegularity = 0.3
        public init() {}
    }

    /// - Parameters:
    ///   - seconds: ein Eintrag je Sekunde ab Start; `nil` = Lücke (keine Daten)
    ///   - motion: Beschleunigung je Sekunde (gleiche Zeitachse), `nil` = unbekannt
    public static func estimate(seconds: [Second?], motion: [Double?] = [],
                                parameters p: Parameters = Parameters()) -> [Epoch] {
        let n = seconds.count / p.epochSeconds
        guard n > 0 else { return [] }

        // 1) Grundpegel: 20-%-Quantil in ±150 s, je Epoche
        let rms = seconds.map { $0?.rms }
        var baseline = [Double](repeating: -120, count: n)
        for e in 0..<n {
            let c = e * p.epochSeconds + p.epochSeconds / 2
            let lo = max(0, c - 150), hi = min(rms.count, c + 150)
            let vals = rms[lo..<hi].compactMap { $0 }.sorted()
            if !vals.isEmpty { baseline[e] = vals[vals.count / 5] }
        }

        // 2) Je Epoche: Ereignisse, angefasst, Atemregelmäßigkeit
        var epochs: [Epoch] = []
        epochs.reserveCapacity(n)
        for e in 0..<n {
            let a = e * p.epochSeconds, b = a + p.epochSeconds
            var events = 0, valid = 0
            for s in a..<b {
                guard let v = rms[s] else { continue }
                valid += 1
                if v - baseline[e] > p.eventDB { events += 1 }
            }
            var handled = false
            if !motion.isEmpty {
                for s in a..<min(b, motion.count) where (motion[s] ?? 0) > p.handledG { handled = true; break }
            }
            let reg = regularity(seconds, center: a + p.epochSeconds / 2)
            epochs.append(Epoch(index: e, stage: .core, events: events, regularity: reg,
                                handled: handled, hasData: valid >= p.epochSeconds / 2))
        }

        // 3) Wach/Schlaf mit gewichteter Nachbarschaft (ähnlich Aktigraphie)
        let weights: [(Int, Double)] = [(-4, 0.15), (-3, 0.15), (-2, 0.15), (-1, 0.3), (0, 1.0), (1, 0.3), (2, 0.15)]
        var asleep = [Bool](repeating: false, count: n)
        for e in 0..<n {
            guard epochs[e].hasData, !epochs[e].handled else { continue }
            var score = 0.0
            for (k, w) in weights where e + k >= 0 && e + k < n {
                score += w * Double(epochs[e + k].events)
            }
            asleep[e] = score <= p.wakeScore
        }
        // kurze Schlafinseln (< 1,5 min) zwischen Wach → wach
        var i = 0
        while i < n {
            guard asleep[i] else { i += 1; continue }
            var j = i
            while j < n && asleep[j] { j += 1 }
            if j - i < 3 && i > 0 && j < n { for k in i..<j { asleep[k] = false } }
            i = j
        }

        // 4) Einschlafen / Aufwachen: 10-min-Fenster mit ≥ 90 % Schlaf
        let win = 20
        var onset = n, offset = -1
        if n >= win {
            for s in 0...(n - win) where asleep[s..<(s + win)].filter({ $0 }).count >= 18 { onset = s; break }
            for s in stride(from: n - win, through: 0, by: -1)
            where asleep[s..<(s + win)].filter({ $0 }).count >= 18 { offset = s + win - 1; break }
        }
        for e in 0..<n where e < onset || e > offset { asleep[e] = false }

        // 5) Phasen innerhalb des Schlafs
        let span = max(1, offset - onset)
        var stages = [Stage](repeating: .wake, count: n)
        for e in 0..<n where asleep[e] {
            var quiet = true
            for k in -6...6 where e + k >= 0 && e + k < n && epochs[e + k].events > 0 { quiet = false; break }
            let progress = Double(e - onset) / Double(span)
            let r = epochs[e].regularity
            if quiet && r >= p.deepRegularity && progress < 0.6 {
                stages[e] = .deep
            } else if quiet && r < p.remMaxRegularity && e - onset >= 120 {
                stages[e] = .rem
            } else {
                stages[e] = .core
            }
        }
        stages = smooth(stages, asleep: asleep)
        for e in 0..<n { epochs[e].stage = stages[e] }
        return epochs
    }

    /// Atemregelmäßigkeit: Autokorrelations-Maximum des Hochton-Pegels
    /// (Atemrauschen) in 2 Minuten um `center`, Perioden 3–10 s.
    static func regularity(_ seconds: [Second?], center: Int) -> Double {
        let lo = max(0, center - 60), hi = min(seconds.count, center + 60)
        let x = seconds[lo..<hi].map { $0?.high }
        guard x.count >= 60, x.allSatisfy({ $0 != nil }) else { return 0 }
        let v = x.map { $0! }
        let m = v.reduce(0, +) / Double(v.count)
        let d = v.map { $0 - m }
        let denom = d.reduce(0) { $0 + $1 * $1 }
        guard denom > 1e-9 else { return 0 }
        var best = 0.0
        for lag in 3...10 {
            var s = 0.0
            for k in 0..<(d.count - lag) { s += d[k] * d[k + lag] }
            best = max(best, s / denom)
        }
        return best
    }

    /// Glättung: Mehrheit im 7er-Fenster, Tief/REM-Blöcke unter 3 min → Kern.
    static func smooth(_ s: [Stage], asleep: [Bool]) -> [Stage] {
        var out = s
        for i in 0..<s.count where asleep[i] {
            var counts = [Stage: Int]()
            for k in -3...3 where i + k >= 0 && i + k < s.count && asleep[i + k] { counts[s[i + k], default: 0] += 1 }
            if let best = counts.max(by: { $0.value < $1.value })?.key { out[i] = best }
        }
        var i = 0
        while i < out.count {
            let st = out[i]
            var j = i
            while j < out.count && out[j] == st { j += 1 }
            if (st == .deep || st == .rem) && j - i < 6 { for k in i..<j { out[k] = .core } }
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

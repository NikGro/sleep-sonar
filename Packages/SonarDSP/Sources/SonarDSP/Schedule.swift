import Foundation

/// Reine Zeitrechnung für Wecker und Ausblend-Bereiche – ohne App-Zustand, damit sie testbar ist.
public enum AlarmTimes {
    /// Nächste Weckzeit (Uhrzeit `wakeMinutes` nach Mitternacht) nach `from`.
    /// `repeatDays`: Wochentage nach Calendar (1 = Sonntag … 7 = Samstag), leer = nächstes Vorkommen.
    public static func next(wakeMinutes: Int, repeatDays: Set<Int>, after from: Date,
                            calendar cal: Calendar = .current) -> Date? {
        for dayOffset in 0...7 {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: from),
                  let at = cal.date(bySettingHour: wakeMinutes / 60, minute: wakeMinutes % 60, second: 0, of: day),
                  at > from else { continue }
            if repeatDays.isEmpty || repeatDays.contains(cal.component(.weekday, from: at)) { return at }
        }
        return nil
    }

    /// Derselbe Wochentag und dieselbe Uhrzeit in den folgenden `weeks` Wochen (Sommerzeit-fest)
    public static func followUps(after latest: Date, weeks: Int, calendar cal: Calendar = .current) -> [Date] {
        (1...max(1, weeks)).compactMap { cal.date(byAdding: .day, value: 7 * $0, to: latest) }
    }
}

/// Bereiche im Spektrogramm (10 Bilder je Sekunde), die die Auswertung ausblendet.
public enum MaskRanges {
    /// Aus Klänge-an/aus-Marken (Sekunden ab Aufnahmebeginn): 2 s vor „an“ bis 35 s nach „aus“
    /// (Nachhall, Ausblenden). Fehlt „aus“, höchstens 3 h. Kaputte Werte werden übergangen.
    public static func sounds(_ marks: [(seconds: Double, on: Bool)]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        func append(_ from: Double, _ to: Double) {
            guard from.isFinite, to.isFinite, to > from, abs(to) < 1e7 else { return }
            out.append(Int(from * 10)..<Int(to * 10))
        }
        var on: Double?
        for m in marks.sorted(by: { $0.seconds < $1.seconds }) {
            if m.on { if on == nil { on = m.seconds } }
            else if let o = on { append(o - 2, m.seconds + 35); on = nil }
        }
        if let o = on { append(o - 2, o + 3 * 3600) }
        return out
    }

    /// Aussetzer aus gaps.csv („from_s,to_s“, Sekunden auf der Zeitachse des Tons)
    public static func gaps(csv: String) -> [Range<Int>] {
        csv.split(separator: "\n").dropFirst().compactMap { line in
            let c = line.split(separator: ",")
            guard c.count == 2, let a = Double(c[0]), let b = Double(c[1]), a.isFinite, b.isFinite,
                  b > a, a >= 0, b < 1e6 else { return nil }
            return Int(a * 10)..<Int(b * 10)
        }
    }

    /// Summe der Sprünge (> 5 s) zwischen aufeinanderfolgenden Zeitstempeln, in Sekunden
    public static func timestampGaps(_ times: [Date]) -> Double {
        zip(times, times.dropFirst()).reduce(0) { sum, p in
            let d = p.1.timeIntervalSince(p.0)
            return d > 5 ? sum + d - 1 : sum
        }
    }
}

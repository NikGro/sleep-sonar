import SonarDSP

/// Schlafwert 0–100 aus der eigenen Phasenschätzung.
/// Dauer 50, Ruhe (Schlaf im Verhältnis zur Zeit zwischen Einschlafen und Aufwachen) 20,
/// Tief + REM 20, wenig Aufwachen 10.
struct SleepScore: Codable, Equatable {
    var total: Int
    var duration: Int
    var efficiency: Int
    var depth: Int
    var interruptions: Int

    static func compute(_ stages: [SleepStaging.Stage], epochSeconds: Double) -> SleepScore? {
        guard let first = stages.firstIndex(where: { $0 != .wake }),
              let last = stages.lastIndex(where: { $0 != .wake }) else { return nil }
        let asleep = stages.filter { $0 != .wake }.count
        let hours = Double(asleep) * epochSeconds / 3600
        guard hours >= 1 else { return nil }
        func clamp(_ x: Double) -> Double { min(1, max(0, x)) }

        // 7,5 h und mehr = volle Punkte, unter 3 h keine
        let duration = clamp((hours - 3) / 4.5) * 50
        let efficiency = clamp((Double(asleep) / Double(last - first + 1) - 0.75) / 0.2) * 20
        let deepRem = stages.filter { $0 == .deep || $0 == .rem }.count
        let depth = clamp((Double(deepRem) / Double(asleep) - 0.15) / 0.25) * 20
        // Aufwachen ab 1 min zwischen Einschlafen und Aufwachen: je 2 Punkte Abzug
        var wakes = 0, i = first
        while i <= last {
            if stages[i] == .wake {
                var j = i
                while j <= last && stages[j] == .wake { j += 1 }
                if Double(j - i) * epochSeconds >= 60 { wakes += 1 }
                i = j
            } else { i += 1 }
        }
        let interruptions = Double(max(0, 10 - 2 * wakes))
        let parts = [duration, efficiency, depth, interruptions].map { Int($0.rounded()) }
        return SleepScore(total: parts.reduce(0, +), duration: parts[0], efficiency: parts[1],
                          depth: parts[2], interruptions: parts[3])
    }
}

import SwiftUI

/// Schlafwert als Mondphase: 0 = Neumond, 100 = Vollmond (wie das Mond-Motiv der App).
struct ScoreMoon: View {
    let score: Int
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            Circle().fill(Theme.raised)
            Circle().strokeBorder(Theme.hairline, lineWidth: 1)
            MoonPhase(lit: Double(score) / 100)
                .fill(RadialGradient(colors: [Theme.moon, Theme.moon.opacity(0.82)],
                                     center: UnitPoint(x: 0.62, y: 0.35), startRadius: 1, endRadius: size * 0.7))
                .shadow(color: Theme.moon.opacity(0.35 * Double(score) / 100), radius: size * 0.22)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Schlafwert %d von 100", score))
    }
}

/// Beleuchteter Teil des Mondes (zunehmend, Licht von rechts).
struct MoonPhase: Shape {
    var lit: Double

    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let f = min(1, max(0, lit))
        guard f > 0.005 else { return Path() }
        // Schattengrenze: Halbellipse mit Halbachse r·(1−2f); rechts gewölbt = Sichel, links = Dreiviertel
        let rx = r * (1 - 2 * f)
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y - r))
        p.addArc(center: c, radius: r, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        let steps = 48
        for i in 1...steps {
            let t = Double.pi / 2 - Double.pi * Double(i) / Double(steps)   // +90° … −90°
            p.addLine(to: CGPoint(x: c.x + rx * cos(t), y: c.y + r * sin(t)))
        }
        p.closeSubpath()
        return p
    }
}

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

/// Schlafwert als Ring mit Zahl.
struct ScoreRing: View {
    let score: Int
    var size: CGFloat = 64
    var line: CGFloat = 5

    var body: some View {
        ZStack {
            Circle().stroke(Theme.hairline, lineWidth: line)
            // Bogen von Tiefschlaf-Blau über REM-Violett zur Morgendämmerung
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(AngularGradient(colors: [Theme.color(.deep), Theme.color(.rem), Theme.color(.wake)],
                                        center: .center, startAngle: .zero,
                                        endAngle: .degrees(360 * Double(max(score, 1)) / 100)),
                        style: StrokeStyle(lineWidth: line, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            Text("\(score)")
                .font(Theme.display(size * 0.38).monospacedDigit())
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Schlafwert %d von 100", score))
    }
}

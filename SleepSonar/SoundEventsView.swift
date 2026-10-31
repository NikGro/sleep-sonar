import Charts
import SwiftUI

/// Geräusche der Nacht: Zeitleiste, Zusammenfassung je Art und abspielbare Momente.
struct SoundSection: View {
    let events: [SoundEvent]
    let start: Date
    let total: Double
    let folder: URL
    @ObservedObject var player: NightClipPlayer
    @State private var expanded: Set<SoundEvent.Kind> = []

    private var kinds: [SoundEvent.Kind] {
        SoundEvent.Kind.allCases.filter { k in events.contains { $0.kind == k } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionTitle("Geräusche")
            if events.isEmpty {
                Text("Keine auffälligen Geräusche erkannt. Für Nächte ohne Audio (oder wenn es gelöscht wurde) "
                     + "lässt sich das nicht auswerten.")
                    .font(.callout).foregroundStyle(Theme.mist)
            } else {
                timeline
                ForEach(kinds, id: \.self) { kind in kindBlock(kind) }
                Text("Erkannt mit Apples Geräuscherkennung direkt auf dem iPhone. Schnarchen zählt in der "
                     + "Auswertung als Schlaf, Sprechen und Husten als Unruhe.")
                    .font(.caption).foregroundStyle(Theme.mist)
            }
        }
    }

    // Eine Zeile je Geräuschart über die ganze Nacht
    private var timeline: some View {
        Chart(events) { e in
            RectangleMark(xStart: .value("von", start.addingTimeInterval(e.start)),
                          xEnd: .value("bis", start.addingTimeInterval(max(e.end, e.start + 45))),
                          y: .value("Art", e.kind.name), height: .ratio(0.6))
                .foregroundStyle(Theme.moon.opacity(0.35 + 0.65 * e.confidence))
                .cornerRadius(2)
        }
        .chartXScale(domain: start...start.addingTimeInterval(max(total, 60)))
        .chartYScale(domain: kinds.map(\.name))
        .chartYAxis {
            AxisMarks { _ in AxisValueLabel().foregroundStyle(Theme.mist) }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour)) { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel(format: .dateTime.hour()).foregroundStyle(Theme.mist)
            }
        }
        .frame(height: CGFloat(28 * kinds.count + 30))
        .accessibilityLabel("Zeitleiste der Geräusche")
    }

    @ViewBuilder private func kindBlock(_ kind: SoundEvent.Kind) -> some View {
        let list = events.filter { $0.kind == kind }
        // Die deutlichsten Momente zuerst anbieten
        let best = list.sorted { $0.confidence * min($0.duration, 60) > $1.confidence * min($1.duration, 60) }
        let shown = expanded.contains(kind) ? best : Array(best.prefix(3))
        let minutes = Int((list.reduce(0) { $0 + $1.duration } / 60).rounded())

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(kind.name, systemImage: kind.symbol).font(.callout.weight(.medium))
                Spacer()
                Text(summary(count: list.count, minutes: minutes))
                    .font(.callout.monospacedDigit()).foregroundStyle(Theme.mist)
            }
            ForEach(shown) { e in clipRow(e) }
            if best.count > 3 {
                Button(expanded.contains(kind) ? "Weniger anzeigen" : "Alle \(best.count) anzeigen") {
                    if expanded.contains(kind) { expanded.remove(kind) } else { expanded.insert(kind) }
                }
                .font(.caption)
                .foregroundStyle(Theme.mist)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.raised))
    }

    private func clipRow(_ e: SoundEvent) -> some View {
        let playing = player.playingID == e.id
        return Button {
            player.toggle(e, folder: folder)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: playing ? "stop.fill" : "play.fill")
                    .font(.system(size: 12))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(playing ? Theme.moon : Theme.hairline))
                    .foregroundStyle(playing ? Theme.ink : Theme.moon)
                Text(start.addingTimeInterval(e.start).formatted(date: .omitted, time: .shortened))
                    .font(.callout.monospacedDigit())
                Text(duration(e.duration)).font(.caption).foregroundStyle(Theme.mist)
                Spacer()
                ConfidenceDots(value: e.confidence)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(e.kind.name) um \(start.addingTimeInterval(e.start).formatted(date: .omitted, time: .shortened)), \(playing ? "stoppen" : "abspielen")")
    }

    private func summary(count: Int, minutes: Int) -> String {
        let times = count == 1 ? "1-mal" : "\(count)-mal"
        return minutes >= 1 ? "\(times), \(minutes) min" : times
    }

    private func duration(_ s: Double) -> String {
        s < 60 ? "\(Int(s.rounded())) s" : "\(Int(s / 60)) min \(Int(s.truncatingRemainder(dividingBy: 60))) s"
    }
}

/// Wie sicher die Erkennung war: drei Punkte.
private struct ConfidenceDots: View {
    let value: Double
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Double(i) < (value - 0.4) / 0.2 ? Theme.moon : Theme.hairline)
                    .frame(width: 5, height: 5)
            }
        }
        .accessibilityLabel("Sicherheit \(Int(value * 100)) Prozent")
    }
}

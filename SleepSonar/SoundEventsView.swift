import SwiftUI

/// Geräusche der Nacht: Zusammenfassung je Art und abspielbare Momente.
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
            SectionTitle(tr("Geräusche im Schlaf"))
            if events.isEmpty {
                Text(tr("Während des Schlafs wurden keine auffälligen Geräusche erkannt. Für Nächte ohne Audio lässt sich das nicht auswerten."))
                    .font(.callout).foregroundStyle(Theme.mist)
            } else {
                ForEach(kinds, id: \.self) { kind in kindBlock(kind) }
                Text(tr("Erkannt mit Apples Geräuscherkennung direkt auf dem iPhone. Gezeigt wird nur, was während des Schlafs war. Zum Anhören wird jeder Moment automatisch lauter gemacht."))
                    .font(.caption).foregroundStyle(Theme.mist)
            }
        }
    }

    @ViewBuilder private func kindBlock(_ kind: SoundEvent.Kind) -> some View {
        let list = events.filter { $0.kind == kind }
        // Die deutlichsten Momente zuerst anbieten
        let best = list.sorted { $0.confidence * min($0.duration, 60) > $1.confidence * min($1.duration, 60) }
        let shown = expanded.contains(kind) ? best : Array(best.prefix(3))
        let minutes = Int((list.reduce(0) { $0 + $1.duration } / 60).rounded())

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(kind.displayName, systemImage: kind.symbol).font(.callout.weight(.medium))
                Spacer()
                Text(summary(count: list.count, minutes: minutes))
                    .font(.callout.monospacedDigit()).foregroundStyle(Theme.mist)
            }
            ForEach(shown) { e in clipRow(e) }
            if best.count > 3 {
                Button(expanded.contains(kind) ? tr("Weniger anzeigen") : tr("Alle %d anzeigen", best.count)) {
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
        .accessibilityLabel(tr(playing ? "%@ um %@, stoppen" : "%@ um %@, abspielen", e.kind.displayName,
                               start.addingTimeInterval(e.start).formatted(date: .omitted, time: .shortened)))
    }

    private func summary(count: Int, minutes: Int) -> String {
        let times = tr("%d-mal", count)
        return minutes >= 1 ? tr("%@, %d min", times, minutes) : times
    }

    private func duration(_ s: Double) -> String {
        s < 60 ? tr("%d s", Int(s.rounded())) : tr("%d min %d s", Int(s / 60), Int(s.truncatingRemainder(dividingBy: 60)))
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
        .accessibilityLabel(tr("Sicherheit %d Prozent", Int(value * 100)))
    }
}

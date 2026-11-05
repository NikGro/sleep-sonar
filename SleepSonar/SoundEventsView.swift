import SwiftUI

/// Geräusche der Nacht: Zusammenfassung je Art und abspielbare Momente.
struct SoundSection: View {
    /// ab dieser Sicherheit wird ein Geräusch gezeigt (darunter zu oft Fehlalarm)
    static let minConfidence = 0.6
    private let events: [SoundEvent]
    let start: Date
    let total: Double
    let folder: URL
    @ObservedObject var player: NightClipPlayer
    @State private var expanded: Set<SoundEvent.Kind> = []
    @State private var levels: ClipLevels?

    init(events: [SoundEvent], start: Date, total: Double, folder: URL, player: NightClipPlayer) {
        self.events = events.filter { $0.confidence >= Self.minConfidence }
        self.start = start
        self.total = total
        self.folder = folder
        _player = ObservedObject(wrappedValue: player)
    }

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
        .task(id: folder) {
            let f = folder
            levels = await Task.detached(priority: .utility) { ClipLevels.load(f) }.value
        }
    }

    @ViewBuilder private func kindBlock(_ kind: SoundEvent.Kind) -> some View {
        let list = events.filter { $0.kind == kind }
        // Die sichersten zuerst (bei gleicher Sicherheit die längeren)
        let best = list.sorted { ($0.confidence, $0.duration) > ($1.confidence, $1.duration) }
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
                // Lautstärke-Linie wie bei einer Sprachnachricht
                Group {
                    if let levels { MiniWaveform(levels: levels, event: e, player: playing ? player : nil) } else { Color.clear }
                }
                .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
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

/// Wie sicher die Erkennung war: drei Punkte (ab 60 % einer, ab 75 % zwei, ab 90 % drei).
private struct ConfidenceDots: View {
    let value: Double
    private static let steps = [SoundSection.minConfidence, 0.75, 0.9]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(value >= Self.steps[i] ? Theme.moon : Theme.hairline)
                    .frame(width: 5, height: 5)
            }
        }
        .accessibilityLabel(tr("Sicherheit %d Prozent", Int(value * 100)))
    }
}

/// Gesamtpegel je Sekunde (aus levels.csv) für die Lautstärke-Linien.
struct ClipLevels: Sendable {
    let rms: [Float]
    /// Grundpegel (20-%-Quantil der Nacht)
    let base: Float

    static func load(_ folder: URL) -> ClipLevels? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("levels.csv"), encoding: .utf8)
        else { return nil }
        var rms: [Float] = []
        for line in text.split(separator: "\n").dropFirst() {
            let c = line.split(separator: ",", omittingEmptySubsequences: false)
            guard c.count >= 2 else { continue }
            rms.append(Float(c[1]) ?? -120)
        }
        guard !rms.isEmpty else { return nil }
        let sorted = rms.sorted()
        return ClipLevels(rms: rms, base: sorted[sorted.count / 5])
    }
}

/// Lautstärke-Linie des Ausschnitts, der beim Abspielen zu hören ist (2 s Vorlauf, höchstens 30 s):
/// senkrechte, abgerundete Striche um die Mittellinie, je lauter über dem Grundpegel, desto höher.
private struct MiniWaveform: View {
    let levels: ClipLevels
    let event: SoundEvent
    /// nur gesetzt, während dieser Ausschnitt läuft
    let player: NightClipPlayer?
    private let bars = 28

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: player == nil)) { _ in
            waveform(progress: player?.progress)
        }
        .accessibilityHidden(true)
    }

    private func waveform(progress: Double?) -> some View {
        Canvas { ctx, size in
            let from = max(0, Int(event.start) - 2)
            let to = min(levels.rms.count, from + min(Int(event.duration.rounded(.up)) + 4, 30))
            guard to > from else { return }
            let span = Double(to - from)
            let step = size.width / CGFloat(bars)
            for b in 0..<bars {
                // Sekunde zu diesem Strich (bei kurzen Ausschnitten weich dazwischen)
                let t = (Double(b) + 0.5) / Double(bars) * span - 0.5
                let i0 = max(0, min(to - from - 1, Int(t.rounded(.down))))
                let i1 = min(to - from - 1, i0 + 1)
                let f = Float(max(0, min(1, t - Double(i0))))
                let db = levels.rms[from + i0] * (1 - f) + levels.rms[from + i1] * f
                let v = CGFloat(min(1, max(0, (db - levels.base) / 30)))
                let h = max(3, v * size.height)
                let rect = CGRect(x: CGFloat(b) * step + step * 0.2, y: (size.height - h) / 2,
                                  width: step * 0.6, height: h)
                // schon gespielt: Mondweiß, noch nicht: Nebelgrau
                let played = progress.map { (Double(b) + 0.5) / Double(bars) <= $0 } ?? false
                ctx.fill(Path(roundedRect: rect, cornerRadius: step * 0.3),
                         with: .color(played ? Theme.moon : Theme.mist.opacity(progress == nil ? 0.8 : 0.45)))
            }
        }
    }
}

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
                if let levels { MiniSpectrogram(levels: levels, event: e) }
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

/// Pegel je Sekunde in drei Bändern (aus levels.csv) für die kleinen Klangbilder.
struct ClipLevels: Sendable {
    let low: [Float], mid: [Float], high: [Float]
    /// Grundpegel je Band (20-%-Quantil der Nacht)
    let base: (Float, Float, Float)

    static func load(_ folder: URL) -> ClipLevels? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("levels.csv"), encoding: .utf8)
        else { return nil }
        var low: [Float] = [], mid: [Float] = [], high: [Float] = []
        for line in text.split(separator: "\n").dropFirst() {
            let c = line.split(separator: ",", omittingEmptySubsequences: false)
            guard c.count >= 6 else { continue }
            low.append(Float(c[3]) ?? -120); mid.append(Float(c[4]) ?? -120); high.append(Float(c[5]) ?? -120)
        }
        guard !low.isEmpty else { return nil }
        func q(_ x: [Float]) -> Float { let s = x.sorted(); return s[s.count / 5] }
        return ClipLevels(low: low, mid: mid, high: high, base: (q(low), q(mid), q(high)))
    }
}

/// Kleines Klangbild des Ausschnitts, der beim Abspielen zu hören ist: oben hell, unten tief,
/// je Sekunde eine Spalte – je lauter über dem Grundpegel der Nacht, desto kräftiger.
private struct MiniSpectrogram: View {
    let levels: ClipLevels
    let event: SoundEvent

    var body: some View {
        Canvas { ctx, size in
            let from = max(0, Int(event.start) - 2)
            let to = min(levels.low.count, from + min(Int(event.duration.rounded(.up)) + 4, 30))
            guard to > from else { return }
            let n = to - from
            let w = size.width / CGFloat(n), h = size.height / 3
            let rows: [([Float], Float)] = [(levels.high, levels.base.2), (levels.mid, levels.base.1), (levels.low, levels.base.0)]
            for (r, (band, base)) in rows.enumerated() {
                for i in 0..<n {
                    let v = Double(min(1, max(0, (band[from + i] - base) / 30)))
                    let rect = CGRect(x: CGFloat(i) * w, y: CGFloat(r) * h, width: max(1, w - 0.5), height: h - 1)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1),
                             with: .color(Theme.accent.opacity(0.12 + 0.88 * v)))
                }
            }
        }
        .frame(width: 64, height: 20)
        .accessibilityHidden(true)
    }
}

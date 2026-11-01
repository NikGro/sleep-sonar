import SwiftUI

/// Schlafklänge – eigenes Suya-Mischpult statt Standardliste:
/// oben der runde Probehören-Knopf (das eine auffällige Element), darunter Klang-Kacheln:
/// antippen = an/aus, seitlich ziehen = Lautstärke (die Kachel füllt sich). Darunter die Nacht-Einstellungen.
struct SoundsView: View {
    @ObservedObject private var player = SleepSoundPlayer.shared
    @ObservedObject private var rec = PassiveNightEngine.shared
    private let timers = [0, 15, 30, 45, 60, 90, 120]
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    hero
                    VStack(alignment: .leading, spacing: 14) {
                        SectionTitle(tr("Klänge"))
                        Text(tr("Antippen zum Mischen, zur Seite ziehen für die Lautstärke."))
                            .font(.caption).foregroundStyle(Theme.mist)
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(SleepSound.allCases) { SoundTile(sound: $0, player: player) }
                        }
                    }
                    nightSection
                    Text(tr("Während der Nachtaufnahme rechnet Suya die Klänge aus dem Mikrofon heraus, damit sie die Messung kaum stören. Ganz verschwinden sie nicht, deshalb ist Ausblenden beim Einschlafen voreingestellt."))
                        .font(.caption).foregroundStyle(Theme.mist)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .nightBackground()
            .navigationTitle(tr("Klänge"))
            .toolbarTitleDisplayMode(.inlineLarge)
            .suyaTopEdge()
            .onAppear { player.preload(player.active) }
        }
    }

    // Runder Knopf: leuchtet, solange etwas spielt
    private var hero: some View {
        VStack(spacing: 14) {
            Button {
                Haptics.tap()
                player.togglePreview()
            } label: {
                ZStack {
                    Circle().fill(Theme.raised)
                    Circle().strokeBorder(player.isPlaying ? Theme.accent : Theme.hairline, lineWidth: 2)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(player.isPlaying ? Theme.accent : Theme.moon)
                        .offset(x: player.isPlaying ? 0 : 3)
                }
                .frame(width: 112, height: 112)
                .shadow(color: Theme.accent.opacity(player.isPlaying ? 0.45 : 0), radius: 28)
                .animation(.easeInOut(duration: 0.4), value: player.isPlaying)
            }
            .buttonStyle(.plain)
            .disabled(player.active.isEmpty)
            .accessibilityLabel(player.isPlaying ? tr("Anhalten") : tr("Probehören"))
            VStack(spacing: 4) {
                Text(player.active.isEmpty ? tr("Wähle unten einen Klang") : player.activeNames)
                    .font(Theme.display(19))
                    .multilineTextAlignment(.center)
                Text(rec.isRunning
                     ? tr("Die Klänge laufen gerade für die Nacht.")
                     : tr("Zum Ausprobieren. In der Nacht laufen die Klänge mit der Aufnahme und enden mit ihr."))
                    .font(.caption).foregroundStyle(Theme.mist)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var nightSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(tr("In der Nacht"))
            VStack(spacing: 0) {
                Toggle(tr("Mit der Nachtaufnahme starten"), isOn: $player.autoStart)
                    .tint(Theme.accent).padding(.vertical, 12)
                Divider().overlay(Theme.hairline)
                HStack {
                    Text(tr("Ausschalten nach"))
                    Spacer()
                    Picker(tr("Ausschalten nach"), selection: $player.timerMinutes) {
                        ForEach(timers, id: \.self) { m in
                            Text(m == 0 ? tr("Nie") : NightAnalysisView.hm(Double(m) * 60)).tag(m)
                        }
                    }
                    .labelsHidden()
                    .tint(Theme.accent)
                }
                .padding(.vertical, 6)
                Divider().overlay(Theme.hairline)
                Toggle(tr("Ausblenden, wenn du schläfst"), isOn: $player.stopOnSleep)
                    .tint(Theme.accent).padding(.vertical, 12)
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: 20).fill(Theme.raised))
            Text(tr("Was zuerst eintritt, blendet die Klänge über 30 Sekunden aus. Spätestens mit dem Ende der Aufnahme sind sie aus."))
                .font(.caption).foregroundStyle(Theme.mist)
        }
        .onChange(of: player.autoStart) { Haptics.select() }
        .onChange(of: player.stopOnSleep) { Haptics.select() }
    }
}

/// Kachel: antippen = Klang an/aus; seitlich ziehen = Lautstärke. Die Füllung von links zeigt die Lautstärke.
private struct SoundTile: View {
    let sound: SleepSound
    @ObservedObject var player: SleepSoundPlayer
    @State private var dragStart: Double?
    @State private var horizontal: Bool?

    var body: some View {
        let v = player.volumes[sound] ?? 0
        let on = v > 0.01
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 18).fill(Theme.raised)
                // Lautstärke als Füllung
                Rectangle().fill(Theme.accent.opacity(0.22))
                    .frame(width: g.size.width * v)
                VStack(spacing: 8) {
                    Image(systemName: sound.symbol)
                        .font(.system(size: 22))
                        .frame(height: 26)
                        .foregroundStyle(on ? Theme.accent : Theme.moon)
                    Text(sound.name)
                        .font(.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(on ? Theme.moon : Theme.mist)
                        .frame(height: 30, alignment: .top)
                    Text(on ? "\(Int((v * 100).rounded())) %" : " ")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
                .frame(maxWidth: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(on ? Theme.accent.opacity(0.7) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .onTapGesture {
                Haptics.select()
                player.volumes[sound] = on ? 0 : 0.6
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { d in
                        // nur waagerechtes Ziehen ändert die Lautstärke, senkrecht scrollt weiter
                        if horizontal == nil { horizontal = abs(d.translation.width) > abs(d.translation.height) }
                        guard horizontal == true else { return }
                        if dragStart == nil { dragStart = v; Haptics.select() }
                        let nv = min(1, max(0, (dragStart ?? v) + d.translation.width / g.size.width))
                        player.volumes[sound] = nv < 0.02 ? 0 : nv
                    }
                    .onEnded { _ in
                        if horizontal == true { Haptics.select() }
                        dragStart = nil; horizontal = nil
                    })
        }
        .frame(height: 108)
        .accessibilityElement()
        .accessibilityLabel(sound.name)
        .accessibilityValue(on ? "\(Int((v * 100).rounded())) %" : tr("aus"))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { player.volumes[sound] = on ? 0 : 0.6 }
        .accessibilityAdjustableAction { dir in
            let step = dir == .increment ? 0.1 : -0.1
            player.volumes[sound] = min(1, max(0, v + step))
        }
    }
}

/// Kurztext: was läuft und wann es endet.
enum SoundStatus {
    @MainActor static func text(_ p: SleepSoundPlayer) -> String {
        if p.fading { return tr("%@, wird ausgeblendet", p.activeNames) }
        var parts = [p.activeNames]
        if let at = p.stopsAt { parts.append(tr("aus um %@", at.formatted(date: .omitted, time: .shortened))) }
        if p.stopOnSleep { parts.append(tr("oder wenn du schläfst")) }
        return parts.joined(separator: ", ")
    }
}

/// Karte in „Heute Nacht“ während der Aufnahme.
struct SoundsCard: View {
    @ObservedObject private var player = SleepSoundPlayer.shared
    var body: some View {
        if player.isPlaying || !player.active.isEmpty {
            HStack(spacing: 14) {
                Image(systemName: player.active.first?.symbol ?? "waveform")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(player.isPlaying ? Theme.accent : Theme.hairline))
                    .foregroundStyle(player.isPlaying ? Theme.ink : Theme.moon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Klänge")).font(.callout.weight(.medium))
                    Text(player.isPlaying ? SoundStatus.text(player) : player.activeNames)
                        .font(.caption).foregroundStyle(Theme.mist)
                        .lineLimit(2, reservesSpace: true)   // feste Höhe: nichts springt beim Umschalten
                }
                Spacer()
                Button { Haptics.tap(); player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 36, height: 36)
                        .background(FadeRing(start: player.fadeStart, end: player.fadeEnd))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? tr("Anhalten") : tr("Abspielen"))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.raised))
            .transaction { $0.animation = nil }
        }
    }
}

/// Herkunft und Lizenzen der Naturklänge (Namensnennung für CC BY).
struct SoundCreditsView: View {
    var body: some View {
        List {
            Section {
                ForEach(SleepSound.allCases.filter { $0.credit != nil }) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name).foregroundStyle(Theme.moon)
                        Text(s.credit ?? "").font(.caption).foregroundStyle(Theme.mist)
                    }
                }
            } footer: {
                Text(tr("Gekürzt und als nahtlose Schleife bearbeitet, teils über das Projekt Blanket. Ventilator und Rauschen hat Suya selbst erzeugt."))
            }
            .listRowBackground(Theme.raised)
        }
        .nightBackground()
        .navigationTitle(tr("Quellen der Klänge"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Kreis um den Knopf, der sich während des Ausblendens füllt.
struct FadeRing: View {
    let start: Date?
    let end: Date?
    var body: some View {
        ZStack {
            Circle().strokeBorder(Theme.hairline, lineWidth: 1.5)
            if let start, let end {
                TimelineView(.animation) { tl in
                    let p = min(1, max(0, tl.date.timeIntervalSince(start) / end.timeIntervalSince(start)))
                    Circle().trim(from: 0, to: p)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(1.5)
                }
            }
        }
    }
}

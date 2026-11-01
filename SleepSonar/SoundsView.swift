import SwiftUI

/// Schlafklänge: eigene Mischung aus mehreren Klängen, Ausschalten nach Zeit oder beim Einschlafen.
struct SoundsView: View {
    @ObservedObject private var player = SleepSoundPlayer.shared
    @ObservedObject private var rec = PassiveNightEngine.shared
    @State private var naming = false
    @State private var mixName = ""
    private let timers = [0, 15, 30, 45, 60, 90, 120]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { Haptics.tap(); player.togglePreview() } label: {
                        Label(player.isPlaying ? tr("Anhalten") : tr("Probehören"),
                              systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(MoonButtonStyle(prominent: !player.isPlaying))
                    .disabled(player.active.isEmpty)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text(rec.isRunning
                         ? tr("Die Klänge laufen gerade für die Nacht.")
                         : tr("Zum Ausprobieren. In der Nacht laufen die Klänge mit der Aufnahme und enden mit ihr."))
                }

                Section {
                    ForEach(SleepSound.allCases) { s in SoundRow(sound: s, player: player) }
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.fill").foregroundStyle(Theme.mist)
                        Slider(value: $player.master, in: 0...1).tint(Theme.accent)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(Theme.mist)
                    }
                    .accessibilityLabel(tr("Gesamtlautstärke"))
                } header: {
                    ListHeader(tr("Mischen"))
                } footer: {
                    Text(tr("Tippe auf einen Klang, um ihn dazuzunehmen, und stelle seine Lautstärke ein."))
                }
                .listRowBackground(Theme.raised)

                Section {
                    Toggle(tr("Mit der Nachtaufnahme starten"), isOn: $player.autoStart).tint(Theme.accent)
                    Picker(tr("Ausschalten nach"), selection: $player.timerMinutes) {
                        ForEach(timers, id: \.self) { m in
                            Text(m == 0 ? tr("Nie") : NightAnalysisView.hm(Double(m) * 60)).tag(m)
                        }
                    }
                    Toggle(tr("Ausblenden, wenn du schläfst"), isOn: $player.stopOnSleep).tint(Theme.accent)
                } header: {
                    ListHeader(tr("In der Nacht"))
                } footer: {
                    Text(tr("Was zuerst eintritt, blendet die Klänge über 15 Sekunden aus. Spätestens mit dem Ende der Aufnahme sind sie aus."))
                }
                .listRowBackground(Theme.raised)

                Section {
                    ForEach(player.mixes) { mix in
                        let current = player.volumes == mix.volumes
                        Button {
                            Haptics.select()
                            player.load(mix)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mix.name).foregroundStyle(Theme.moon)
                                    Text(SleepSound.allCases.filter { (mix.volumes[$0] ?? 0) > 0.01 }.map(\.name)
                                            .joined(separator: " + "))
                                        .font(.caption).foregroundStyle(Theme.mist)
                                }
                                Spacer()
                                // eingestellte Mischung sichtbar markieren
                                if current {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .contentShape(Rectangle())
                            .animation(.snappy, value: current)
                        }
                        .accessibilityAddTraits(current ? .isSelected : [])
                    }
                    .onDelete(perform: player.deleteMixes)
                    Button(tr("Aktuelle Mischung sichern …")) { mixName = ""; naming = true }
                        .foregroundStyle(Theme.moon)
                        .disabled(player.active.isEmpty)
                } header: {
                    ListHeader(tr("Eigene Mischungen"))
                }
                .listRowBackground(Theme.raised)

                Section {} footer: {
                    Text(tr("Während der Nachtaufnahme rechnet Suya die Klänge aus dem Mikrofon heraus, damit sie die Messung kaum stören. Ganz verschwinden sie nicht, deshalb ist Ausblenden beim Einschlafen voreingestellt."))
                }
            }
            .nightBackground()
            .navigationTitle(tr("Klänge"))
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbarBackground(Theme.ink, for: .navigationBar)
            .alert(tr("Mischung sichern"), isPresented: $naming) {
                TextField(tr("Name"), text: $mixName)
                Button(tr("Abbrechen"), role: .cancel) {}
                Button(tr("Sichern")) { player.saveMix(named: mixName); Haptics.success() }
            }
        }
    }
}

/// Ein Klang: antippen = an/aus, Regler = Lautstärke.
private struct SoundRow: View {
    let sound: SleepSound
    @ObservedObject var player: SleepSoundPlayer

    private var value: Binding<Double> {
        Binding(get: { player.volumes[sound] ?? 0 }, set: { player.volumes[sound] = $0 })
    }

    var body: some View {
        let on = (player.volumes[sound] ?? 0) > 0.01
        HStack(spacing: 12) {
            // kein Button in der Zeile: sonst fängt die Liste die erste Berührung ab und der Regler
            // reagiert erst beim zweiten Mal
            Image(systemName: sound.symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 34)
                .background(Circle().fill(on ? Theme.accent : Theme.hairline))
                .foregroundStyle(on ? Theme.ink : Theme.moon)
                .contentShape(Circle())
                .onTapGesture {
                    Haptics.select()
                    player.volumes[sound] = on ? 0 : 0.6
                }
                .accessibilityElement()
                .accessibilityLabel(sound.name)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { player.volumes[sound] = on ? 0 : 0.6 }
            VStack(alignment: .leading, spacing: 2) {
                Text(sound.name).font(.callout).foregroundStyle(on ? Theme.moon : Theme.mist)
                Slider(value: value, in: 0...1).tint(Theme.accent)
                    .accessibilityLabel(tr("Lautstärke %@", sound.name))
            }
        }
        .padding(.vertical, 2)
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
                        .lineLimit(2)
                }
                Spacer()
                Button { Haptics.tap(); player.toggle() } label: {
                    Image(systemName: player.isPlaying && !player.fading ? "pause.fill" : "play.fill")
                        .frame(width: 36, height: 36)
                        .background(FadeRing(start: player.fadeStart, end: player.fadeEnd))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? tr("Anhalten") : tr("Abspielen"))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.raised))
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

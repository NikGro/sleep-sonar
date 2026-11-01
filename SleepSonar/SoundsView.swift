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
                    Button { player.toggle() } label: {
                        Label(player.isPlaying ? tr("Anhalten") : tr("Abspielen"),
                              systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(MoonButtonStyle(prominent: !player.isPlaying))
                    .disabled(player.active.isEmpty)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    if player.isPlaying {
                        Text(SoundStatus.text(player))
                            .font(.callout).foregroundStyle(Theme.mist)
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                    }
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
                    Picker(tr("Ausschalten nach"), selection: $player.timerMinutes) {
                        ForEach(timers, id: \.self) { m in
                            Text(m == 0 ? tr("Nie") : NightAnalysisView.hm(Double(m) * 60)).tag(m)
                        }
                    }
                    Toggle(tr("Ausblenden, wenn du schläfst"), isOn: $player.stopOnSleep).tint(Theme.accent)
                } header: {
                    ListHeader(tr("Ausschalten"))
                } footer: {
                    Text(rec.isRunning || !player.stopOnSleep
                         ? tr("Was zuerst eintritt, blendet die Klänge über 30 Sekunden aus.")
                         : tr("Ob du schläfst, erkennt Suya nur, während die Nachtaufnahme läuft."))
                }
                .listRowBackground(Theme.raised)

                Section {
                    ForEach(player.mixes) { mix in
                        Button {
                            player.load(mix)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mix.name).foregroundStyle(Theme.moon)
                                Text(SleepSound.allCases.filter { (mix.volumes[$0] ?? 0) > 0.01 }.map(\.name)
                                        .joined(separator: " + "))
                                    .font(.caption).foregroundStyle(Theme.mist)
                            }
                        }
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
                Button(tr("Sichern")) { player.saveMix(named: mixName) }
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
            Button {
                player.volumes[sound] = on ? 0 : 0.6
            } label: {
                Image(systemName: sound.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(on ? Theme.accent : Theme.hairline))
                    .foregroundStyle(on ? Theme.ink : Theme.moon)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sound.name)
            .accessibilityAddTraits(on ? .isSelected : [])
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
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 36, height: 36)
                        .background(Circle().strokeBorder(Theme.hairline))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? tr("Anhalten") : tr("Abspielen"))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.raised))
        }
    }
}

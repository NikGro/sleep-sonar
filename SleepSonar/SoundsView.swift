import SwiftUI

/// Schlafklänge – eigenes Suya-Mischpult statt Standardliste:
/// oben der runde Probehören-Knopf (das eine auffällige Element), darunter Klang-Kacheln:
/// antippen = an/aus, seitlich ziehen = Lautstärke (die Kachel füllt sich). Darunter die Nacht-Einstellungen.
struct SoundsView: View {
    @ObservedObject private var player = SleepSoundPlayer.shared
    @ObservedObject private var rec = PassiveNightEngine.shared
    private let timers = [0, 15, 30, 45, 60, 90, 120]
    @State private var pressed = false
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
            // Reagiert schon beim Berühren (nicht erst beim Loslassen): In einer Scroll-Ansicht hält iOS
            // Berührungen sonst kurz zurück, das wirkte verzögert. Das Leuchten blendet weich, der Rest sofort.
            ZStack {
                Circle().fill(RadialGradient(colors: [Theme.accent.opacity(0.35), .clear],
                                             center: .center, startRadius: 50, endRadius: 86))
                    .frame(width: 172, height: 172)
                    .opacity(player.isPlaying ? 1 : 0)
                    .animation(.easeInOut(duration: 0.7), value: player.isPlaying)
                // Ring und Symbol wechseln sofort (eigene Transaktion ohne Animation). Vorher hat die
                // Eindrück-Animation sie mitgenommen: Symbol und Ring glitten 0,2 s und wirkten verzögert.
                Group {
                    Circle().fill(Theme.raised).frame(width: 112, height: 112)
                    Circle().strokeBorder(player.isPlaying ? Theme.accent : Theme.hairline, lineWidth: 2)
                        .frame(width: 112, height: 112)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(player.isPlaying ? Theme.accent : Theme.moon)
                        .offset(x: player.isPlaying ? 0 : 3)
                }
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
            }
            .frame(width: 112, height: 112)
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(.spring(duration: 0.18), value: pressed)
            .overlay {
                // Beschriftung entlang der Rundung: macht klar, dass dies nur zum Ausprobieren ist
                CurvedText(text: player.isPlaying ? tr("Probe läuft") : tr("Probehören"), radius: 70, size: 15)
                    .foregroundStyle(player.isPlaying ? Theme.accent : Theme.mist)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .contentShape(Circle())
            // UIKit-Berührung ohne Wartezeit: Die Scroll-Ansicht hält Berührungen sonst ~150 ms zurück,
            // um zu prüfen, ob gescrollt wird – genau diese Zeit wirkte wie Verzögerung.
            .gesture(TouchDown {
                guard !player.active.isEmpty else { return }
                pressed = true
                Haptics.tap()
                player.togglePreview()
            } onUp: {
                pressed = false
            })
            .padding(.top, 24)
            .opacity(player.active.isEmpty ? 0.5 : 1)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { player.togglePreview() }
            .accessibilityLabel(player.isPlaying ? tr("Anhalten") : tr("Probehören"))
            VStack(spacing: 4) {
                Text(player.active.isEmpty ? tr("Wähle unten einen Klang") : player.activeNames)
                    .font(Theme.display(19))
                    .multilineTextAlignment(.center)
                Text(rec.isRunning
                     ? tr("Die Klänge laufen gerade für die Nacht.")
                     : tr("Hier nur zum Probehören. Für die Nacht startest du die Klänge mit der Aufnahme unter „Heute Nacht“ – sie helfen beim Einschlafen und enden mit der Aufnahme."))
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
/// Das Ziehen beginnt nur bei waagerechter Bewegung, senkrecht scrollt die Seite ganz normal.
private struct SoundTile: View {
    let sound: SleepSound
    @ObservedObject var player: SleepSoundPlayer
    @State private var dragStart: Double?

    var body: some View {
        let v = player.volumes[sound] ?? 0
        let on = v > 0.01
        VStack(spacing: 6) {
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
            if on {
                Text("\(Int((v * 100).rounded())) %")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 108)
        .background(alignment: .leading) {
            ZStack(alignment: .leading) {
                Theme.raised
                GeometryReader { g in Theme.accent.opacity(0.22).frame(width: g.size.width * v) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(on ? Theme.accent.opacity(0.7) : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture {
            Haptics.select()
            player.volumes[sound] = on ? 0 : 0.6
        }
        .gesture(HorizontalPan { dx, width in
            if dragStart == nil { dragStart = max(v, 0.05); Haptics.select() }
            // beim Ziehen nie ganz aus: ausschalten nur per Tippen
            player.volumes[sound] = min(1, max(0.05, (dragStart ?? v) + dx / max(width, 1)))
        } onEnd: {
            if dragStart != nil { Haptics.select() }
            dragStart = nil
        })
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

/// Waagerechtes Ziehen (UIKit), das senkrechtes Scrollen nicht blockiert.
struct HorizontalPan: UIGestureRecognizerRepresentable {
    var onChange: (_ dx: CGFloat, _ width: CGFloat) -> Void
    var onEnd: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let g = UIPanGestureRecognizer()
        g.delegate = context.coordinator
        return g
    }

    func handleUIGestureRecognizerAction(_ g: UIPanGestureRecognizer, context: Context) {
        switch g.state {
        case .began, .changed: onChange(g.translation(in: g.view).x, g.view?.bounds.width ?? 1)
        case .ended, .cancelled, .failed: onEnd()
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let p = g as? UIPanGestureRecognizer else { return true }
            let v = p.velocity(in: p.view)
            return abs(v.x) > abs(v.y) * 1.2
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
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    Haptics.tap()
                    // ohne Animation: sonst gleitet der Knopf der neuen Kartenhöhe hinterher
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { player.toggle() }
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 36, height: 36)
                        .background(FadeRing(start: player.fadeStart, end: player.fadeEnd))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? tr("Anhalten") : tr("Abspielen"))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.raised))
            .transaction { $0.disablesAnimations = true; $0.animation = nil }
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

/// Text entlang des oberen Kreisbogens (Zeichen einzeln gedreht).
struct CurvedText: View {
    let text: String
    let radius: CGFloat
    let size: CGFloat

    var body: some View {
        let chars = Array(text)
        let step = size * 0.56 / radius             // ungefähre Zeichenbreite als Winkel
        let total = step * CGFloat(max(chars.count - 1, 0))
        ZStack {
            ForEach(Array(chars.enumerated()), id: \.offset) { i, c in
                let angle = -total / 2 + step * CGFloat(i)          // 0 = oben
                Text(String(c))
                    .font(Theme.display(size, weight: .medium))
                    .rotationEffect(.radians(angle))
                    .offset(x: radius * sin(angle), y: -radius * cos(angle))
            }
        }
    }
}

/// Meldet das Aufsetzen des Fingers sofort (UILongPress mit Dauer 0, ohne Berührungsverzögerung).
struct TouchDown: UIGestureRecognizerRepresentable {
    var onDown: () -> Void
    var onUp: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let g = UILongPressGestureRecognizer()
        g.minimumPressDuration = 0
        g.allowableMovement = 30
        g.delaysTouchesBegan = false
        g.cancelsTouchesInView = false
        g.delegate = context.coordinator
        return g
    }

    func handleUIGestureRecognizerAction(_ g: UILongPressGestureRecognizer, context: Context) {
        switch g.state {
        case .began: onDown()
        case .ended, .cancelled, .failed: onUp()
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

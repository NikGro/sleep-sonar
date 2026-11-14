import SwiftUI

/// Startbildschirm: vor dem Schlafen starten, während der Nacht die Atemlinie sehen.
struct TonightView: View {
    @ObservedObject private var rec = PassiveNightEngine.shared
    @State private var confirmStop = false
    @State private var showDetails = false
    @Environment(\.verticalSizeClass) private var verticalSize

    /// iPhone quer (z. B. im Dock) während der Aufnahme: alles auf einen Blick, ohne Leisten und ohne Scrollen
    private var landscape: Bool { verticalSize == .compact && rec.isRunning }

    var body: some View {
        NavigationStack {
            if landscape {
                landscapeRunning
                    .nightBackground()
                    .toolbar(.hidden, for: .navigationBar)
                    .toolbar(.hidden, for: .tabBar)
                    .persistentSystemOverlays(.hidden)
            } else {
                portrait
            }
        }
        .alert(tr("Aufnahme zu kurz"), isPresented: $rec.tooShort) {
            Button(tr("OK"), role: .cancel) {}
        } message: {
            Text(tr("Für eine Auswertung braucht Suya mindestens etwa elf Minuten. Diese Aufnahme wurde nicht gespeichert."))
        }
    }

    private var portrait: some View {
        GeometryReader { g in
            ScrollView {
                VStack(spacing: 28) {
                    if rec.isRunning { running } else { ready }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, rec.isRunning ? 12 : 16)
                .padding(.bottom, rec.isRunning ? 28 : 0)
                // vor dem Start: mittig zwischen Titel und Tab-Leiste
                .frame(maxWidth: .infinity, minHeight: rec.isRunning ? nil : g.size.height)
            }
        }
        // vor dem Start passt alles auf den Bildschirm: nicht federn (Titel bleibt groß)
        .scrollDisabled(!rec.isRunning)
        .nightBackground()
        .navigationTitle(tr("Heute Nacht"))
        .toolbarTitleDisplayMode(.inlineLarge)   // großer Titel in einer Zeile mit den Knöpfen
        .suyaTopEdge()
    }

    // MARK: Während der Nacht, quer

    private var landscapeRunning: some View {
        VStack(spacing: 12) {
            clock(top: 0, size: 40)
            breath(height: 60)
            SoundsCard()
            stopButton
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Vor dem Schlafen

    private var ready: some View {
        VStack(spacing: 28) {
            MoonDisc(lit: true)
                .frame(width: 140, height: 140)
                .padding(.top, 8)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(tr("Leg dein iPhone neben das Bett"))
                    .font(Theme.display(26))
                    .multilineTextAlignment(.center)
                Text(tr("Suya hört deine Atmung und Bewegungen und schätzt daraus deine Schlafphasen. Die Aufnahme bleibt auf deinem iPhone."))
                    .font(.callout)
                    .foregroundStyle(Theme.mist)
                    .multilineTextAlignment(.center)
            }

            Button {
                Haptics.tap()
                Task { await rec.start(); if rec.isRunning { Haptics.success() } }
            } label: {
                Text(tr("Aufnahme starten"))
            }
            .buttonStyle(MoonButtonStyle())

            if let e = rec.errorMessage {
                Text(e).font(.callout).foregroundStyle(Theme.alert).multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 14) {
                Checklist(symbol: "bolt", text: tr("Ans Ladekabel, Mikrofon (Unterseite) zeigt zu dir."))
                Checklist(symbol: "applewatch", text: tr("Mit Apple Watch kannst du die Schätzung morgens vergleichen."))
                Checklist(symbol: "lock", text: tr("Bildschirm sperren ist okay. Die App nur nicht wegwischen."))
            }
            .padding(.top, 8)
        }
    }

    // MARK: Während der Nacht

    private var running: some View {
        VStack(spacing: 28) {
            clock(top: 32, size: 56)

            breath(height: 120)

            SoundsCard()

            stopButton

            DisclosureGroup(isExpanded: $showDetails) {
                VStack(spacing: 10) {
                    LiveDetails()
                    TonightDetail(key: tr("Mikrofon"), value: rec.inputName)
                    TonightDetail(key: tr("Neustarts"), value: "\(rec.restarts)")
                    ForEach(rec.events, id: \.self) {
                        Text($0).font(.caption.monospaced()).foregroundStyle(Theme.mist)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 10)
            } label: {
                Text(tr("Technische Details")).font(.callout).foregroundStyle(Theme.mist)
            }
        }
    }

    @ViewBuilder private func clock(top: CGFloat, size: CGFloat) -> some View {
        if let start = rec.startDate {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(spacing: 4) {
                    Text(Self.clock(ctx.date.timeIntervalSince(start)))
                        .font(Theme.display(size, weight: .light).monospacedDigit())
                    Text(tr("seit %@ Uhr", start.formatted(date: .omitted, time: .shortened)))
                        .font(.callout)
                        .foregroundStyle(Theme.mist)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, top)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func breath(height: CGFloat) -> some View {
        LiveBreath(height: height, restarts: rec.restarts)
    }

    private var stopButton: some View {
        // Hervorgehoben in Mondweiß; erstes Tippen färbt ihn rot mit „Wirklich beenden?“,
        // zweites Tippen beendet. Ohne zweites Tippen kehrt er nach 4 s zurück.
        Button {
            if confirmStop {
                rec.stop()
                Haptics.warning()
                confirmStop = false
            } else {
                Haptics.tap()
                confirmStop = true
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    confirmStop = false
                }
            }
        } label: {
            Text(confirmStop ? tr("Wirklich beenden?") : tr("Aufnahme beenden"))
        }
        .buttonStyle(StopButtonStyle(confirming: confirmStop))
        .animation(.snappy(duration: 0.2), value: confirmStop)
    }


    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

private struct TonightDetail: View {
    let key: String
    let value: String
    var body: some View {
        HStack {
            Text(key).foregroundStyle(Theme.mist)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}

/// Atemlinie mit Zustand – beobachtet als Einzige die schnellen Pegel, damit nur sie neu gezeichnet wird
private struct LiveBreath: View {
    @ObservedObject private var live = LiveLevels.shared
    let height: CGFloat
    let restarts: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BreathLine(values: live.recentBreath)
                .frame(height: height)
                .accessibilityLabel(tr("Atemlinie der letzten 30 Sekunden"))
            HStack {
                Text(tr("Letzte 30 Sekunden"))
                Spacer()
                Text(status)
            }
            .font(.caption)
            .foregroundStyle(Theme.mist)
        }
    }

    private var status: String {
        if live.motionActivity > MotionLogger.handledThreshold { return tr("iPhone wird bewegt") }
        if restarts > 0 { return tr("hört zu, %d× neu gestartet", restarts) }
        return tr("hört zu")
    }
}

private struct LiveDetails: View {
    @ObservedObject private var live = LiveLevels.shared
    var body: some View {
        TonightDetail(key: tr("Pegel"), value: String(format: "%.0f dBFS", live.levelDB))
        TonightDetail(key: tr("Tief / Mitte / Hoch"), value: live.bandDB.map { String(format: "%.0f", $0) }.joined(separator: " / "))
        TonightDetail(key: tr("iPhone bewegt"), value: String(format: "%.3f g", live.motionActivity))
    }
}

private struct Checklist: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(Theme.mist)
            Text(text).font(.callout)
        }
    }
}

/// Mond als ruhiges Zeichen der App.
struct MoonDisc: View {
    var lit: Bool
    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Theme.moon, Theme.moon.opacity(0.82)],
                                     center: UnitPoint(x: 0.38, y: 0.35), startRadius: 4, endRadius: 120))
                .shadow(color: Theme.moon.opacity(lit ? 0.35 : 0), radius: 40)
            // Schatten macht daraus eine Sichel (Versatz relativ zur Größe, passt bei jeder Größe)
            GeometryReader { g in
                Circle()
                    .fill(Theme.ink)
                    .scaleEffect(0.92)
                    .offset(x: g.size.width * 0.21, y: -g.size.height * 0.122)
            }
        }
        .compositingGroup()
    }
}

/// Atemlinie: Hochton-Pegel (Atemrauschen) der letzten 30 Sekunden als weiche Linie.
/// Werte kommen 10× pro Sekunde; gezeichnet wird mit Bildschirmfrequenz und fließend verschoben.
struct BreathLine: View {
    struct Sample: Equatable { var t: TimeInterval; var v: Double }
    static let window: TimeInterval = 30
    /// Anzeige leicht verzögert, damit neue Werte sicher da sind (Audio kommt in Paketen)
    static let delay: TimeInterval = 0.3
    let values: [Sample]

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                draw(ctx, size, now: tl.date.timeIntervalSinceReferenceDate - Self.delay)
            }
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, now: TimeInterval) {
        var base = Path()
        base.move(to: CGPoint(x: 0, y: size.height - 0.5))
        base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
        ctx.stroke(base, with: .color(Theme.hairline), lineWidth: 1)

        // sichtbarer Ausschnitt (+ je ein Punkt Rand), leicht geglättet (±0,2 s)
        let raw = values.filter { $0.t >= now - Self.window - 0.5 && $0.t <= now + 0.5 }
        guard raw.count > 1 else { return }
        let pts: [Sample] = raw.indices.map { i in
            let a = max(0, i - 2), b = min(raw.count - 1, i + 2)
            return Sample(t: raw[i].t, v: raw[a...b].reduce(0) { $0 + $1.v } / Double(b - a + 1))
        }
        let lo = pts.map(\.v).min() ?? 0, hi = pts.map(\.v).max() ?? 1
        let span = max(hi - lo, 6)  // mind. 6 dB, damit Stille nicht wie Sturm aussieht
        func point(_ s: Sample) -> CGPoint {
            CGPoint(x: size.width * CGFloat(1 - (now - s.t) / Self.window),
                    y: size.height * (0.9 - 0.8 * CGFloat((s.v - lo) / span)))
        }
        var line = Path()
        line.move(to: point(pts[0]))
        for i in 1..<pts.count {
            let p0 = point(pts[i - 1]), p1 = point(pts[i])
            line.addQuadCurve(to: CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2), control: p0)
            if i == pts.count - 1 { line.addLine(to: p1) }
        }
        var clipped = ctx
        clipped.clip(to: Path(CGRect(origin: .zero, size: size)))
        var fill = line
        fill.addLine(to: CGPoint(x: point(pts[pts.count - 1]).x, y: size.height))
        fill.addLine(to: CGPoint(x: point(pts[0]).x, y: size.height))
        fill.closeSubpath()
        clipped.fill(fill, with: .linearGradient(Gradient(colors: [Theme.moon.opacity(0.18), .clear]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        clipped.stroke(line, with: .color(Theme.moon), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

        // Punkt am rechten Rand: Wert zur Anzeigezeit, zwischen zwei Messwerten interpoliert
        let v: Double
        if let j = pts.firstIndex(where: { $0.t >= now }), j > 0 {
            let a = pts[j - 1], b = pts[j]
            v = a.v + (b.v - a.v) * (now - a.t) / max(b.t - a.t, 1e-6)
        } else {
            v = pts[pts.count - 1].v
        }
        let dot = CGPoint(x: min(size.width, point(pts[pts.count - 1]).x), y: point(Sample(t: now, v: v)).y)
        ctx.fill(Path(ellipseIn: CGRect(x: dot.x - 4, y: dot.y - 4, width: 8, height: 8)), with: .color(Theme.moon))
    }
}

/// Beenden-Knopf: ausgefüllt in Mondweiß, beim Nachfragen in Korallrot.
private struct StopButtonStyle: ButtonStyle {
    let confirming: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .foregroundStyle(Theme.ink)
            .background(Capsule().fill(confirming ? Theme.alert : Theme.moon))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

import SwiftUI

/// Startbildschirm: vor dem Schlafen starten, während der Nacht die Atemlinie sehen.
struct TonightView: View {
    @ObservedObject private var rec = PassiveNightEngine.shared
    @State private var confirmStop = false
    @State private var showDetails = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    if rec.isRunning { running } else { ready }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .nightBackground()
            .navigationTitle("Heute Nacht")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Theme.ink, for: .navigationBar)
        }
    }

    // MARK: Vor dem Schlafen

    private var ready: some View {
        VStack(spacing: 28) {
            MoonDisc(lit: true)
                .frame(width: 140, height: 140)
                .padding(.top, 8)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Leg dein iPhone neben das Bett")
                    .font(Theme.display(26))
                    .multilineTextAlignment(.center)
                Text("Somnivo hört deine Atmung und Bewegungen und schätzt daraus deine Schlafphasen. "
                     + "Die Aufnahme bleibt auf deinem iPhone.")
                    .font(.callout)
                    .foregroundStyle(Theme.mist)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await rec.start() }
            } label: {
                Text("Aufnahme starten")
            }
            .buttonStyle(MoonButtonStyle())

            if let e = rec.errorMessage {
                Text(e).font(.callout).foregroundStyle(Theme.alert).multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 14) {
                Checklist(symbol: "bolt", text: "Ans Ladekabel, Mikrofon (Unterseite) zeigt zu dir.")
                Checklist(symbol: "applewatch", text: "Mit Apple Watch kannst du die Schätzung morgens vergleichen.")
                Checklist(symbol: "lock", text: "Bildschirm sperren ist okay. Die App nur nicht wegwischen.")
            }
            .padding(.top, 8)
        }
    }

    // MARK: Während der Nacht

    private var running: some View {
        VStack(spacing: 28) {
            if let start = rec.startDate {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(spacing: 4) {
                        Text(Self.clock(ctx.date.timeIntervalSince(start)))
                            .font(Theme.display(56, weight: .light).monospacedDigit())
                        Text("seit \(start.formatted(date: .omitted, time: .shortened)) Uhr")
                            .font(.callout)
                            .foregroundStyle(Theme.mist)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
                    .accessibilityElement(children: .combine)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                BreathLine(values: rec.recentBreath)
                    .frame(height: 120)
                    .accessibilityLabel("Atemlinie der letzten 30 Sekunden")
                HStack {
                    Text("Letzte 30 Sekunden")
                    Spacer()
                    Text(Self.statusText(rec))
                }
                .font(.caption)
                .foregroundStyle(Theme.mist)
            }

            Button {
                confirmStop = true
            } label: {
                Text("Aufnahme beenden")
            }
            .buttonStyle(MoonButtonStyle(prominent: false))
            // iOS 26 zeigt die Rückfrage als Sprechblase: verankert an einem unsichtbaren Punkt
            // knapp über dem Knopf, damit sie ihn nicht berührt
            .background(alignment: .top) {
                Color.clear
                    .frame(height: 1)
                    .offset(y: -10)
                    .confirmationDialog("Aufnahme beenden?", isPresented: $confirmStop, titleVisibility: .visible) {
                        Button("Aufnahme beenden", role: .destructive) { rec.stop() }
                    } message: {
                        Text("Die Nacht wird gespeichert und lässt sich danach auswerten.")
                    }
            }

            DisclosureGroup(isExpanded: $showDetails) {
                VStack(spacing: 10) {
                    detail("Pegel", String(format: "%.0f dBFS", rec.levelDB))
                    detail("Tief / Mitte / Hoch", rec.bandDB.map { String(format: "%.0f", $0) }.joined(separator: " / "))
                    detail("Mikrofon", rec.inputName)
                    detail("iPhone bewegt", String(format: "%.3f g", rec.motionActivity))
                    detail("Neustarts", "\(rec.restarts)")
                    ForEach(rec.events, id: \.self) {
                        Text($0).font(.caption.monospaced()).foregroundStyle(Theme.mist)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 10)
            } label: {
                Text("Technische Details").font(.callout).foregroundStyle(Theme.mist)
            }
        }
    }

    private func detail(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(Theme.mist)
            Spacer()
            Text(v).monospacedDigit()
        }
        .font(.callout)
    }

    private static func statusText(_ rec: PassiveNightEngine) -> String {
        if rec.motionActivity > MotionLogger.handledThreshold { return "iPhone wird bewegt" }
        if rec.restarts > 0 { return "hört zu, \(rec.restarts)× neu gestartet" }
        return "hört zu"
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 3600, (s / 60) % 60)
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
            // Schatten macht daraus eine Sichel
            Circle()
                .fill(Theme.ink)
                .scaleEffect(0.92)
                .offset(x: 38, y: -22)
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

import Charts
import SonarDSP
import SwiftUI

struct SonarTestView: View {
    @StateObject private var sonar = SonarEngine()
    @AppStorage("sonar.carrier") private var carrier = 20_000.0
    @AppStorage("sonar.volume") private var volume = 0.5

    private let carriers: [Double] = [18_500, 19_500, 20_000, 21_000]

    var body: some View {
        NavigationStack {
            List {
                if !sonar.isRunning && sonar.reading == nil {
                    Section("So geht's") {
                        Label("iPhone 30–100 cm neben dich legen, Unterseite (Lautsprecher) zu dir.",
                              systemImage: "iphone.gen3")
                        Label("Lautstärke etwa 70 %. Der Ton ist für die meisten Erwachsenen unhörbar.",
                              systemImage: "speaker.wave.2")
                        Label("Haustiere können 18–21 kHz hören.", systemImage: "pawprint")
                        Label("Ruhig liegen und normal atmen. Nach ca. 10 s kommen die ersten Werte.",
                              systemImage: "lungs")
                    }
                }

                Section {
                    Picker("Frequenz", selection: $carrier) {
                        ForEach(carriers, id: \.self) { f in
                            Text(String(format: "%.1f kHz", f / 1000)).tag(f)
                        }
                    }
                    .disabled(sonar.isRunning)
                    VStack(alignment: .leading) {
                        Text("Sendepegel \(Int(volume * 100)) %")
                        Slider(value: $volume, in: 0.05...1)
                            .onChange(of: volume) { _, v in sonar.setVolume(Float(v)) }
                    }
                    Button {
                        Task {
                            if sonar.isRunning { sonar.stop() }
                            else { await sonar.start(carrierHz: carrier, volume: Float(volume)) }
                        }
                    } label: {
                        Label(sonar.isRunning ? "Stoppen" : "Live-Test starten",
                              systemImage: sonar.isRunning ? "stop.circle.fill" : "waveform.circle.fill")
                            .font(.headline)
                    }
                    if let e = sonar.errorMessage {
                        Text(e).foregroundStyle(.red).font(.callout)
                    }
                }

                if let r = sonar.reading {
                    Section {
                        StatusRow(status: r.status, quiet: r.quietSeconds)
                    }
                    Section("Atemkurve (letzte 30 s)") {
                        WaveformChart(values: r.waveform)
                            .frame(height: 160)
                    }
                    Section("Werte") {
                        ValueRow(title: "Atmung",
                                 value: r.breathsPerMinute.map { String(format: "%.1f /min", $0) },
                                 detail: String(format: "Sicherheit %.0f %%", r.breathConfidence * 100),
                                 reliable: r.isBreathReliable)
                        ValueRow(title: "Atemhub",
                                 value: r.breathAmplitudeMM.map { String(format: "%.1f mm", $0) },
                                 detail: "Brustkorb-Bewegung, Spitze zu Spitze",
                                 reliable: r.isBreathReliable)
                        MovementRow(mmPerSecond: r.movementMMPerSecond)
                        ValueRow(title: "Puls (experimentell)",
                                 value: r.heartBPM.map { String(format: "%.0f /min", $0) },
                                 detail: String(format: "Eindeutigkeit %.1f – zum Vergleich am Handgelenk zählen",
                                                r.heartConfidence),
                                 reliable: r.isHeartReliable)
                    }
                    Section("Signal") {
                        LabeledContent("Empfangspegel", value: String(format: "%.0f dBFS", r.levelDB))
                        LabeledContent("Körperecho / Rauschen", value: String(format: "%.1f", r.snr))
                        LabeledContent("Abtastrate", value: "\(Int(sonar.sampleRate)) Hz")
                    }
                    .font(.callout)
                }
            }
            .navigationTitle("Sonar-Test")
            .onDisappear { sonar.stop() }
        }
    }
}

private struct StatusRow: View {
    let status: SonarReading.Status
    let quiet: Double

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(color)
            VStack(alignment: .leading) {
                Text(title).font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var icon: String {
        switch status {
        case .warmingUp: "hourglass"
        case .noEcho: "wifi.exclamationmark"
        case .moving: "figure.walk.motion"
        case .collecting: "waveform.path"
        case .ok: "checkmark.circle.fill"
        }
    }
    private var color: Color {
        switch status {
        case .ok: .green
        case .moving: .orange
        case .noEcho: .red
        default: .secondary
        }
    }
    private var title: String {
        switch status {
        case .warmingUp: "Sammle Daten …"
        case .noEcho: "Kein Körperecho"
        case .moving: "Bewegung erkannt"
        case .collecting: "Ruhig – werte aus …"
        case .ok: "Atmung erkannt"
        }
    }
    private var subtitle: String {
        switch status {
        case .warmingUp: "Die ersten 8 Sekunden"
        case .noEcho: "Näher rangehen, Lautstärke erhöhen oder andere Frequenz probieren"
        case .moving: "Atemwerte kommen nach 10 s Ruhe wieder"
        case .collecting: String(format: "%.0f s ruhig", quiet)
        case .ok: String(format: "%.0f s ruhig", quiet)
        }
    }
}

private struct ValueRow: View {
    let title: String
    let value: String?
    let detail: String
    let reliable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(value ?? "–")
                    .font(.title3.monospacedDigit().bold())
                    .foregroundStyle(reliable && value != nil ? .primary : .secondary)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct MovementRow: View {
    let mmPerSecond: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Bewegung")
                Spacer()
                Text(String(format: "%.0f mm/s", mmPerSecond)).font(.title3.monospacedDigit().bold())
            }
            ProgressView(value: min(mmPerSecond / 60, 1))
                .tint(mmPerSecond > SonarProcessor.movementThreshold ? .orange : .green)
            Text("Atmen allein ≈ 2–8 mm/s, ab 15 mm/s gilt es als Bewegung")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct WaveformChart: View {
    let values: [Double]

    var body: some View {
        if values.isEmpty {
            Text("Noch keine Daten").foregroundStyle(.secondary)
        } else {
            Chart {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("s", Double(i) / 10), y: .value("mm", v))
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxisLabel("Sekunden")
            .chartYAxisLabel("mm")
        }
    }
}

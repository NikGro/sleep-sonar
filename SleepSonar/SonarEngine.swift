import AVFAudio
import Foundation
import SonarDSP
import UIKit

/// Sendet einen Dauerton über den Lautsprecher und wertet das Mikrofon aus.
/// Startet die Audio-Engine selbstständig neu, wenn iOS sie stoppt
/// (z. B. bei Routen- oder Abtastratenwechsel kurz nach dem Start).
@MainActor
final class SonarEngine: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var reading: SonarReading?
    @Published private(set) var errorMessage: String?
    @Published private(set) var diagnostics = Diagnostics()
    /// Empfangspegel relativ zum Sendepegel (dB), 2 Werte pro Sekunde, letzte 60 s
    @Published private(set) var levelHistory: [Double] = []
    /// Aktueller Sendepegel 0…1
    @Published private(set) var currentLevel: Float = 0
    /// Obergrenze; sinkt, wenn der Lautsprecherschutz erkannt wird
    @Published private(set) var ceiling: Float = SonarEngine.maxLevel
    @Published var autoLevel = true
    /// Nachtmessung: protokolliert alles, Bildschirm darf sperren
    @Published private(set) var nightRecorder: NightRecorder?
    @Published private(set) var motionActivity: Double = 0
    @Published private(set) var startDate: Date?
    private var motion: MotionLogger?

    static let maxLevel: Float = 0.85
    static let minAutoLevel: Float = 0.05
    static let autoStartLevel: Float = 0.4

    struct Diagnostics {
        var inputRate: Double = 0
        var outputRate: Double = 0
        var route = ""
        var ioBufferMS: Double = 0
        var restarts = 0
        var events: [String] = []
    }

    private var engine: AVAudioEngine?
    private var tone: ToneState?
    private var worker: Worker?
    private var carrierHz = 20_000.0
    private var volume: Float = 0.15
    private var observers: [NSObjectProtocol] = []
    private var watchdog: Timer?

    func start(carrierHz: Double, volume: Float, auto: Bool, night: Bool = false) async {
        guard !isRunning else { return }
        teardown()
        tone = nil
        worker = nil
        autoLevel = auto
        ceiling = Self.maxLevel
        reference = nil
        recentLevels = []
        lastLevelChange = Date()
        let startLevel = auto ? Self.autoStartLevel : min(volume, Self.maxLevel)
        currentLevel = startLevel
        errorMessage = nil
        reading = nil
        levelHistory = []
        diagnostics = Diagnostics()
        self.carrierHz = carrierHz
        self.volume = startLevel

        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Kein Mikrofonzugriff. Einstellungen → SleepSonar → Mikrofon erlauben."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            // .measurement schaltet Echo-Unterdrückung und Automatik-Pegel ab
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
            try session.overrideOutputAudioPort(.speaker)
            observeSession()
            if night {
                UIDevice.current.isBatteryMonitoringEnabled = true
                nightRecorder = try NightRecorder(meta: [
                    "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                    "device": Self.deviceModel(),
                    "ios": UIDevice.current.systemVersion,
                    "carrier_hz": carrierHz,
                    "auto_level": auto,
                    "max_level": Double(Self.maxLevel),
                ])
                let rec = nightRecorder
                let m = MotionLogger { [weak self] activity, maxDelta, pitch, roll in
                    rec?.appendMotion(activity: activity, maxDelta: maxDelta, pitch: pitch, roll: roll)
                    Task { @MainActor in self?.motionActivity = activity }
                }
                m.start()
                motion = m
            }
            try buildAndStart()
            isRunning = true
            startDate = Date()
            // Nachts darf der Bildschirm sperren (Audio läuft im Hintergrund weiter)
            UIApplication.shared.isIdleTimerDisabled = !night
            log(night ? "Nachtmessung gestartet" : "Gestartet")
            if night { logBattery() }
            // Falls iOS die Engine ohne Benachrichtigung anhält
            watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkAlive() }
            }
        } catch {
            errorMessage = "Audio-Fehler: \(error.localizedDescription)"
            stop()
        }
    }

    func setVolume(_ v: Float) {
        guard !autoLevel else { return }
        apply(min(v, Self.maxLevel))
    }

    func setAuto(_ on: Bool) {
        autoLevel = on
        reference = nil
        recentLevels = []
        lastLevelChange = Date()
    }

    private func apply(_ v: Float) {
        volume = v
        currentLevel = v
        tone?.targetAmplitude = v
        lastLevelChange = Date()
        recentLevels.removeAll()
    }

    private func receive(_ r: SonarReading) {
        reading = r
        nightRecorder?.appendReading(r, txLevel: currentLevel, ceiling: ceiling)
        levelHistory.append(r.levelDB)
        if levelHistory.count > 120 { levelHistory.removeFirst(levelHistory.count - 120) }
        autoAdjust(r)
    }

    private func logBattery() {
        let d = UIDevice.current
        let state: String
        switch d.batteryState {
        case .charging: state = "lädt"
        case .full: state = "voll"
        case .unplugged: state = "NICHT am Strom"
        default: state = "unbekannt"
        }
        log(String(format: "Akku %.0f %%, %@", d.batteryLevel * 100, state))
    }

    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    // MARK: - Automatischer Pegel

    private var reference: Double?
    private var recentLevels: [Double] = []
    private var lastLevelChange = Date()
    private var dropCount = 0

    /// Regelt den Sendepegel: so leise wie möglich bei ausreichendem Körperecho,
    /// nie über der Obergrenze. Fällt der (auf den Sendepegel normierte) Empfangspegel
    /// ohne Bewegung deutlich ab, regelt der Lautsprecherschutz → Obergrenze senken.
    private func autoAdjust(_ r: SonarReading) {
        recentLevels.append(r.levelDB)
        if recentLevels.count > 20 { recentLevels.removeFirst() }
        guard autoLevel, isRunning, volume > 0, r.status != .warmingUp else { return }
        // nach einer Änderung erst einschwingen lassen
        guard Date().timeIntervalSince(lastLevelChange) > 6, recentLevels.count >= 8 else { return }
        let med = recentLevels.suffix(8).sorted()[4]

        if r.status != .moving {
            if let ref = reference, med < ref - 3 {
                dropCount += 1
                if dropCount >= 2 {
                    dropCount = 0
                    ceiling = max(Self.minAutoLevel, volume * 0.7)
                    log(String(format: "Lautsprecherschutz (−%.0f dB) → Obergrenze %d %%",
                               ref - med, Int(ceiling * 100)))
                    reference = nil
                    apply(ceiling)
                    return
                }
            } else {
                dropCount = 0
                // Referenz folgt nach oben sofort, nach unten nur langsam (1 dB / 10 s)
                reference = max(med, (reference ?? med) - 0.05)
            }
        }

        if r.status == .noEcho || r.snr < 3 {
            if volume < ceiling - 0.005 {
                let v = min(ceiling, volume * 1.41)   // +3 dB
                log(String(format: "Echo schwach → Pegel %d %%", Int(v * 100)))
                apply(v)
            }
        } else if r.snr > 8, volume > Self.minAutoLevel + 0.005 {
            apply(max(Self.minAutoLevel, volume / 1.19))   // −1,5 dB
        }
    }

    /// Blendet den Ton aus (kein Knacken) und stoppt dann.
    func stop() {
        guard isRunning || engine != nil else { return }
        isRunning = false            // verhindert Neustarts
        watchdog?.invalidate()
        watchdog = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        tone?.targetAmplitude = 0
        UIApplication.shared.isIdleTimerDisabled = false
        if let rec = nightRecorder {
            logBattery()
            log("Gestoppt")
            motion?.stop()
            motion = nil
            worker?.recorder = nil
            rec.finish()
            nightRecorder = nil
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !self.isRunning else { return }   // inzwischen neu gestartet
            self.teardown()
            self.tone = nil
            self.worker = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - Engine

    private func buildAndStart() throws {
        teardown()
        let session = AVAudioSession.sharedInstance()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        let rate = inFormat.sampleRate > 0 ? inFormat.sampleRate : session.sampleRate
        guard carrierHz < rate / 2 - 500 else {
            throw NSError(domain: "Sonar", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Abtastrate \(Int(rate)) Hz ist zu niedrig für \(Int(carrierHz)) Hz."])
        }

        // Sender: weich einblenden, damit es nicht knackt
        let tone = ToneState(frequency: carrierHz, sampleRate: rate, amplitude: volume)
        let outFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let source = Self.makeSourceNode(format: outFormat, tone: tone)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: outFormat)

        // Empfänger: bei gleicher Rate weiterverwenden, Daten aber verwerfen
        // (Sende- und Empfangsphase starten neu)
        let worker: Worker
        if let w = self.worker, w.sampleRate == rate {
            w.reset()
            worker = w
        } else {
            worker = Worker(sampleRate: rate, carrierHz: carrierHz) { [weak self] r in
                Task { @MainActor in self?.receive(r) }
            }
        }
        worker.tone = tone
        worker.recorder = nightRecorder
        nightRecorder?.setMeta("sample_rate", rate)
        Self.installTap(on: input, format: inFormat, worker: worker)

        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restart(reason: "Audio-Konfiguration geändert") }
        })

        engine.prepare()
        try engine.start()
        self.engine = engine
        self.tone = tone
        self.worker = worker

        diagnostics.inputRate = rate
        diagnostics.outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        diagnostics.ioBufferMS = session.ioBufferDuration * 1000
        diagnostics.route = session.currentRoute.outputs.map(\.portName).joined(separator: ", ")
            + " / " + session.currentRoute.inputs.map(\.portName).joined(separator: ", ")
    }

    private func teardown() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func restart(reason: String) {
        guard isRunning else { return }
        diagnostics.restarts += 1
        log("Neustart: \(reason)")
        do {
            try buildAndStart()
        } catch {
            errorMessage = "Neustart fehlgeschlagen: \(error.localizedDescription)"
            log("Neustart fehlgeschlagen")
        }
    }

    private func checkAlive() {
        guard isRunning, let engine, !engine.isRunning else { return }
        restart(reason: "Engine stand still")
    }

    private func observeSession() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                        queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            Task { @MainActor in
                guard let self else { return }
                if type == .began {
                    self.log("Unterbrechung (Anruf/Wecker?)")
                } else {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self.restart(reason: "Unterbrechung beendet")
                }
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                        queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            Task { @MainActor in
                let route = AVAudioSession.sharedInstance().currentRoute
                self?.diagnostics.route = route.outputs.map(\.portName).joined(separator: ", ")
                    + " / " + route.inputs.map(\.portName).joined(separator: ", ")
                self?.log("Routenwechsel (Grund \(raw))")
            }
        })
    }

    private func log(_ text: String) {
        nightRecorder?.event(text)
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        diagnostics.events.insert("\(f.string(from: Date()))  \(text)", at: 0)
        if diagnostics.events.count > 10 { diagnostics.events.removeLast() }
    }

    // Die Audio-Closures laufen auf Audio-Threads, deshalb außerhalb des MainActors erzeugen.
    nonisolated private static func makeSourceNode(format: AVAudioFormat, tone: ToneState) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            tone.render(frameCount: Int(frameCount), into: audioBufferList)
            return noErr
        }
    }

    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, worker: Worker) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            worker.handle(buffer: buffer, time: time)
        }
    }
}

/// Sinusgenerator für den Echtzeit-Thread (keine Allokationen).
final class ToneState: @unchecked Sendable {
    private var phase = 0.0
    private let increment: Double
    private let smoothing: Float
    private(set) var amplitude: Float = 0
    var targetAmplitude: Float

    init(frequency: Double, sampleRate: Double, amplitude: Float) {
        increment = 2 * .pi * frequency / sampleRate
        smoothing = Float(1 / (0.3 * sampleRate))   // ~300 ms
        targetAmplitude = amplitude
    }

    func render(frameCount: Int, into list: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let target = targetAmplitude
        for i in 0..<frameCount {
            // sanft ein-/ausblenden, damit es nicht knackt
            amplitude += (target - amplitude) * smoothing
            let v = amplitude * Float(sin(phase))
            phase += increment
            if phase > 2 * .pi { phase -= 2 * .pi }
            for b in buffers {
                b.mData?.assumingMemoryBound(to: Float.self)[i] = v
            }
        }
    }
}

/// Läuft auf dem Tap-Thread: füttert den Prozessor, wertet zweimal pro Sekunde aus.
final class Worker: @unchecked Sendable {
    let sampleRate: Double
    private let processor: SonarProcessor
    private let lock = NSLock()
    private let publish: @Sendable (SonarReading) -> Void
    private var lastAnalysis = Date.distantPast
    weak var tone: ToneState?
    var recorder: NightRecorder? {
        didSet {
            processor.sampleHandler = { [weak self] z in
                guard let self, let rec = self.recorder else { return }
                rec.appendIQ(z, gain: self.currentGain)
            }
        }
    }
    private var currentGain: Float = 1

    init(sampleRate: Double, carrierHz: Double, publish: @escaping @Sendable (SonarReading) -> Void) {
        self.sampleRate = sampleRate
        processor = SonarProcessor(sampleRate: sampleRate, carrierHz: carrierHz)
        self.publish = publish
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        processor.reset()
    }

    func handle(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let data = buffer.floatChannelData?[0] else { return }
        lock.lock(); defer { lock.unlock() }
        let n = Int(buffer.frameLength)
        let st: Int64? = time.isSampleTimeValid ? time.sampleTime : nil
        currentGain = tone?.amplitude ?? 1
        processor.process(UnsafeBufferPointer(start: data, count: n), sampleTime: st, gain: Double(currentGain))
        let now = Date()
        if now.timeIntervalSince(lastAnalysis) >= 0.5 {
            lastAnalysis = now
            publish(processor.analyze())
        }
    }
}

import AVFAudio
import Foundation
import UIKit

/// Nachtaufnahme nur mit dem Mikrofon. Sendet keinen Ton, mischt sich mit anderen Apps
/// (Instagram & Co. unterbrechen die Aufnahme nicht) und startet nach Störungen neu.
@MainActor
final class PassiveNightEngine: ObservableObject {
    /// Eine Instanz für App und Kurzbefehle
    static let shared = PassiveNightEngine()
    private init() {}

    @Published private(set) var isRunning = false
    @Published private(set) var startDate: Date?
    @Published private(set) var levelDB: Double = -120
    @Published private(set) var bandDB: [Double] = [-120, -120, -120]
    @Published private(set) var motionActivity: Double = 0
    @Published private(set) var restarts = 0
    @Published private(set) var events: [String] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var folder: URL?
    @Published private(set) var inputName = ""

    private var engine: AVAudioEngine?
    private var recorder: PassiveRecorder?
    private var motion: MotionLogger?
    private var observers: [NSObjectProtocol] = []
    private var watchdog: Timer?

    func start() async {
        guard !isRunning else { return }
        errorMessage = nil
        events = []
        restarts = 0
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Kein Mikrofonzugriff. Einstellungen → SleepSonar → Mikrofon erlauben."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            // Mischbar: andere Apps dürfen abspielen, ohne die Aufnahme zu unterbrechen.
            // .measurement: keine automatische Pegelregelung / Rauschunterdrückung.
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
            if let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(mic)
            }
            UIDevice.current.isBatteryMonitoringEnabled = true
            let rec = try PassiveRecorder(meta: [
                "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                "device": Self.deviceModel(),
                "ios": UIDevice.current.systemVersion,
            ]) { [weak self] db, bands in
                Task { @MainActor in
                    self?.levelDB = db
                    self?.bandDB = bands
                }
            }
            recorder = rec
            folder = rec.folder
            let m = MotionLogger { [weak self] activity, maxDelta, pitch, roll in
                rec.appendMotion(activity: activity, maxDelta: maxDelta, pitch: pitch, roll: roll)
                Task { @MainActor in self?.motionActivity = activity }
            }
            m.start()
            motion = m
            observeSession()
            try buildAndStart()
            isRunning = true
            startDate = Date()
            log("Nachtaufnahme gestartet (nur Mikrofon)")
            logBattery()
            watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkAlive() }
            }
        } catch {
            errorMessage = "Audio-Fehler: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        motion?.stop()
        motion = nil
        if let recorder {
            logBattery()
            log("Gestoppt")
            recorder.finish()
        }
        recorder = nil
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Engine

    private func buildAndStart() throws {
        if let old = engine {
            old.inputNode.removeTap(onBus: 0)
            old.stop()
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Passive", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Kein Mikrofon verfügbar"])
        }
        if let rec = recorder { Self.installTap(on: input, format: format, recorder: rec) }
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restart(reason: "Audio-Konfiguration geändert") }
        })
        engine.prepare()
        try engine.start()
        self.engine = engine
        let route = AVAudioSession.sharedInstance().currentRoute
        inputName = route.inputs.map(\.portName).joined(separator: ", ")
        recorder?.setMeta("input_sample_rate", format.sampleRate)
        recorder?.setMeta("input", inputName)
    }

    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat,
                                               recorder: PassiveRecorder) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            recorder.handle(buffer)
        }
    }

    private func restart(reason: String) {
        guard isRunning else { return }
        restarts += 1
        log("Neustart: \(reason)")
        do {
            try buildAndStart()
        } catch {
            log("Neustart fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    private func checkAlive() {
        guard isRunning, let engine, !engine.isRunning else { return }
        restart(reason: "Aufnahme stand still")
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
                    self.log("Unterbrechung (Anruf/Wecker/Siri?)")
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
                let inputs = AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portName)
                self?.inputName = inputs.joined(separator: ", ")
                self?.log("Routenwechsel (Grund \(raw)), Eingang: \(inputs.joined(separator: ", "))")
            }
        })
    }

    private func log(_ text: String) {
        recorder?.event(text)
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        events.insert("\(f.string(from: Date()))  \(text)", at: 0)
        if events.count > 10 { events.removeLast() }
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
}

import ActivityKit
import AVFAudio
import SonarDSP
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
    /// Hochton-Pegel (Atemrauschen) der letzten 30 s, alle 0,1 s – für die Atemlinie
    @Published private(set) var recentBreath: [BreathLine.Sample] = []
    /// Audiozeit → Uhrzeit: Startpunkt, wird neu gesetzt, wenn er mehr als 0,5 s abweicht
    private var breathAnchor: TimeInterval?
    @Published private(set) var motionActivity: Double = 0
    @Published private(set) var restarts = 0
    @Published private(set) var events: [String] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var folder: URL?
    /// zuletzt beendete Aufnahme war zu kurz zum Auswerten (und wurde verworfen) – Hinweis in „Heute Nacht“
    @Published var tooShort = false
    /// darunter kann das Modell nichts schätzen (mindestens 20 Abschnitte à 30 s, etwas Puffer)
    static let minimumSeconds: TimeInterval = 11 * 60
    @Published private(set) var inputName = ""

    private var engine: AVAudioEngine?
    private var recorder: PassiveRecorder?
    private var motion: MotionLogger?
    private var observers: [NSObjectProtocol] = []
    private var watchdog: Timer?
    private var activity: Activity<NightActivityAttributes>?
    /// Sekundenwerte der laufenden Nacht für den Wecker (gleiche Daten wie levels.csv)
    private var secondsHistory: [SleepStaging.Second?] = []
    private var motionHistory: [Double?] = []
    private var motionPeak = 0.0
    private var alarmTimer: Timer?

    func start() async {
        guard !isRunning else { return }
        errorMessage = nil
        events = []
        restarts = 0
        recentBreath = []
        breathAnchor = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = tr("Kein Mikrofonzugriff. Einstellungen → Suya → Mikrofon erlauben.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            // Mischbar: andere Apps dürfen abspielen, ohne die Aufnahme zu unterbrechen.
            // .measurement: keine automatische Pegelregelung / Rauschunterdrückung.
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.mixWithOthers, .defaultToSpeaker])
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
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
                    guard let self else { return }
                    self.levelDB = db
                    self.bandDB = bands
                    self.secondsHistory.append(.init(rms: db, mid: bands[1], high: bands[2]))
                    self.motionHistory.append(self.motionPeak)
                    self.motionPeak = 0
                }
            }
            rec.onTick = { [weak self] high, index in
                let arrived = Date().timeIntervalSinceReferenceDate
                Task { @MainActor in
                    guard let self else { return }
                    // Zeitstempel aus der Audiozeit, nicht aus der (stoßweisen) Ankunft
                    let audio = Double(index) * 0.1
                    if let a = self.breathAnchor, abs(a + audio - arrived) < 0.5 {} else { self.breathAnchor = arrived - audio }
                    self.recentBreath.append(.init(t: self.breathAnchor! + audio, v: high))
                    let cut = arrived - BreathLine.window - 2
                    if let i = self.recentBreath.firstIndex(where: { $0.t >= cut }), i > 0 { self.recentBreath.removeFirst(i) }
                }
            }
            recorder = rec
            folder = rec.folder
            SoundReference.shared.setFolder(rec.folder)
            let m = MotionLogger { [weak self] activity, maxDelta, pitch, roll in
                rec.appendMotion(activity: activity, maxDelta: maxDelta, pitch: pitch, roll: roll)
                Task { @MainActor in
                    self?.motionActivity = activity
                    self?.motionPeak = max(self?.motionPeak ?? 0, activity)
                }
            }
            m.start()
            motion = m
            observeSession()
            // Live-Aktivität vor dem Mikrofon: Pflicht für den Start im Hintergrund per Kurzbefehl
            startDate = Date()
            startActivity()
            try buildAndStart()
            isRunning = true
            Orientation.recordingChanged(true)
            log(tr("Nachtaufnahme gestartet (nur Mikrofon)"))
            logBattery()
            watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkAlive() }
            }
            secondsHistory = []
            motionHistory = []
            if let startDate { SmartAlarm.shared.recordingStarted(at: startDate) }
            SleepSoundPlayer.shared.recordingStarted()
            alarmTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    SmartAlarm.shared.tick(seconds: self.secondsHistory, motion: self.motionHistory)
                    SleepSoundPlayer.shared.tick(seconds: self.secondsHistory, motion: self.motionHistory)
                }
            }
        } catch {
            errorMessage = tr("Audio-Fehler: %@", error.localizedDescription)
            stop()
        }
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        if alarmTimer != nil { SmartAlarm.shared.recordingStopped() }
        alarmTimer?.invalidate()
        alarmTimer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        motion?.stop()
        motion = nil
        SoundReference.shared.setFolder(nil)
        let short = recorder != nil && Date().timeIntervalSince(startDate ?? Date()) < Self.minimumSeconds
        if let recorder {
            logBattery()
            log(tr("Gestoppt"))
            recorder.finish()
        }
        recorder = nil
        // zu kurz zum Auswerten: keine Nacht in der Übersicht anlegen
        if short, let f = folder {
            try? FileManager.default.removeItem(at: f)
            folder = nil
            tooShort = true
        }
        isRunning = false
        SleepSoundPlayer.shared.recordingStopped()
        endActivity()
        Orientation.recordingChanged(false)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        // Nacht in Health eintragen (außer die Watch hat sie schon)
        Task { await HealthSync.syncRecent() }
    }

    /// Eintrag ins Protokoll der laufenden Nacht (z. B. Klänge an/aus)
    func note(_ text: String) {
        if isRunning { log(text) }
    }

    /// Klänge an/aus maschinenlesbar festhalten (sounds.csv: Sekunden seit Aufnahmebeginn),
    /// damit das Modell diese Zeit ausblenden kann
    func soundMark(on: Bool) {
        guard isRunning, let folder, let startDate else { return }
        let url = folder.appendingPathComponent("sounds.csv")
        let line = String(format: "%.1f,%@\n", Date().timeIntervalSince(startDate), on ? "an" : "aus")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? ("seconds,state\n" + line).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Live-Aktivität (Dynamic Island, Sperrbildschirm, StandBy)

    private func startActivity() {
        guard let startDate else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log(tr("Live-Aktivitäten sind aus (Einstellungen → Suya → Live-Aktivitäten)"))
            return
        }
        // Reste einer abgebrochenen Nacht aufräumen
        for old in Activity<NightActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        do {
            activity = try Activity.request(
                attributes: NightActivityAttributes(start: startDate),
                content: .init(state: .init(handled: false), staleDate: nil))
            log(tr("Live-Aktivität gestartet"))
            updateActivity()
        } catch {
            log(tr("Live-Aktivität nicht möglich: %@", error.localizedDescription))
        }
    }

    /// Klänge in der Live-Aktivität aktuell halten
    func updateActivity() {
        guard let activity else { return }
        let p = SleepSoundPlayer.shared
        let state = NightActivityAttributes.ContentState(
            handled: false, sounds: p.active.isEmpty ? nil : p.activeNames, playing: p.isPlaying,
            fadeStart: p.isPlaying ? p.fadeStart : nil, fadeEnd: p.isPlaying ? p.fadeEnd : nil)
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    private func endActivity() {
        let all = Activity<NightActivityAttributes>.activities
        activity = nil
        for a in all { Task { await a.end(nil, dismissalPolicy: .immediate) } }
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
                          userInfo: [NSLocalizedDescriptionKey: tr("Kein Mikrofon verfügbar")])
        }
        if let rec = recorder { Self.installTap(on: input, format: format, recorder: rec) }
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restart(reason: tr("Audio-Konfiguration geändert")) }
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
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            recorder.handle(buffer, hostTime: when.isHostTimeValid ? when.hostTime : mach_absolute_time())
        }
    }

    private var failedRestarts = 0

    private var pausedForAlarm = false

    private func restart(reason: String) {
        guard isRunning else { return }
        // Solange ein Wecker klingelt, nicht wieder aufnehmen: das Aktivieren der Audio-Sitzung
        // würde den Weckton abbrechen. Danach startet der Wächter die Aufnahme von selbst.
        if #available(iOS 26.0, *), AlarmBackend.isRinging {
            if !pausedForAlarm { log(tr("Wecker klingelt – Aufnahme pausiert")) }
            pausedForAlarm = true
            return
        }
        pausedForAlarm = false
        restarts += 1
        // nach einer Unterbrechung (z. B. Wecker) meldet iOS das Ende oft nicht: Sitzung selbst wieder aktivieren
        try? AVAudioSession.sharedInstance().setActive(true)
        do {
            try buildAndStart()
            if failedRestarts > 0 { log(tr("Aufnahme läuft wieder")) }
            else { log(tr("Neustart: %@", reason)) }
            failedRestarts = 0
        } catch {
            // nicht alle 2 s ins Protokoll schreiben
            if failedRestarts == 0 || failedRestarts % 30 == 0 {
                log(tr("Neustart fehlgeschlagen: %@", error.localizedDescription))
            }
            failedRestarts += 1
        }
    }

    private func checkAlive() {
        guard isRunning, let engine, !engine.isRunning else { return }
        restart(reason: tr("Aufnahme stand still"))
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
                    self.log(tr("Unterbrechung (Anruf/Wecker/Siri?)"))
                } else {
                    self.restart(reason: tr("Unterbrechung beendet"))
                }
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                        queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            Task { @MainActor in
                let inputs = AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portName)
                self?.inputName = inputs.joined(separator: ", ")
                self?.log(tr("Routenwechsel (Grund %@), Eingang: %@", "\(raw)", inputs.joined(separator: ", ")))
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
        case .charging: state = tr("lädt")
        case .full: state = tr("voll")
        case .unplugged: state = tr("NICHT am Strom")
        default: state = tr("unbekannt")
        }
        log(tr("Akku %.0f %%, %@", Double(d.batteryLevel * 100), state))
    }

    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

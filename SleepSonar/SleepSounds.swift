import AVFoundation
import Foundation
import SonarDSP
import SwiftUI

/// Eingebaute Schlafklänge (eigene Synthese, nahtlose 60-s-Schleifen in SleepSounds/).
enum SleepSound: String, CaseIterable, Identifiable, Codable {
    case regen, wellen, wind, kamin, ventilator, rosa, braun
    var id: String { rawValue }
    var name: String {
        switch self {
        case .regen: tr("Regen")
        case .wellen: tr("Meereswellen")
        case .wind: tr("Wind")
        case .kamin: tr("Kaminfeuer")
        case .ventilator: tr("Ventilator")
        case .rosa: tr("Rosa Rauschen")
        case .braun: tr("Braunes Rauschen")
        }
    }
    var symbol: String {
        switch self {
        case .regen: "cloud.rain"
        case .wellen: "water.waves"
        case .wind: "wind"
        case .kamin: "flame"
        case .ventilator: "fan"
        case .rosa: "waveform"
        case .braun: "waveform.path"
        }
    }
}

/// Eine eigene Mischung: Lautstärke je Klang (0 = aus).
struct SoundMix: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var volumes: [SleepSound: Double]
}

/// Spielt die Mischung, blendet nach Zeit oder beim Einschlafen aus und liefert die Referenz
/// für das Herausrechnen aus dem Mikrofon.
@MainActor
final class SleepSoundPlayer: ObservableObject {
    static let shared = SleepSoundPlayer()

    private let d = UserDefaults.standard
    @Published var volumes: [SleepSound: Double] { didSet { applyVolumes(); persist() } }
    @Published var master: Double { didSet { applyVolumes(); d.set(master, forKey: "sounds.master") } }
    /// Ausschalten nach Minuten (0 = kein Zeitlimit)
    @Published var timerMinutes: Int { didSet { d.set(timerMinutes, forKey: "sounds.timer"); scheduleTimer() } }
    /// Ausblenden, sobald die Nachtaufnahme Schlaf erkennt
    @Published var stopOnSleep: Bool { didSet { d.set(stopOnSleep, forKey: "sounds.sleep") } }
    @Published private(set) var mixes: [SoundMix] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var stopsAt: Date?
    @Published private(set) var fading = false

    private var engine: AVAudioEngine?
    private var nodes: [SleepSound: AVAudioPlayerNode] = [:]
    private var timer: Timer?
    private var fadeTimer: Timer?
    private var fadeGain = 1.0
    private var checking = false
    private var configObserver: NSObjectProtocol?

    private init() {
        if let data = d.data(forKey: "sounds.volumes"),
           let v = try? JSONDecoder().decode([SleepSound: Double].self, from: data) {
            volumes = v
        } else {
            volumes = [.regen: 0.6]
        }
        master = d.object(forKey: "sounds.master") as? Double ?? 0.6
        timerMinutes = d.object(forKey: "sounds.timer") as? Int ?? 30
        stopOnSleep = d.object(forKey: "sounds.sleep") as? Bool ?? true
        if let data = d.data(forKey: "sounds.mixes"), let m = try? JSONDecoder().decode([SoundMix].self, from: data) {
            mixes = m
        }
    }

    var active: [SleepSound] { SleepSound.allCases.filter { (volumes[$0] ?? 0) > 0.01 } }

    var activeNames: String { active.map(\.name).joined(separator: " + ") }

    private func persist() {
        if let data = try? JSONEncoder().encode(volumes) { d.set(data, forKey: "sounds.volumes") }
    }

    // MARK: Mischungen

    func saveMix(named name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        mixes.append(SoundMix(name: clean.isEmpty ? activeNames : clean, volumes: volumes))
        persistMixes()
    }

    func load(_ mix: SoundMix) { volumes = mix.volumes }

    func deleteMixes(at offsets: IndexSet) {
        mixes.remove(atOffsets: offsets)
        persistMixes()
    }

    private func persistMixes() {
        if let data = try? JSONEncoder().encode(mixes) { d.set(data, forKey: "sounds.mixes") }
    }

    // MARK: Wiedergabe

    func toggle() { isPlaying ? stop(fade: true) : play() }

    func play() {
        guard !active.isEmpty else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // gleiche Einstellung wie die Aufnahme, damit beide ohne Unterbrechung zusammen laufen
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
            let engine = AVAudioEngine()
            for s in SleepSound.allCases {
                guard let url = Bundle.main.url(forResource: s.rawValue, withExtension: "m4a"),
                      let file = try? AVAudioFile(forReading: url),
                      let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                 frameCapacity: AVAudioFrameCount(file.length)) else { continue }
                try file.read(into: buf)
                let node = AVAudioPlayerNode()
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: buf.format)
                node.scheduleBuffer(buf, at: nil, options: .loops)
                nodes[s] = node
            }
            // Referenz für das Herausrechnen aus dem Mikrofon
            let mixer = engine.mainMixerNode
            EchoCanceller.shared.reset()
            mixer.installTap(onBus: 0, bufferSize: 2048, format: mixer.outputFormat(forBus: 0)) { buffer, when in
                EchoCanceller.shared.pushReference(buffer, hostTime: when.isHostTimeValid ? when.hostTime : mach_absolute_time())
            }
            try engine.start()
            nodes.values.forEach { $0.play() }
            self.engine = engine
            // startet die Aufnahme, ändert sich die Audio-Konfiguration: Wiedergabe neu aufbauen
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.restartAfterChange() }
            }
            fadeGain = 0
            isPlaying = true
            fading = false
            applyVolumes()
            fade(to: 1, seconds: 3)
            scheduleTimer()
            PassiveNightEngine.shared.note(tr("Klänge an: %@", activeNames))
        } catch {
            stopNow()
        }
    }

    private func restartAfterChange() {
        guard isPlaying, !fading else { return }
        let until = stopsAt
        stopNow(quiet: true)
        play()
        if let until { scheduleTimer(until: until) }
    }

    func stop(fade: Bool) {
        guard isPlaying else { return }
        if fade {
            fading = true
            self.fade(to: 0, seconds: 30) { [weak self] in self?.stopNow() }
        } else {
            stopNow()
        }
    }

    private func stopNow(quiet: Bool = false) {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        timer?.invalidate(); timer = nil
        fadeTimer?.invalidate(); fadeTimer = nil
        engine?.mainMixerNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        nodes = [:]
        if isPlaying && !quiet { PassiveNightEngine.shared.note(tr("Klänge aus")) }
        if !PassiveNightEngine.shared.isRunning && !quiet {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        isPlaying = false
        fading = false
        stopsAt = nil
    }

    private func applyVolumes() {
        for (s, node) in nodes { node.volume = Float(volumes[s] ?? 0) }
        engine?.mainMixerNode.outputVolume = Float(master * fadeGain)
    }

    private var fadeFrom = 0.0, fadeTo = 0.0, fadeStep = 0, fadeSteps = 1
    private var fadeDone: (() -> Void)?

    private func fade(to target: Double, seconds: Double, done: (() -> Void)? = nil) {
        fadeTimer?.invalidate()
        fadeFrom = fadeGain; fadeTo = target; fadeStep = 0; fadeSteps = max(1, Int(seconds * 10)); fadeDone = done
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fadeTick() }
        }
    }

    private func fadeTick() {
        fadeStep += 1
        fadeGain = fadeFrom + (fadeTo - fadeFrom) * Double(min(fadeStep, fadeSteps)) / Double(fadeSteps)
        applyVolumes()
        if fadeStep >= fadeSteps {
            fadeTimer?.invalidate(); fadeTimer = nil
            let done = fadeDone; fadeDone = nil
            done?()
        }
    }

    private func scheduleTimer(until: Date? = nil) {
        timer?.invalidate(); timer = nil
        guard isPlaying, timerMinutes > 0 || until != nil else { stopsAt = nil; return }
        let at = until ?? Date().addingTimeInterval(Double(timerMinutes) * 60)
        stopsAt = at
        timer = Timer.scheduledTimer(withTimeInterval: max(1, at.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop(fade: true) }
        }
    }

    // MARK: Schlaf erkannt → ausblenden (jede Minute von der Nachtaufnahme aufgerufen)

    func tick(seconds: [SleepStaging.Second?], motion: [Double?]) {
        guard isPlaying, stopOnSleep, !fading, !checking, seconds.count >= 12 * 60 else { return }
        checking = true
        Task {
            let asleep = await Task.detached(priority: .utility) {
                Self.fellAsleep(seconds: seconds, motion: motion)
            }.value
            checking = false
            if asleep {
                PassiveNightEngine.shared.note(tr("Schlaf erkannt, Klänge werden ausgeblendet"))
                stop(fade: true)
            }
        }
    }

    /// Eingeschlafen: Einschlafpunkt erkannt und die letzten 5 Minuten durchgehend Schlaf
    nonisolated static func fellAsleep(seconds: [SleepStaging.Second?], motion: [Double?]) -> Bool {
        let epochs = SleepStaging.estimate(seconds: seconds, motion: motion)
        guard epochs.count >= 12, epochs.contains(where: { $0.stage != .wake }) else { return false }
        return epochs[(epochs.count - 11)...(epochs.count - 2)].allSatisfy { $0.stage != .wake }
    }
}

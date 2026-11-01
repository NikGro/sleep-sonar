import AVFoundation
import Foundation
import SonarDSP
import SwiftUI

/// Eingebaute Schlafklänge als nahtlose Schleifen (SleepSounds/<rawValue>.m4a).
/// Naturklänge: echte Aufnahmen (CC0, gemeinfrei, CC BY; Quellen siehe `credit`).
/// Ventilator und Rauschen: selbst erzeugt.
enum SleepSound: String, CaseIterable, Identifiable, Codable {
    case regen, gewitter, wellen, bach, wind, kamin, voegel, sommernacht, zug, boot, cafe, stadt
    case ventilator, weiss, rosa, braun
    var id: String { rawValue }
    var name: String {
        switch self {
        case .regen: tr("Regen")
        case .gewitter: tr("Gewitter")
        case .wellen: tr("Meereswellen")
        case .bach: tr("Bach")
        case .wind: tr("Wind")
        case .kamin: tr("Kaminfeuer")
        case .voegel: tr("Vögel")
        case .sommernacht: tr("Sommernacht")
        case .zug: tr("Zugfahrt")
        case .boot: tr("Boot")
        case .cafe: tr("Café")
        case .stadt: tr("Stadt")
        case .ventilator: tr("Ventilator")
        case .weiss: tr("Weißes Rauschen")
        case .rosa: tr("Rosa Rauschen")
        case .braun: tr("Braunes Rauschen")
        }
    }
    var symbol: String {
        switch self {
        case .regen: "cloud.rain"
        case .gewitter: "cloud.bolt.rain"
        case .wellen: "water.waves"
        case .bach: "drop"
        case .wind: "wind"
        case .kamin: "flame"
        case .voegel: "bird"
        case .sommernacht: "moon.stars"
        case .zug: "tram"
        case .boot: "sailboat"
        case .cafe: "cup.and.saucer"
        case .stadt: "building.2"
        case .ventilator: "fan"
        case .weiss: "waveform"
        case .rosa: "waveform.path"
        case .braun: "waveform.path.ecg"
        }
    }
    /// Herkunft und Lizenz (CC BY verlangt Namensnennung)
    var credit: String? {
        switch self {
        case .regen: "alex36917, freesound.org · CC BY"
        case .gewitter: "Digifish music, freesound.org · CC BY"
        case .wellen: "Luftrum, freesound.org · CC BY"
        case .bach: "gluckose, freesound.org · CC0"
        case .wind: "felix.blume, freesound.org · CC0"
        case .kamin: "ezwa, soundbible.com · gemeinfrei"
        case .voegel: "kvgarlic, freesound.org · CC0"
        case .sommernacht: "Lisa Redfern, soundbible.com · gemeinfrei"
        case .zug: "SDLx, freesound.org · CC BY 3.0"
        case .boot: "Falcet, freesound.org · CC0"
        case .cafe: "stephan, soundbible.com · gemeinfrei"
        case .stadt: "gezortenplotz, freesound.org · CC BY"
        default: nil
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
    /// Mischung automatisch mit der Nachtaufnahme starten
    @Published var autoStart: Bool { didSet { d.set(autoStart, forKey: "sounds.auto") } }
    /// Probehören im Klänge-Tab: ohne Zeitlimit, ohne Ausblenden beim Schlaf, endet im Hintergrund
    @Published private(set) var preview = false
    @Published private(set) var mixes: [SoundMix] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var stopsAt: Date?
    @Published private(set) var fading = false
    /// Ausblenden läuft von … bis … (für die sich füllenden Knöpfe)
    @Published private(set) var fadeStart: Date?
    @Published private(set) var fadeEnd: Date?
    static let fadeSeconds = 30.0

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
        autoStart = d.bool(forKey: "sounds.auto")
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

    /// Knopf: sofort (kurz ausgeblendet) anhalten bzw. starten
    func toggle() {
        if !isPlaying { play() } else if fading { stopSoft() } else { stop(fade: true) }
    }

    /// Klänge-Tab: zum Testen an/aus (sofort, ohne Ausblenden)
    func togglePreview() {
        if isPlaying { stopSoft(); return }
        play(preview: !PassiveNightEngine.shared.isRunning)
    }

    /// Sofort, aber ohne Knacken: in 0,3 s ausblenden
    func stopSoft() {
        guard isPlaying else { return }
        fade(to: 0, seconds: 0.15) { [weak self] in self?.stopNow() }
    }

    // MARK: Puffer (einmal dekodieren, dann sofort startbereit)

    private static var cache: [SleepSound: AVAudioPCMBuffer] = [:]
    private var loading: Set<SleepSound> = []

    /// Klänge im Hintergrund dekodieren, damit Abspielen sofort beginnt
    func preload(_ sounds: [SleepSound]) {
        for s in sounds where Self.cache[s] == nil && !loading.contains(s) {
            loading.insert(s)
            Task {
                let buf = await Task.detached(priority: .userInitiated) { Self.decode(s) }.value
                loading.remove(s)
                if let buf { Self.cache[s] = buf }
                if isPlaying, (volumes[s] ?? 0) > 0.01 { attach(s) }
            }
        }
    }

    nonisolated private static func decode(_ s: SleepSound) -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(forResource: s.rawValue, withExtension: "m4a"),
              let file = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil else { return nil }
        return buf
    }

    /// App geht in den Hintergrund: Probehören endet
    func appBackgrounded() { if preview { stopNow() } }

    /// Nachtaufnahme beginnt: Probehören wird zur Nacht-Wiedergabe, sonst ggf. automatisch starten
    func recordingStarted() {
        if isPlaying {
            preview = false
            scheduleTimer()
            PassiveNightEngine.shared.updateActivity()
        } else if autoStart {
            play()
        }
    }

    /// Nachtaufnahme endet: Klänge enden auch
    func recordingStopped() { if isPlaying { stopNow() } }

    func play(preview: Bool = false) {
        guard !active.isEmpty else { return }
        // Nacht-Wiedergabe nur während der Aufnahme
        guard preview || PassiveNightEngine.shared.isRunning else { return }
        self.preview = preview
        do {
            let session = AVAudioSession.sharedInstance()
            // gleiche Einstellung wie die Aufnahme; nur umstellen, wenn nötig (jede Umstellung knackt)
            if session.category != .playAndRecord || session.mode != .measurement {
                try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
            }
            try session.setActive(true)
            let engine = AVAudioEngine()
            self.engine = engine
            engine.mainMixerNode.outputVolume = 0   // stumm starten, dann einblenden → kein Knacken
            fadeGain = 0
            for s in active { attach(s) }
            preload(active)
            // Referenz für das Herausrechnen aus dem Mikrofon
            let mixer = engine.mainMixerNode
            EchoCanceller.shared.reset()
            mixer.installTap(onBus: 0, bufferSize: 2048, format: mixer.outputFormat(forBus: 0)) { buffer, when in
                EchoCanceller.shared.pushReference(buffer, hostTime: when.isHostTimeValid ? when.hostTime : mach_absolute_time())
            }
            engine.prepare()
            try engine.start()
            nodes.values.forEach { $0.play() }
            // startet die Aufnahme, ändert sich die Audio-Konfiguration: Wiedergabe neu aufbauen
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.restartAfterChange() }
            }
            isPlaying = true
            fading = false
            applyVolumes()
            fade(to: 1, seconds: preview ? 0.25 : 1.5)
            scheduleTimer()
            PassiveNightEngine.shared.note(tr("Klänge an: %@", activeNames))
            PassiveNightEngine.shared.updateActivity()
        } catch {
            stopNow()
        }
    }

    private func restartAfterChange() {
        guard isPlaying, !fading else { return }
        let until = stopsAt
        stopNow(quiet: true)
        play(preview: preview)
        if let until { scheduleTimer(until: until) }
    }

    func stop(fade: Bool, seconds: Double = SleepSoundPlayer.fadeSeconds) {
        guard isPlaying, !fading else { return }
        if fade {
            fading = true
            fadeStart = Date()
            fadeEnd = Date().addingTimeInterval(seconds)
            PassiveNightEngine.shared.updateActivity()
            self.fade(to: 0, seconds: seconds) { [weak self] in self?.stopNow() }
        } else {
            stopNow()
        }
    }

    func stopNow(quiet: Bool = false) {
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
        preview = false
        fading = false
        fadeStart = nil
        fadeEnd = nil
        stopsAt = nil
        PassiveNightEngine.shared.updateActivity()
    }

    /// Klang laden und an den Mischer hängen (beim Start oder wenn er während der Wiedergabe dazukommt)
    @discardableResult private func attach(_ s: SleepSound) -> AVAudioPlayerNode? {
        guard let engine, nodes[s] == nil else { return nil }
        guard let buf = Self.cache[s] else { preload([s]); return nil }   // kommt nach dem Dekodieren
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: buf.format)
        node.scheduleBuffer(buf, at: nil, options: .loops)
        node.volume = Float(volumes[s] ?? 0)
        nodes[s] = node
        if engine.isRunning { node.play() }
        return node
    }

    private func applyVolumes() {
        if isPlaying { for s in active where nodes[s] == nil { attach(s) } } else { preload(active) }
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
        guard isPlaying, !preview, timerMinutes > 0 || until != nil else { stopsAt = nil; return }
        let at = until ?? Date().addingTimeInterval(Double(timerMinutes) * 60)
        stopsAt = at
        timer = Timer.scheduledTimer(withTimeInterval: max(1, at.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop(fade: true) }
        }
    }

    // MARK: Schlaf erkannt → ausblenden (jede Minute von der Nachtaufnahme aufgerufen)

    func tick(seconds: [SleepStaging.Second?], motion: [Double?]) {
        guard isPlaying, !preview, stopOnSleep, !fading, !checking, seconds.count >= 12 * 60 else { return }
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

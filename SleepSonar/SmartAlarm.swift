import ActivityKit
import AlarmKit
import AVFoundation
import Foundation
import SonarDSP
import SwiftUI

/// Ein Wecker mit allen Einstellungen.
struct AlarmItem: Codable, Identifiable, Equatable {
    enum Mode: String, Codable, CaseIterable { case time, duration }

    var id = UUID()
    var enabled = true
    var label = ""
    var mode: Mode = .time
    /// Minuten seit Mitternacht (Modus Uhrzeit)
    var wakeMinutes = 7 * 60
    /// Dauer ab Beginn der Nachtaufnahme in Minuten, 1 … 23 h 59 (Modus Schlafdauer)
    var durationMinutes = 7 * 60 + 30
    /// Leichten Schlaf suchen (nur mit laufender Nachtaufnahme)
    var smart = true
    var windowMinutes = 30
    /// Wochentage nach Calendar (1 = Sonntag … 7 = Samstag); leer = einmalig
    var repeatDays: [Int] = []
    var snooze = true
    var snoozeMinutes = 9
    /// eingebauter Ton (AlarmSound.rawValue) oder "custom" für einen eigenen
    var sound = AlarmSound.morgenlicht.rawValue
    /// Dateiname eines eigenen Tons (Application Support/Sounds)
    var customSound: String?
    var customSoundName: String?
    /// 0 … 1 (−30 dB … 0 dB); der iPhone-Standardton folgt der Systemlautstärke
    var volume = 0.7
    /// in so vielen Sekunden von leise auf die eingestellte Lautstärke (0 = sofort, bis 5 min)
    var rampSeconds = 60

    /// Wann der einmalige Wecker gestellt wurde (danach automatisch aus)
    var onceFor: Date?

    var title: String { label.isEmpty ? tr("Wecker") : label }
}

/// Eingebaute Wecktöne (Sounds/<name>.caf, volle Lautstärke). Lautstärke und Anstieg werden
/// je Wecker in eine eigene Datei gerechnet (AlarmKit kennt keine Lautstärke-Einstellung).
enum AlarmSound: String, CaseIterable, Identifiable {
    case sonnenaufgang, spieluhr, gitarre, morgenlicht, harfe, glocke, voegel, bach, wellen, klassisch, system, custom
    var id: String { rawValue }
    static var builtIn: [AlarmSound] {
        [.sonnenaufgang, .spieluhr, .gitarre, .morgenlicht, .harfe, .glocke, .voegel, .bach, .wellen, .klassisch]
    }
    /// Dateiname im App-Paket (nur dort spielt der Systemwecker eigene Töne zuverlässig ab)
    var bundleFile: String? {
        switch self {
        case .system, .custom: nil
        default: "wecker_\(rawValue).m4a"
        }
    }
    var name: String {
        switch self {
        case .sonnenaufgang: tr("Sonnenaufgang")
        case .spieluhr: tr("Spieluhr")
        case .gitarre: tr("Gitarre")
        case .morgenlicht: tr("Morgenlicht")
        case .harfe: tr("Harfe")
        case .glocke: tr("Glocke")
        case .voegel: tr("Vögel")
        case .bach: tr("Bach")
        case .wellen: tr("Meereswellen")
        case .klassisch: tr("Klassisch")
        case .system: tr("iPhone-Standard")
        case .custom: tr("Eigener Ton")
        }
    }
}

/// Rechnet Lautstärke und Anstieg in den Ton und legt ihn unter Library/Sounds ab (dort sucht AlarmKit).
enum AlarmSoundRenderer {
    static let maxSeconds = 30.0

    static var soundsDir: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dir = lib.appendingPathComponent("Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var customDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func source(_ a: AlarmItem) -> URL? {
        switch AlarmSound(rawValue: a.sound) ?? .system {
        case .system: return nil
        case .custom: return a.customSound.map { customDir.appendingPathComponent($0) }
        default: return Bundle.main.url(forResource: "wecker_" + a.sound, withExtension: "m4a")
        }
    }

    /// Fertige Datei für AlarmKit (Name in Library/Sounds) oder nil für den Standardton
    static func prepare(_ a: AlarmItem) -> String? {
        guard let src = source(a) else { return nil }
        let name = "somnivo-\(a.id.uuidString)-\(Int(a.volume * 100))-\(src.deletingPathExtension().lastPathComponent.prefix(12)).caf"
        let dst = soundsDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dst.path) { return name }
        // alte Fassungen dieses Weckers entfernen
        for f in (try? FileManager.default.contentsOfDirectory(atPath: soundsDir.path)) ?? []
        where f.hasPrefix("somnivo-\(a.id.uuidString)") {
            try? FileManager.default.removeItem(at: soundsDir.appendingPathComponent(f))
        }
        // ohne Lauterwerden: der Systemwecker wiederholt die Datei, ein Anstieg finge jedes Mal neu an
        return (try? render(src, to: dst, volume: a.volume, ramp: 0)) != nil ? name : nil
    }

    static func render(_ src: URL, to dst: URL, volume: Double, ramp: Double) throws {
        let input = try AVAudioFile(forReading: src)
        let format = input.processingFormat
        let frames = AVAudioFrameCount(min(Double(input.length), maxSeconds * format.sampleRate))
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        try input.read(into: buf, frameCount: frames)
        let gain = Float(pow(10, (-30 + 30 * min(1, max(0, volume))) / 20))
        let rampFrames = Float(ramp * format.sampleRate)
        let n = Int(buf.frameLength)
        if let ch = buf.floatChannelData {
            for c in 0..<Int(format.channelCount) {
                for i in 0..<n {
                    let r: Float = rampFrames > 0 ? min(1, 0.05 + 0.95 * Float(i) / rampFrames) : 1
                    ch[c][i] *= gain * r
                }
                // kurz ausblenden, damit es am Ende nicht knackt
                let tail = min(n, Int(format.sampleRate * 0.05))
                for i in 0..<tail { ch[c][n - tail + i] *= Float(tail - i) / Float(tail) }
            }
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
                                       AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        try? FileManager.default.removeItem(at: dst)
        let out = try AVAudioFile(forWriting: dst, settings: settings, commonFormat: format.commonFormat,
                                  interleaved: format.isInterleaved)
        try out.write(from: buf)
    }

    /// Eigenen Ton übernehmen (Dateien-App): Kopie in Application Support/Sounds
    static func importCustom(_ url: URL) throws -> String {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        _ = try AVAudioFile(forReading: url)   // nur lesbare Audiodateien annehmen
        let name = UUID().uuidString + "." + url.pathExtension.lowercased()
        try FileManager.default.copyItem(at: url, to: customDir.appendingPathComponent(name))
        return name
    }
}

/// Alle Wecker, die Verbindung zu AlarmKit und das Wecken im leichten Schlaf.
///
/// Läuft die Nachtaufnahme, prüft die App im Zeitraum vor der spätesten Weckzeit jede Minute die
/// Schlafphase und klingelt früher, sobald du leicht schläfst (nicht Tief, dazu Bewegung) oder
/// schon wach bist. Ohne Aufnahme klingelt jeder Wecker zur eingestellten Zeit.
@MainActor
final class SmartAlarm: ObservableObject {
    static let shared = SmartAlarm()

    @Published private(set) var items: [AlarmItem] = []
    @Published private(set) var problem: String?

    private let store = "alarm.items"
    private var recordingStart: Date?
    private var onset: Date?
    /// Wecker, die in dieser Nacht schon früh geklingelt haben → nach der spätesten Zeit wieder stellen
    private var rang: [UUID: Date] = [:] {
        didSet {
            UserDefaults.standard.set(rang.reduce(into: [String: Double]()) { $0[$1.key.uuidString] = $1.value.timeIntervalSince1970 },
                                      forKey: "alarm.rang")
        }
    }
    private var evaluating = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: store),
           let list = try? JSONDecoder().decode([AlarmItem].self, from: data) {
            items = list
        }
        // früh geweckte Wecker (überlebt einen Neustart der App)
        for (k, v) in UserDefaults.standard.dictionary(forKey: "alarm.rang") as? [String: Double] ?? [:] {
            if let id = UUID(uuidString: k) { rang[id] = Date(timeIntervalSince1970: v) }
        }
    }

    static var isAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    // MARK: Verwalten

    func save(_ item: AlarmItem) {
        var item = item
        item.durationMinutes = min(23 * 60 + 59, max(1, item.durationMinutes))
        item.windowMinutes = min(item.windowMinutes, max(1, item.mode == .duration ? item.durationMinutes : 24 * 60))
        item.onceFor = nil
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
        items.sort { sortKey($0) < sortKey($1) }
        persist()
        Task { await apply(item) }
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard var item = items.first(where: { $0.id == id }) else { return }
        item.enabled = on
        save(item)
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        persist()
        if #available(iOS 26.0, *) { AlarmBackend.cancel(for: id) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: store) }
    }

    private func sortKey(_ a: AlarmItem) -> Int { a.mode == .time ? a.wakeMinutes : 24 * 60 + a.durationMinutes }

    // MARK: Zeiten

    /// Nächste späteste Weckzeit eines Weckers nach `from`
    func latest(_ a: AlarmItem, after from: Date = Date()) -> Date? {
        switch a.mode {
        case .time:
            let cal = Calendar.current
            for dayOffset in 0...7 {
                guard let day = cal.date(byAdding: .day, value: dayOffset, to: from),
                      let at = cal.date(bySettingHour: a.wakeMinutes / 60, minute: a.wakeMinutes % 60, second: 0, of: day),
                      at > from else { continue }
                if a.repeatDays.isEmpty || a.repeatDays.contains(cal.component(.weekday, from: at)) { return at }
            }
            return nil
        case .duration:
            // ab Beginn der Nachtaufnahme; ohne Aufnahme kein Wecker
            guard let start = recordingStart else { return nil }
            return start.addingTimeInterval(Double(a.durationMinutes) * 60)
        }
    }

    // MARK: Systemwecker stellen

    /// Beim App-Start/Vordergrund: abgelaufene einmalige Wecker ausschalten, früh geweckte wiederherstellen
    func refresh() {
        let now = Date()
        for (id, until) in rang where now > until { rang[id] = nil }
        var changed = false
        for i in items.indices {
            if let once = items[i].onceFor, once < now, items[i].repeatDays.isEmpty, items[i].mode == .time {
                items[i].enabled = false
                items[i].onceFor = nil
                changed = true
            }
        }
        if changed { persist() }
        if #available(iOS 26.0, *) {
            AlarmBackend.cancelLegacy()
            for a in items { AlarmBackend.cancelBackup(for: a.id) }
        }
        Task { for a in items { await apply(a) } }
    }

    /// nach geänderter Ton-Einstellung alle Systemwecker neu stellen
    func reapplyAll() async {
        for a in items { await apply(a) }
    }

    private func apply(_ a: AlarmItem) async {
        guard #available(iOS 26.0, *) else { return }
        guard a.enabled, items.contains(where: { $0.id == a.id }) else {
            AlarmBackend.cancel(for: a.id)
            return
        }
        guard await AlarmBackend.authorize() else {
            problem = tr("Suya darf keine Wecker stellen. Erlaube es unter Einstellungen → Apps → Suya → Wecker.")
            return
        }
        problem = nil
        do {
            // schon früh (im leichten Schlaf) geweckt: die späteste Zeit dieses Mal überspringen
            if let done = rang[a.id], done > Date() {
                if a.mode == .time, !a.repeatDays.isEmpty, let next = latest(a, after: done) {
                    try await AlarmBackend.schedule(a, at: next)
                } else {
                    AlarmBackend.cancel(for: a.id)
                }
                return
            }
            switch a.mode {
            case .time:
                try await AlarmBackend.schedule(a, at: nil)
                if a.repeatDays.isEmpty, let at = latest(a), let i = items.firstIndex(where: { $0.id == a.id }) {
                    items[i].onceFor = at
                    persist()
                }
            case .duration:
                // ab Beginn der Nachtaufnahme; ohne Aufnahme kein Wecker
                if let at = latest(a) {
                    try await AlarmBackend.schedule(a, at: at)
                } else {
                    AlarmBackend.cancel(for: a.id)
                }
            }
        } catch {
            problem = tr("Wecker konnte nicht gestellt werden: %@", error.localizedDescription)
        }
    }

    // MARK: Nachtaufnahme

    func recordingStarted(at start: Date) {
        recordingStart = start
        onset = nil
        let now = Date()
        for (id, until) in rang where until < now { rang[id] = nil }
        // im Protokoll festhalten, wann jeder Wecker klingeln darf
        let f = Date.FormatStyle(date: .omitted, time: .shortened)
        for a in items where a.enabled {
            guard let at = latest(a, after: start) else { continue }
            let kind = a.mode == .time ? tr("Uhrzeit") : tr("Schlafdauer")
            if a.smart {
                let from = at.addingTimeInterval(-Double(a.windowMinutes) * 60)
                PassiveNightEngine.shared.note(tr("Wecker „%@“ (%@): spätestens %@, im leichten Schlaf ab %@",
                                                  a.title, kind, at.formatted(f), from.formatted(f)))
            } else {
                PassiveNightEngine.shared.note(tr("Wecker „%@“ (%@): %@", a.title, kind, at.formatted(f)))
            }
        }
        Task { for a in items { await apply(a) } }
    }

    func recordingStopped() {
        recordingStart = nil
        onset = nil
        Task { for a in items { await apply(a) } }   // Schlafdauer-Wecker fallen weg
    }

    /// Späteste Weckzeit eines Weckers in der laufenden Nacht (für die Anzeige)
    func tonight(_ a: AlarmItem) -> Date? {
        recordingStart == nil ? nil : latest(a, after: recordingStart ?? Date())
    }

    /// Jede Minute während der Aufnahme: Einschlafen erkennen, im Zeitraum auf leichten Schlaf prüfen.
    func tick(seconds: [SleepStaging.Second?], motion: [Double?]) {
        guard Self.isAvailable, let start = recordingStart else { return }
        let now = Date()
        for (id, until) in rang where now > until {
            rang[id] = nil
            if let a = items.first(where: { $0.id == id }) { Task { await apply(a) } }
        }
        if AlarmBackend.isAlerting { return }
        guard !evaluating, seconds.count >= 20 * 60 else { return }
        let active = items.filter { $0.enabled && rang[$0.id] == nil }
        let needOnset = false   // Schlafdauer zählt ab Aufnahmebeginn, kein Einschlafpunkt nötig
        let due = active.filter { a in
            guard a.smart, let latest = latest(a, after: start) else { return false }
            return now >= latest.addingTimeInterval(-Double(a.windowMinutes) * 60) && now < latest
        }
        guard needOnset || !due.isEmpty else { return }

        evaluating = true
        Task {
            let result = await Task.detached(priority: .utility) {
                Self.assess(seconds: seconds, motion: motion)
            }.value
            evaluating = false
            if needOnset, let first = result.onsetEpoch {
                onset = start.addingTimeInterval(Double(first) * 30)
                for a in items where a.mode == .duration && a.enabled { await apply(a) }
            }
            guard result.light else { return }
            for a in due where rang[a.id] == nil {
                guard let latest = latest(a, after: start) else { continue }
                await ringNow(a, latest: latest)
            }
        }
    }

    private func ringNow(_ a: AlarmItem, latest: Date) async {
        guard #available(iOS 26.0, *) else { return }
        rang[a.id] = latest.addingTimeInterval(60)
        let f = Date.FormatStyle(date: .omitted, time: .shortened)
        PassiveNightEngine.shared.note(tr("Wecker „%@“ klingelt im leichten Schlaf, %d min vor %@",
                                          a.title, max(0, Int(latest.timeIntervalSinceNow / 60)), latest.formatted(f)))
        do {
            try await AlarmBackend.schedule(a, at: Date().addingTimeInterval(3))
        } catch {
            rang[a.id] = nil
            problem = tr("Wecker konnte nicht gestellt werden: %@", error.localizedDescription)
        }
    }

    /// Schlafphase am Ende der bisherigen Aufnahme (ohne Blick in die Zukunft).
    nonisolated static func assess(seconds: [SleepStaging.Second?], motion: [Double?])
        -> (light: Bool, onsetEpoch: Int?) {
        let epochs = SleepStaging.estimate(seconds: seconds, motion: motion)
        let onset = epochs.firstIndex { $0.stage != .wake }
        guard epochs.count >= 4 else { return (false, onset) }
        // die letzten zwei vollständig bewerteten Epochen (die allerletzte hat noch keinen Kontext)
        let recent = epochs[(epochs.count - 3)...(epochs.count - 2)].map(\.stage)
        if recent.contains(.wake) { return (true, onset) }
        guard !recent.contains(.deep) else { return (false, onset) }
        // leichter Schlaf zeigt sich durch Bewegung: helles Rascheln in den letzten 2 Minuten
        let tail = seconds.suffix(300).compactMap { $0?.high }.sorted()
        guard tail.count > 60 else { return (false, onset) }
        let base = tail[tail.count / 5]
        let rustle = seconds.suffix(120).compactMap { $0?.high }.filter { $0 - base > 14 }.count
        let moved = motion.suffix(120).contains { ($0 ?? 0) > 0.02 }
        return (rustle >= 2 || moved, onset)
    }
}

// MARK: - Probehören

@MainActor
final class SoundPreview: ObservableObject {
    static let shared = SoundPreview()
    private var player: AVAudioPlayer?
    @Published private(set) var playing = false

    /// Spielt den Ton genau so, wie er klingeln wird
    func toggle(_ a: AlarmItem) {
        if playing { stop(); return }
        guard let src = AlarmSoundRenderer.source(a) else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vorschau.caf")
        guard (try? AlarmSoundRenderer.render(src, to: tmp, volume: a.volume, ramp: 0)) != nil else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        player = try? AVAudioPlayer(contentsOf: tmp)
        player?.play()
        playing = player != nil
    }

    func stop() {
        player?.stop()
        player = nil
        playing = false
    }
}

// MARK: - AlarmKit

@available(iOS 26.0, *)
@MainActor
enum AlarmBackend {
    private static let key = "alarm.kitIDs"   // Wecker-ID → AlarmKit-ID
    private static let backupKey = "alarm.backupIDs"

    static func kitID(for id: UUID) -> UUID? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[id.uuidString].flatMap(UUID.init)
    }

    /// Klingelt oder schlummert gerade ein Suya-Wecker?
    static var isAlerting: Bool {
        ((try? AlarmManager.shared.alarms) ?? []).contains { $0.state == .alerting || $0.state == .countdown }
    }

    /// Ton für AlarmKit: mit Lautstärke gerechnet unter Library/Sounds, wenn der Test gezeigt hat,
    /// dass iOS Töne von dort spielt – sonst die fertige Datei im App-Paket.
    static func sound(for a: AlarmItem) -> AlertConfiguration.AlertSound {
        if UserDefaults.standard.bool(forKey: AlarmSoundTest.okKey), let name = AlarmSoundRenderer.prepare(a) {
            return .named(name)
        }
        if let file = AlarmSound(rawValue: a.sound)?.bundleFile { return .named(file) }
        return .default
    }

    static func authorize() async -> Bool {
        switch AlarmManager.shared.authorizationState {
        case .authorized: return true
        case .denied: return false
        default:
            return (try? await AlarmManager.shared.requestAuthorization()) == .authorized
        }
    }

    /// Stellt den Wecker neu: `at` = einmalig zu diesem Zeitpunkt, sonst nach Uhrzeit/Wiederholung.
    static func schedule(_ a: AlarmItem, at: Date?) async throws {
        cancel(for: a.id)
        let rule: Alarm.Schedule
        if let at {
            rule = .fixed(at)
        } else {
            let days: [Locale.Weekday] = a.repeatDays.sorted().compactMap(weekday)
            rule = .relative(.init(time: .init(hour: a.wakeMinutes / 60, minute: a.wakeMinutes % 60),
                                   repeats: days.isEmpty ? .never : .weekly(days)))
        }
        let stop = AlarmButton(text: LocalizedStringResource("Aus"), textColor: .white, systemImageName: "sun.max")
        let alert: AlarmPresentation.Alert
        if a.snooze {
            alert = AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: a.title), stopButton: stop,
                secondaryButton: AlarmButton(text: LocalizedStringResource("Schlummern"), textColor: .white,
                                             systemImageName: "zzz"),
                secondaryButtonBehavior: .countdown)
        } else {
            alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: a.title), stopButton: stop)
        }
        let presentation = AlarmPresentation(
            alert: alert,
            countdown: AlarmPresentation.Countdown(title: LocalizedStringResource("Schlummern")))
        let attributes = AlarmAttributes(presentation: presentation, metadata: WakeMetadata(label: a.title),
                                         tintColor: Theme.accent)
        let sound = sound(for: a)
        let config = AlarmManager.AlarmConfiguration<WakeMetadata>(
            countdownDuration: a.snooze ? Alarm.CountdownDuration(preAlert: nil, postAlert: Double(a.snoozeMinutes) * 60) : nil,
            schedule: rule,
            attributes: attributes,
            sound: sound)
        let kitID = UUID()
        _ = try await AlarmManager.shared.schedule(id: kitID, configuration: config)
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        map[a.id.uuidString] = kitID.uuidString
        UserDefaults.standard.set(map, forKey: key)
    }

    /// Ersatzwecker aus Version 0.3.66–0.3.76 entfernen
    static func cancelBackup(for id: UUID) {
        var map = UserDefaults.standard.dictionary(forKey: backupKey) as? [String: String] ?? [:]
        if let s = map[id.uuidString], let kit = UUID(uuidString: s) { try? AlarmManager.shared.cancel(id: kit) }
        map[id.uuidString] = nil
        UserDefaults.standard.set(map, forKey: backupKey)
    }

    /// Wecker aus Version 0.3.46 (ein einzelner, anderer Speicher) entfernen
    static func cancelLegacy() {
        for s in UserDefaults.standard.stringArray(forKey: "alarm.ids") ?? [] {
            if let id = UUID(uuidString: s) { try? AlarmManager.shared.cancel(id: id) }
        }
        UserDefaults.standard.removeObject(forKey: "alarm.ids")
    }

    static func cancel(for id: UUID) {
        cancelBackup(for: id)
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        if let s = map[id.uuidString], let kit = UUID(uuidString: s) { try? AlarmManager.shared.cancel(id: kit) }
        map[id.uuidString] = nil
        UserDefaults.standard.set(map, forKey: key)
    }

    private static func weekday(_ d: Int) -> Locale.Weekday? {
        switch d {
        case 1: .sunday
        case 2: .monday
        case 3: .tuesday
        case 4: .wednesday
        case 5: .thursday
        case 6: .friday
        case 7: .saturday
        default: nil
        }
    }
}

// MARK: - Test: spielt der Systemwecker eigene Töne aus Library/Sounds?

/// Stellt in 10 s einen Systemwecker mit einer leise gerechneten Spieluhr unter Library/Sounds.
/// Hört man die leise Spieluhr, kann Suya Lautstärke und eigene Töne an den Systemwecker geben.
@MainActor
final class AlarmSoundTest: ObservableObject {
    static let shared = AlarmSoundTest()
    static let okKey = "alarm.librarySoundsOK"
    @Published private(set) var scheduled: Date?
    @Published var ok: Bool? = UserDefaults.standard.object(forKey: okKey) as? Bool

    func start() async {
        guard #available(iOS 26.0, *), await AlarmBackend.authorize(),
              let src = Bundle.main.url(forResource: "wecker_spieluhr", withExtension: "m4a") else { return }
        let name = "suya-test.caf"
        guard (try? AlarmSoundRenderer.render(src, to: AlarmSoundRenderer.soundsDir.appendingPathComponent(name),
                                              volume: 0.35, ramp: 0)) != nil else { return }
        let stop = AlarmButton(text: LocalizedStringResource("Aus"), textColor: .white, systemImageName: "sun.max")
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: tr("Ton-Test")), stopButton: stop)
        let attributes = AlarmAttributes(presentation: AlarmPresentation(alert: alert),
                                         metadata: WakeMetadata(label: tr("Ton-Test")), tintColor: Theme.accent)
        let at = Date().addingTimeInterval(10)
        let config = AlarmManager.AlarmConfiguration<WakeMetadata>(schedule: .fixed(at), attributes: attributes,
                                                                   sound: .named(name))
        if (try? await AlarmManager.shared.schedule(id: UUID(), configuration: config)) != nil { scheduled = at }
    }

    func answer(_ heard: Bool) {
        ok = heard
        scheduled = nil
        UserDefaults.standard.set(heard, forKey: Self.okKey)
        Task { await SmartAlarm.shared.reapplyAll() }
    }
}

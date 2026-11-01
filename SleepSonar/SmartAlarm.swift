import AlarmKit
import Foundation
import SonarDSP
import SwiftUI

/// Wecker, der im Zeitraum vor der spätesten Weckzeit auf leichten Schlaf wartet.
///
/// - Weckzeit: täglich wiederholter Systemwecker (AlarmKit) zur spätesten Zeit.
/// - Schlafdauer: einmaliger Wecker, spätestens Einschlafen + Dauer.
/// Läuft die Nachtaufnahme, prüft die App im Zeitraum jede Minute die Schlafphase und klingelt
/// früher, sobald du leicht schläfst (nicht Tief, dazu Bewegung) oder schon wach bist.
/// Ohne Aufnahme klingelt der Wecker zur spätesten Zeit wie ein normaler Wecker.
@MainActor
final class SmartAlarm: ObservableObject {
    static let shared = SmartAlarm()

    enum Mode: String, CaseIterable { case time, duration }

    private let d = UserDefaults.standard
    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "alarm.enabled"); settingsChanged() } }
    @Published var mode: Mode { didSet { d.set(mode.rawValue, forKey: "alarm.mode"); settingsChanged() } }
    /// Minuten seit Mitternacht
    @Published var wakeMinutes: Int { didSet { d.set(wakeMinutes, forKey: "alarm.time"); settingsChanged() } }
    @Published var durationMinutes: Int { didSet { d.set(durationMinutes, forKey: "alarm.duration"); settingsChanged() } }
    @Published var windowMinutes: Int { didSet { d.set(windowMinutes, forKey: "alarm.window"); settingsChanged() } }
    @Published private(set) var problem: String?
    /// späteste Weckzeit der laufenden Nacht (nur während der Aufnahme bekannt)
    @Published private(set) var latest: Date?

    private var recordingStart: Date?
    private var onset: Date?
    private var rang = false
    private var restoreAfter: Date?
    private var evaluating = false

    private init() {
        enabled = d.bool(forKey: "alarm.enabled")
        mode = Mode(rawValue: d.string(forKey: "alarm.mode") ?? "") ?? .time
        wakeMinutes = d.object(forKey: "alarm.time") as? Int ?? 7 * 60
        durationMinutes = d.object(forKey: "alarm.duration") as? Int ?? 7 * 60 + 30
        windowMinutes = d.object(forKey: "alarm.window") as? Int ?? 30
    }

    static var isAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    // MARK: Zeiten

    /// Nächstes Vorkommen der Weckzeit nach `from`
    func nextWakeTime(after from: Date = Date()) -> Date {
        let cal = Calendar.current
        var c = cal.dateComponents([.year, .month, .day], from: from)
        c.hour = wakeMinutes / 60
        c.minute = wakeMinutes % 60
        let today = cal.date(from: c) ?? from
        return today > from ? today : cal.date(byAdding: .day, value: 1, to: today) ?? today
    }

    /// Späteste Weckzeit für die aktuelle (oder eine jetzt beginnende) Nacht
    func latestWake(start: Date? = nil) -> Date {
        switch mode {
        case .time:
            return nextWakeTime(after: start ?? Date())
        case .duration:
            // bis zum erkannten Einschlafen: Aufnahmebeginn + 15 min als Annahme
            let base = onset ?? (start ?? recordingStart ?? Date()).addingTimeInterval(15 * 60)
            return base.addingTimeInterval(Double(durationMinutes) * 60)
        }
    }

    // MARK: Einstellungen → Systemwecker

    func settingsChanged() {
        Task { await apply() }
    }

    /// Beim App-Start/Vordergrund: Wecker nach frühem Klingeln wiederherstellen
    func refresh() {
        if let r = restoreAfter, Date() > r { restoreAfter = nil; rang = false }
        settingsChanged()
    }

    private func apply() async {
        guard #available(iOS 26.0, *) else { return }
        guard enabled else {
            AlarmBackend.cancelAll()
            latest = nil
            problem = nil
            return
        }
        guard await AlarmBackend.authorize() else {
            problem = tr("Somnivo darf keine Wecker stellen. Erlaube es unter Einstellungen → Apps → Somnivo → Wecker.")
            return
        }
        problem = nil
        if rang { return }   // heute schon geweckt, Wiederherstellung folgt
        do {
            switch mode {
            case .time:
                try await AlarmBackend.scheduleDaily(hour: wakeMinutes / 60, minute: wakeMinutes % 60)
                latest = recordingStart != nil ? latestWake(start: recordingStart) : nil
            case .duration:
                if let start = recordingStart {
                    let at = latestWake(start: start)
                    latest = at
                    try await AlarmBackend.scheduleOnce(at: at)
                } else {
                    AlarmBackend.cancelAll()   // wird mit der Aufnahme gestellt
                    latest = nil
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
        rang = false
        restoreAfter = nil
        settingsChanged()
    }

    func recordingStopped() {
        recordingStart = nil
        onset = nil
        latest = nil
        if mode == .duration && !rang {
            if #available(iOS 26.0, *) { AlarmBackend.cancelAll() }
        }
    }

    /// Jede Minute während der Aufnahme: Einschlafen erkennen, im Zeitraum auf leichten Schlaf prüfen.
    func tick(seconds: [SleepStaging.Second?], motion: [Double?]) {
        guard enabled, Self.isAvailable, let start = recordingStart else { return }
        let now = Date()
        if let r = restoreAfter, now > r {
            restoreAfter = nil
            rang = false
            settingsChanged()
            return
        }
        guard !rang, !evaluating else { return }
        let needOnset = mode == .duration && onset == nil
        let latest = latestWake(start: start)
        let inWindow = now >= latest.addingTimeInterval(-Double(windowMinutes) * 60) && now < latest
        guard needOnset || inWindow, seconds.count >= 20 * 60 else { return }

        evaluating = true
        Task {
            let result = await Task.detached(priority: .utility) {
                Self.assess(seconds: seconds, motion: motion)
            }.value
            evaluating = false
            if needOnset, let first = result.onsetEpoch {
                onset = start.addingTimeInterval(Double(first) * 30)
                settingsChanged()
                return
            }
            if inWindow, result.light, !rang {
                await ringNow(latest: latest)
            }
        }
    }

    private func ringNow(latest: Date) async {
        guard #available(iOS 26.0, *) else { return }
        rang = true
        do {
            AlarmBackend.cancelAll()
            try await AlarmBackend.scheduleOnce(at: Date().addingTimeInterval(3))
            // Täglicher Wecker kommt nach der spätesten Zeit zurück
            restoreAfter = latest.addingTimeInterval(60)
        } catch {
            rang = false
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

// MARK: - AlarmKit

@available(iOS 26.0, *)
struct WakeMetadata: AlarmMetadata {}

@available(iOS 26.0, *)
@MainActor
enum AlarmBackend {
    private static let key = "alarm.ids"

    static func authorize() async -> Bool {
        switch AlarmManager.shared.authorizationState {
        case .authorized: return true
        case .denied: return false
        default:
            return (try? await AlarmManager.shared.requestAuthorization()) == .authorized
        }
    }

    private static var attributes: AlarmAttributes<WakeMetadata> {
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource("Guten Morgen"),
            stopButton: AlarmButton(text: LocalizedStringResource("Aus"), textColor: .white,
                                    systemImageName: "sun.max"))
        return AlarmAttributes(presentation: AlarmPresentation(alert: alert), metadata: WakeMetadata(),
                               tintColor: Theme.color(.rem))
    }

    static func scheduleDaily(hour: Int, minute: Int) async throws {
        cancelAll()
        let days: [Locale.Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
        let rule = Alarm.Schedule.relative(.init(time: .init(hour: hour, minute: minute),
                                                 repeats: .weekly(days)))
        try await add(rule)
    }

    static func scheduleOnce(at date: Date) async throws {
        cancelAll()
        try await add(.fixed(date))
    }

    private static func add(_ rule: Alarm.Schedule) async throws {
        let id = UUID()
        let config = AlarmManager.AlarmConfiguration<WakeMetadata>(schedule: rule, attributes: attributes)
        _ = try await AlarmManager.shared.schedule(id: id, configuration: config)
        UserDefaults.standard.set([id.uuidString], forKey: key)
    }

    static func cancelAll() {
        for s in UserDefaults.standard.stringArray(forKey: key) ?? [] {
            if let id = UUID(uuidString: s) { try? AlarmManager.shared.cancel(id: id) }
        }
        UserDefaults.standard.set([String](), forKey: key)
    }
}

import BackgroundTasks
import Foundation
import UIKit

/// Geräuscherkennung für ältere Nächte auch im Hintergrund.
///
/// - Neue Nächte werden schon während der Aufnahme ausgewertet (LiveSoundAnalyzer).
/// - Verlässt man die App während einer Auswertung, bittet sie iOS um etwas Extrazeit.
/// - Was dann noch fehlt, erledigt iOS später als Hintergrundaufgabe, sobald das iPhone
///   am Strom hängt und nicht benutzt wird (meist nachts). Fertige Stunden bleiben gespeichert.
@MainActor
enum BackgroundAnalysis {
    static let taskID = "de.nikgro.sleepsonar.sounds"
    private static var extraTime: UIBackgroundTaskIdentifier = .invalid
    private static var activeCount = 0

    /// Muss beim App-Start aufgerufen werden (vor dem Ende von didFinishLaunching).
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            Task { @MainActor in run(task) }
        }
    }

    /// Nächte mit Audio, aber noch ohne Geräusch-Auswertung.
    static func pendingNights() -> [URL] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: NightRecorder.nightsFolder,
                                                                 includingPropertiesForKeys: nil)) ?? []
        let engine = PassiveNightEngine.shared
        return dirs.filter { url in
            url.hasDirectoryPath
                && !(engine.isRunning && engine.folder == url)
                && SoundEventDetector.cached(in: url) == nil
                && !NightExport.audioFiles(in: url).isEmpty
        }
    }

    /// Hintergrundaufgabe anmelden, falls noch etwas zu tun ist.
    static func scheduleIfNeeded() {
        guard !pendingNights().isEmpty else { return }
        let request = BGProcessingTaskRequest(identifier: taskID)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Während einer sichtbaren Auswertung aufrufen: beim Wechsel in den Hintergrund gibt es Extrazeit.
    static func analysisStarted() { activeCount += 1 }
    static func analysisEnded() {
        activeCount = max(0, activeCount - 1)
        if activeCount == 0, extraTime != .invalid {
            UIApplication.shared.endBackgroundTask(extraTime)
            extraTime = .invalid
        }
    }

    static func appWentToBackground() {
        if activeCount > 0, extraTime == .invalid {
            extraTime = UIApplication.shared.beginBackgroundTask(withName: "Geräusche") {
                Task { @MainActor in
                    UIApplication.shared.endBackgroundTask(extraTime)
                    extraTime = .invalid
                }
            }
        }
        scheduleIfNeeded()
    }

    private static func run(_ task: BGProcessingTask) {
        let work = Task { @MainActor in
            for night in pendingNights() {
                if Task.isCancelled { break }
                _ = try? await SoundEventDetector.analyze(folder: night) { _ in }
            }
        }
        task.expirationHandler = { work.cancel() }
        Task { @MainActor in
            _ = await work.result
            task.setTaskCompleted(success: pendingNights().isEmpty)
            scheduleIfNeeded()
        }
    }
}

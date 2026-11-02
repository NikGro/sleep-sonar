import Foundation
import SwiftUI

/// Bildschirmfotos im Simulator (CI-Ablauf „Screens“): Start mit `-suyaScreen <name>` öffnet direkt
/// eine Ansicht, für die Nachtansicht mit einer erfundenen Nacht. Ohne das Argument passiert nichts.
enum DemoScreens {
    /// tonight, alarms, alarmEdit, sounds, soundsPlaying, nights, night, more, onboarding
    static var screen: String? { UserDefaults.standard.string(forKey: "suyaScreen") }

    static var tab: Int {
        switch screen {
        case "alarms", "alarmEdit": 1
        case "sounds", "soundsPlaying": 2
        case "nights", "night": 3
        case "more": 4
        default: 0
        }
    }

    /// Erfundene Nacht (7 h 30) mit Atem, Bewegung und ein paar Geräuschen – nur für Bildschirmfotos.
    static func demoNight() -> URL? {
        let start = Calendar.current.date(bySettingHour: 23, minute: 20, second: 0,
                                          of: Date().addingTimeInterval(-86400)) ?? Date()
        let folder = NightRecorder.nightsFolder
            .appendingPathComponent(DateFormatter.nightName.string(from: start) + "_demo", isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("levels.csv").path) { return folder }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var rng = SystemRandomNumberGenerator()
        var csv = "time,rms_db,peak_db,low_250hz_db,mid_1200hz_db,high_4500hz_db\n"
        let total = 7 * 3600 + 30 * 60
        for t in 0..<total {
            let cycle = Double(t % 5400) / 5400               // 90-min-Zyklen
            let deep = cycle > 0.15 && cycle < 0.45 && t < 4 * 3600
            let rem = cycle > 0.75 && t > 3600
            let awake = t < 900 || (t > 15000 && t < 15240) || t > total - 600
            let period = deep ? 5.0 : rem ? 3.0 : 4.0
            let breath = sin(2 * .pi * Double(t) / period) * (deep ? 3 : 2)
            let jitter = Double.random(in: -1...1, using: &rng) * (rem ? 2.5 : 0.8)
            var high = -84 + breath + jitter
            if awake && Int.random(in: 0..<4, using: &rng) == 0 { high += 22 }
            let rms = -78 + breath * 0.6 + jitter * 0.5 + (awake ? 4 : 0)
            let line = [rms, rms + 18, rms - 2, rms - 9, high].map { String(format: "%.1f", $0) }
            csv += iso.string(from: start.addingTimeInterval(Double(t))) + "," + line.joined(separator: ",") + "\n"
        }
        try? csv.write(to: folder.appendingPathComponent("levels.csv"), atomically: true, encoding: .utf8)
        try? SoundEventDetector.save([
            SoundEvent(kind: .snoring, start: 7200, end: 7238, confidence: 0.92),
            SoundEvent(kind: .snoring, start: 9100, end: 9121, confidence: 0.78),
            SoundEvent(kind: .snoring, start: 12000, end: 12010, confidence: 0.64),
            SoundEvent(kind: .coughing, start: 15100, end: 15104, confidence: 0.81),
        ], in: folder)
        return folder
    }
}

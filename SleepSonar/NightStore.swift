import Foundation

/// Ablage der Nächte: je Nacht ein Ordner unter Documents/Nights, benannt nach dem Start („yyyy-MM-dd_HH-mm“).
enum NightStore {
    /// Ordner aller Nächte – nicht im iCloud- oder Computer-Backup: Ton und Ausschnitte bleiben auf diesem iPhone
    static var nightsFolder: URL {
        var url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nights", isDirectory: true)
        if !backupExcluded {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            if (try? url.setResourceValues(values)) != nil { backupExcluded = true }
        }
        return url
    }
    nonisolated(unsafe) private static var backupExcluded = false
}

extension DateFormatter {
    static let nightName: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        return f
    }()
}

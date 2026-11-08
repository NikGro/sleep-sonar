import Foundation

/// Ablage der Nächte: je Nacht ein Ordner unter Documents/Nights, benannt nach dem Start („yyyy-MM-dd_HH-mm“).
enum NightStore {
    static var nightsFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nights", isDirectory: true)
    }
}

extension DateFormatter {
    static let nightName: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        return f
    }()
}

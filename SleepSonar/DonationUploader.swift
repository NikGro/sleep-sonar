import AVFoundation
import CryptoKit
import DeviceCheck
import Foundation
import HealthKit
import SonarDSP

/// Überträgt gespendete Nächte an den Suya-Server (suya.ng-lab.de) – nur mit Einwilligung, nur im WLAN.
///
/// Gesendet wird kein Ton, sondern das Spektrogramm, mit dem auch trainiert wird (Roh-Log-Mel, 64 Bänder,
/// 10 Bilder je Sekunde), die Lautstärke je Sekunde, die Schlafphasen der Watch je 30 s (ohne Datum, nur ab
/// Aufnahmebeginn gezählt) und die Zeiten eigener Schlafklänge. Dazu App-Version und iPhone-Modell.
///
/// Paket (zlib/deflate ohne Kopf, Python: `zlib.decompress(b, -15)`):
///   "SUYA" · Version (1 Byte) · Länge des JSON-Kopfs (UInt32 LE) · JSON · Mel (Float16 LE, Bild für Bild je
///   64 Bänder) · Lautstärke (Float16 LE, dB je Sekunde)
@MainActor
final class DonationUploader {
    static let shared = DonationUploader()
    static let server = URL(string: "https://suya.ng-lab.de")!
    /// nur Nächte ab dieser Länge (wie im Einwilligungstext)
    static let minSeconds: TimeInterval = 5 * 3600
    /// so lange auf Watch-Daten warten (die Watch gleicht manchmal erst später ab)
    static let watchWait: TimeInterval = 3 * 86400

    private var running = false
    private let store = HKHealthStore()
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.allowsExpensiveNetworkAccess = false     // kein Mobilfunk
        c.allowsConstrainedNetworkAccess = false   // kein Datensparmodus
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 30 * 60
        return URLSession(configuration: c)
    }()

    /// Beim Öffnen der App, nach dem Ende einer Nacht und nach Zustimmung/Löschanfrage aufrufen.
    func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        let donation = DataDonation.shared
        guard let donor = donation.donorID else { return }
        let key = donation.secretKey

        // 1) offene Löschanfrage zuerst
        if donation.deletionRequested != nil, !donation.deletionSent {
            if await sendDeletion(donor: donor, key: key) { donation.markDeletionSent() }
            return
        }
        guard donation.state == .granted else { return }
        guard !PassiveNightEngine.shared.isRunning else { return }   // nachts nicht rechnen
        await AppAttestClient.registerIfPossible(donor: donor, key: key)

        // 2) Nächte der letzten zwei Wochen, die noch nicht gespendet wurden
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: NightRecorder.nightsFolder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let engine = PassiveNightEngine.shared
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        for folder in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where folder.hasDirectoryPath {
            if engine.isRunning && engine.folder == folder { continue }
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            guard created > cutoff, var state = NightDonationState.load(folder), !state.done else { continue }
            // nur Nächte, die nach der Zustimmung aufgenommen wurden
            if let since = donation.date, created < since { continue }
            switch await upload(folder: folder, state: &state, donor: donor, key: key) {
            case .sent:
                state.sent = Date(); state.save(folder)
                donation.countUpload()
            case .skip(let why):
                state.skipped = why; state.save(folder)
            case .later:
                continue
            case .stop:
                return
            }
        }
    }

    private enum Outcome { case sent, skip(String), later, stop }

    private func upload(folder: URL, state: inout NightDonationState, donor: String, key: String) async -> Outcome {
        let files = NightExport.audioFiles(in: folder)
        guard !files.isEmpty else { return .skip("kein Ton mehr") }
        guard let start = Self.audioStart(folder) else { return .skip("ohne Startzeit") }
        let seconds = files.reduce(0.0) { $0 + ((try? audioSeconds($1)) ?? 0) }
        guard seconds >= Self.minSeconds else { return .skip("kürzer als 5 Stunden") }
        let epochs = Int(seconds / 30)

        // Watch-Phasen je 30-s-Epoche ab Aufnahmebeginn
        guard let watch = await watchStages(start: start, epochs: epochs) else {
            return Date().timeIntervalSince(start) > Self.watchWait ? .skip("keine Watch-Daten") : .later
        }
        guard watch.filter({ $0 >= 0 }).count >= 240 else {
            return Date().timeIntervalSince(start) > Self.watchWait ? .skip("zu wenig Watch-Daten") : .later
        }

        // Paket bauen (rechnet das Spektrogramm, dauert etwa so lange wie die Modell-Auswertung)
        let night = state.id
        let built = await Task.detached(priority: .utility) { () -> URL? in
            try? Self.buildPackage(folder: folder, files: files, watch: watch)
        }.value
        guard let packageURL = built else { return .later }
        defer { try? FileManager.default.removeItem(at: packageURL) }
        guard let body = try? Data(contentsOf: packageURL, options: .mappedIfSafe) else { return .later }
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()

        var request = URLRequest(url: Self.server.appendingPathComponent("api/spende/nacht"))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(donor, forHTTPHeaderField: "X-Spender")
        request.setValue(key, forHTTPHeaderField: "X-Schluessel")
        request.setValue(night, forHTTPHeaderField: "X-Nacht")
        for (k, v) in await AppAttestClient.assertionHeaders(kind: "nacht", donor: donor, night: night, bodyHash: hash) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        guard let (_, response) = try? await session.upload(for: request, fromFile: packageURL),
              let code = (response as? HTTPURLResponse)?.statusCode else { return .stop }   // kein WLAN o. Ä.
        switch code {
        case 201: return .sent
        case 429, 503, 507: return .stop     // Server-Grenzen: später wieder
        case 403: return .stop               // Schlüssel oder App Attest passt nicht
        default: return .later
        }
    }

    private func sendDeletion(donor: String, key: String) async -> Bool {
        var request = URLRequest(url: Self.server.appendingPathComponent("api/spende/loeschen"))
        request.httpMethod = "POST"
        request.setValue(donor, forHTTPHeaderField: "X-Spender")
        request.setValue(key, forHTTPHeaderField: "X-Schluessel")
        for (k, v) in await AppAttestClient.assertionHeaders(kind: "loeschen", donor: donor, night: "", bodyHash: "") {
            request.setValue(v, forHTTPHeaderField: k)
        }
        // Löschen auch über Mobilfunk
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Schlafphasen der Watch (nicht Suyas eigene Einträge): 0 Wach, 1 REM, 2 Kern, 3 Tief, −1 unbekannt.
    /// Lücken zwischen der ersten und letzten Phase zählen als Wach (wie im Training).
    private func watchStages(start: Date, epochs: Int) async -> [Int]? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let end = start.addingTimeInterval(Double(epochs) * 30)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        guard let samples = try? await HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]).result(for: store) else { return nil }
        let own = Bundle.main.bundleIdentifier ?? ""
        var out = [Int](repeating: -1, count: epochs)
        for s in samples where s.sourceRevision.source.bundleIdentifier != own {
            let code: Int
            switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
            case .awake: code = 0
            case .asleepREM: code = 1
            case .asleepCore: code = 2
            case .asleepDeep: code = 3
            default: continue
            }
            for e in 0..<epochs {
                let mid = start.addingTimeInterval(Double(e) * 30 + 15)
                if mid >= s.startDate && mid < s.endDate { out[e] = code }
            }
        }
        guard let first = out.firstIndex(where: { $0 >= 0 }), let last = out.lastIndex(where: { $0 >= 0 }) else { return nil }
        for e in first...last where out[e] < 0 { out[e] = 0 }
        return out
    }

    /// Beginn des Tons (erste Zeile in audio_index.csv), sonst Beginn der Aufnahme.
    nonisolated static func audioStart(_ folder: URL) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let text = try? String(contentsOf: folder.appendingPathComponent("audio_index.csv"), encoding: .utf8) {
            let lines = text.split(separator: "\n")
            if lines.count > 1, let s = lines[1].split(separator: ",").last, let d = iso.date(from: String(s)) { return d }
        }
        if let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let s = obj["start"] as? String { return iso.date(from: s) }
        return nil
    }

    nonisolated static func deviceModel() -> String {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    nonisolated static func buildPackage(folder: URL, files: [URL], watch: [Int]) throws -> URL {
        let frames = try NightModel.melFrames(files: files)
        let epochs = min(frames.count / LogMel.framesPerEpoch, watch.count)
        let used = epochs * LogMel.framesPerEpoch

        // Lautstärke je Sekunde (levels.csv: time,rms_db,…)
        var levels: [Float] = []
        if let text = try? String(contentsOf: folder.appendingPathComponent("levels.csv"), encoding: .utf8) {
            for line in text.split(separator: "\n").dropFirst() {
                let cols = line.split(separator: ",", omittingEmptySubsequences: false)
                if cols.count > 1, let v = Float(cols[1]) { levels.append(v) }
            }
        }
        let sounds = NightModel.soundFrames(folder).map { [$0.lowerBound, $0.upperBound] }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let head: [String: Any] = [
            "format": 1, "app": "\(version) (\(build))", "device": deviceModel(),
            "sampleRate": LogMel.sampleRate, "nFFT": LogMel.nFFT, "hop": LogMel.hop,
            "bands": LogMel.bands, "framesPerSecond": 10, "epochSeconds": 30,
            "frames": used, "levels": levels.count, "watch": Array(watch.prefix(epochs)),
            "soundFrames": sounds, "model": NightModel.version,
        ]
        let json = try JSONSerialization.data(withJSONObject: head, options: [.sortedKeys])

        var raw = Data("SUYA".utf8)
        raw.append(1)
        var n = UInt32(json.count).littleEndian
        raw.append(Data(bytes: &n, count: 4))
        raw.append(json)
        raw.reserveCapacity(raw.count + used * LogMel.bands * 2 + levels.count * 2)
        var half = [Float16](repeating: 0, count: LogMel.bands)
        for f in frames.prefix(used) {
            for b in 0..<LogMel.bands { half[b] = Float16(f[b]) }
            half.withUnsafeBytes { raw.append(contentsOf: $0) }
        }
        let lv = levels.map { Float16($0) }
        lv.withUnsafeBytes { raw.append(contentsOf: $0) }

        let packed = try (raw as NSData).compressed(using: .zlib) as Data
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spende-\(UUID().uuidString).suya")
        try packed.write(to: url)
        return url
    }
}

/// Länge einer Audiodatei in Sekunden.
private func audioSeconds(_ url: URL) throws -> Double {
    let f = try AVAudioFile(forReading: url)
    return Double(f.length) / f.fileFormat.sampleRate
}

/// Spendenstand einer Nacht (donation.json im Ordner der Nacht): zufällige Nacht-Kennung, gesendet/übersprungen.
struct NightDonationState: Codable {
    var id: String
    var sent: Date?
    var skipped: String?
    var done: Bool { sent != nil || skipped != nil }

    static func load(_ folder: URL) -> NightDonationState? {
        let url = folder.appendingPathComponent("donation.json")
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Self.self, from: data) { return s }
        return NightDonationState(id: UUID().uuidString.lowercased())
    }

    func save(_ folder: URL) {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: folder.appendingPathComponent("donation.json"), options: .atomic)
        }
    }
}

/// Apples App Attest: Der Server erkennt, dass Anfragen von der echten, unveränderten Suya-App auf einem echten
/// iPhone kommen. Einmal je Installation wird ein Schlüssel von Apple bestätigt, danach jede Anfrage damit signiert.
/// Geht das nicht (z. B. selbst signierte Testversion), sendet die App ohne – der Server entscheidet, ob er das annimmt.
@MainActor
enum AppAttestClient {
    private static let d = UserDefaults.standard
    private static var keyID: String? { d.string(forKey: "attest.keyID") }
    private static var registered: Bool { d.bool(forKey: "attest.registered") }

    private static func challenge() async -> String? {
        let url = DonationUploader.server.appendingPathComponent("api/attest/challenge")
        guard let (data, r) = try? await URLSession.shared.data(from: url), (r as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["challenge"] as? String
    }

    private static func serverWantsAttest() async -> Bool {
        let url = DonationUploader.server.appendingPathComponent("api/status")
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj["attest"] as? Bool ?? false
    }

    static func registerIfPossible(donor: String, key: String) async {
        let service = DCAppAttestService.shared
        guard !registered, service.isSupported, await serverWantsAttest() else { return }
        do {
            let id = try await service.generateKey()
            guard let c = await challenge(), let cBytes = Data(base64Encoded: c) else { return }
            let attestation = try await service.attestKey(id, clientDataHash: Data(SHA256.hash(data: cBytes)))
            var request = URLRequest(url: DonationUploader.server.appendingPathComponent("api/attest/register"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(donor, forHTTPHeaderField: "X-Spender")
            request.setValue(key, forHTTPHeaderField: "X-Schluessel")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "keyId": id, "attestation": attestation.base64EncodedString(), "challenge": c])
            let (_, r) = try await URLSession.shared.data(for: request)
            if (r as? HTTPURLResponse)?.statusCode == 201 {
                d.set(id, forKey: "attest.keyID")
                d.set(true, forKey: "attest.registered")
            }
        } catch {
            // nicht unterstützt oder abgelehnt: ohne App Attest weiter
        }
    }

    /// Kopfzeilen X-Assertion/X-Challenge für eine Anfrage (leer, wenn diese Installation nicht registriert ist).
    static func assertionHeaders(kind: String, donor: String, night: String, bodyHash: String) async -> [String: String] {
        guard registered, let id = keyID, let c = await challenge() else { return [:] }
        let clientData = Data("\(kind)|\(c)|\(donor)|\(night)|\(bodyHash)".utf8)
        guard let a = try? await DCAppAttestService.shared.generateAssertion(
            id, clientDataHash: Data(SHA256.hash(data: clientData))) else { return [:] }
        return ["X-Assertion": a.base64EncodedString(), "X-Challenge": c]
    }

    /// nach einer Löschung beim Server: neuer Spender, neuer Schlüssel
    static func reset() {
        d.removeObject(forKey: "attest.keyID")
        d.removeObject(forKey: "attest.registered")
    }
}

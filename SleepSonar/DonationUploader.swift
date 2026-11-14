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
final class DonationUploader: ObservableObject {
    static let shared = DonationUploader()
    /// Nacht, an der gerade gearbeitet wird (Spektrogramm oder Übertragung) – für den Spinner in der Detailansicht
    @Published private(set) var active: URL?
    /// Fortschritt der aktiven Nacht: Phase (Text) und 0 … 1
    @Published private(set) var phase: String?
    @Published private(set) var progress: Double?

    private func report(_ phase: String?, _ p: Double?) { self.phase = phase; self.progress = p }
    static var server: URL { SuyaAPI.server }
    private let api: SuyaAPI
    /// nur Nächte ab dieser Länge (wie im Einwilligungstext)
    static let minSeconds: TimeInterval = 5 * 3600
    /// so lange auf Watch-Daten warten (die Watch gleicht manchmal erst später ab)
    static let watchWait: TimeInterval = 3 * 86400

    private var running = false
    private let store = HKHealthStore()

    init(api: SuyaAPI = SuyaAPI()) { self.api = api }

    /// Beim Öffnen der App, nach dem Ende einer Nacht und nach Zustimmung/Löschanfrage aufrufen.
    /// nach bestätigter Löschung: Spendenstand aller Nächte vergessen. Ältere Nächte gelten danach als
    /// „vor der Zustimmung“ und lassen sich nur von Hand erneut spenden.
    static func forgetSentNights() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: NightStore.nightsFolder, includingPropertiesForKeys: nil)) ?? []
        for folder in dirs where folder.hasDirectoryPath {
            try? FileManager.default.removeItem(at: Night(folder).url(.donation))
        }
    }

    /// Darf weiter gespendet werden? Vor jeder Nacht und jedem Teil geprüft: ein Widerruf oder eine
    /// Löschanfrage stoppt eine laufende Übertragung sofort.
    private var mayDonate: Bool {
        let d = DataDonation.shared
        return d.state == .granted && d.deletionRequested == nil
    }

    func run() async {
        guard !running else { return }
        running = true
        let d = DataDonation.shared
        let deletionPending = d.deletionRequested != nil && !d.deletionSent
        await runOnce()
        running = false
        // während des Laufs widerrufen und Löschung verlangt: gleich senden, nicht erst beim nächsten Öffnen
        // (nur einmal – ging sie schon in diesem Lauf nicht raus, folgt der nächste Versuch beim nächsten Öffnen)
        if !deletionPending, d.deletionRequested != nil, !d.deletionSent { await run() }
    }

    private func runOnce() async {
        let donation = DataDonation.shared
        guard let id = donation.donorID else { return }
        let donor = SuyaAPI.Donor(id: id, key: donation.secretKey)

        // 1) offene Löschanfrage zuerst
        if donation.deletionRequested != nil, !donation.deletionSent {
            switch await sendDeletion(donor) {
            case 200: donation.markDeletionSent()
            case 409: donation.markDeletionImpossible()   // Schlüssel passt nicht (anderes iPhone): Weg über das Impressum
            default: break                                 // offline o. Ä.: beim nächsten Mal
            }
            return
        }
        guard donation.state == .granted else { return }
        guard !PassiveNightEngine.shared.isRunning else { return }   // nachts nicht rechnen
        await AppAttestClient.registerIfPossible(donor, api: api)

        // 2) Nächte der letzten zwei Wochen: erst umwandeln (Spektrogramm sichern, Ton löschen), dann senden
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: NightStore.nightsFolder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let engine = PassiveNightEngine.shared
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        for folder in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where folder.hasDirectoryPath {
            guard mayDonate else { return }
            if engine.isRunning && engine.folder == folder { continue }
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            guard created > cutoff, var state = NightDonationState.load(folder), !state.done else { continue }
            // nur Nächte, die nach der Zustimmung aufgenommen wurden
            if let since = donation.date, created < since, state.manual != true {
                state.skipped = NightDonationState.beforeConsent; state.save(folder); continue
            }
            active = folder
            defer { active = nil; report(nil, nil) }
            if !Self.hasMel(folder), let why = await prepare(folder: folder) {
                state.skipped = why; state.save(folder); continue
            }
            switch await upload(folder: folder, state: &state, donor: donor) {
            case .sent:
                state.sent = Date(); state.waiting = nil; state.save(folder)
                donation.countUpload()
            case .skip(let why):
                state.skipped = why; state.waiting = nil; state.save(folder)
            case .later(let why):
                state.waiting = why; state.save(folder)
            case .stop:
                return
            }
        }
        NightFinisher.cleanupMel()
    }

    private enum Outcome { case sent, skip(String), later(String), stop }

    /// „Datenspende erneut senden“ (gedrückt halten auf eine Nacht): Stand zurücksetzen und gleich senden.
    func resend(_ folder: URL) async {
        guard var state = NightDonationState.existing(folder) ?? NightDonationState.load(folder) else { return }
        let wasSent = state.sent != nil
        state.sent = nil; state.skipped = nil; state.waiting = nil; state.manual = true
        state.save(folder)
        let donation = DataDonation.shared
        guard donation.state == .granted, let donor = donation.donorID else { return }
        // läuft gerade die automatische Spende, danach dran sein (höchstens 15 min warten)
        for _ in 0..<1800 where running { try? await Task.sleep(for: .milliseconds(500)) }
        guard !running else { return }
        state = NightDonationState.existing(folder) ?? state
        if state.sent != nil { return }        // inzwischen von der automatischen Spende erledigt
        running = true
        active = folder
        defer { running = false; active = nil; report(nil, nil) }
        if !Self.hasMel(folder), let why = await prepare(folder: folder) {
            state.skipped = why; state.save(folder); return
        }
        switch await upload(folder: folder, state: &state, donor: SuyaAPI.Donor(id: donor, key: donation.secretKey)) {
        case .sent: state.sent = Date(); state.waiting = nil; if !wasSent { donation.countUpload() }
        case .skip(let why): state.skipped = why; state.waiting = nil
        case .later(let why): state.waiting = why
        case .stop: break
        }
        if FileManager.default.fileExists(atPath: folder.path) { state.save(folder) }
        if donation.deletionRequested != nil, !donation.deletionSent {
            Task { await self.run() }   // nach dem Ende von `running` die Löschung senden
        }
    }

    /// Kann diese Nacht (erneut) gespendet werden? Spektrogramm oder Ton muss noch da sein.
    nonisolated static func canResend(_ folder: URL) -> Bool {
        hasMel(folder) || !Night(folder).audioFiles.isEmpty
    }

    /// Menütext beim Gedrückthalten: schon gespendet → erneut, sonst nachträglich spenden
    nonisolated static func donateLabel(_ folder: URL) -> String {
        NightDonationState.existing(folder)?.sent != nil ? tr("Datenspende erneut senden") : tr("Diese Nacht spenden")
    }

    /// Spektrogramm-Datei der Nacht (Roh-Log-Mel, Float16, Bild für Bild je 64 Bänder)
    nonisolated static func melURL(_ folder: URL) -> URL { Night(folder).url(.mel) }
    nonisolated static func hasMel(_ folder: URL) -> Bool { FileManager.default.fileExists(atPath: melURL(folder).path) }

    /// Umwandeln: Spektrogramm sichern (den Ton löscht NightFinisher nach 24 Stunden).
    /// Gibt einen Grund zurück, wenn die Nacht nicht gespendet werden kann.
    func prepare(folder: URL) async -> String? {
        let files = Night(folder).audioFiles
        guard !files.isEmpty else { return NightDonationState.noAudio }
        let seconds = files.reduce(0.0) { $0 + ((try? audioSeconds($1)) ?? 0) }
        guard seconds >= Self.minSeconds else { return NightDonationState.short }
        report(tr("Klangbild wird erstellt"), 0)
        let ok = await Task.detached(priority: .utility) {
            Self.writeMel(folder: folder, files: files) { p in Task { @MainActor in DonationUploader.shared.report(tr("Klangbild wird erstellt"), p) } }
        }.value
        _ = ok   // klappt es nicht, beim nächsten Mal wieder; den Ton löscht NightFinisher nach 24 h
        return nil
    }

    /// Spektrogramm (Roh-Log-Mel, Float16) der ganzen Nacht in die Datei schreiben
    nonisolated static func writeMel(folder: URL, files: [URL], progress: @escaping (Double) -> Void = { _ in }) -> Bool {
        guard let frames = try? NightModel.melFrames(files: files, progress: progress) else { return false }
        var data = Data(capacity: frames.count * LogMel.bands * 2)
        var half = [Float16](repeating: 0, count: LogMel.bands)
        for f in frames {
            for b in 0..<LogMel.bands { half[b] = Float16(f[b]) }
            half.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        return data.save(to: melURL(folder), "Spektrogramm")
    }

    private func upload(folder: URL, state: inout NightDonationState, donor: SuyaAPI.Donor) async -> Outcome {
        guard Self.hasMel(folder) else { return .later(NightDonationState.converting) }
        guard let start = Night(folder).audioStart else { return .skip(NightDonationState.noStart) }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: Self.melURL(folder).path)[.size] as? Int) ?? 0
        let epochs = bytes / 2 / LogMel.bands / LogMel.framesPerEpoch
        guard Double(epochs) * 30 >= Self.minSeconds else { return .skip(NightDonationState.short) }
        // ältere Aufnahme mit Aussetzern: Ton und Watch-Phasen lägen gegeneinander verschoben
        let untracked = await Task.detached(priority: .utility) { NightModel.untrackedGapSeconds(folder) }.value
        guard untracked < 60 else { return .skip(NightDonationState.gaps) }

        // Watch-Phasen je 30-s-Epoche ab Aufnahmebeginn
        guard let watch = await watchStages(start: start, epochs: epochs) else {
            return Date().timeIntervalSince(start) > Self.watchWait ? .skip(NightDonationState.noWatch) : .later(NightDonationState.waitWatch)
        }
        guard watch.filter({ $0 >= 0 }).count >= 240 else {
            return Date().timeIntervalSince(start) > Self.watchWait ? .skip(NightDonationState.noWatch) : .later(NightDonationState.waitWatch)
        }

        let night = state.id
        report(tr("Wird verpackt"), nil)
        let built = await Task.detached(priority: .utility) { () -> URL? in
            try? Self.buildPackage(folder: folder, watch: watch)
        }.value
        guard let packageURL = built else { return .later(NightDonationState.converting) }
        defer { try? FileManager.default.removeItem(at: packageURL) }
        guard let body = try? Data(contentsOf: packageURL, options: .mappedIfSafe) else { return .later(NightDonationState.converting) }
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()

        // in Teilen à 4 MB senden, jedes Teil bis zu 3-mal (robust bei wackligem WLAN); der Server setzt zusammen
        let partSize = 4 * 1024 * 1024
        let count = max(1, (body.count + partSize - 1) / partSize)
        var lastCode = 0
        var keyMismatch = false
        var networkError: URLError?
        var delivered = Set<Int>()   // Teile, die der Server schon hat (bleiben dort 24 h liegen)
        // bei Unterbrechung weiter versuchen, solange die App offen ist: 8 Runden mit wachsender Pause (gut 6 min)
        let pauses: [Double] = [0, 5, 10, 20, 30, 60, 90, 120]
        report(tr("Wird übertragen"), 0)
        rounds: for pause in pauses {
            if pause > 0 { try? await Task.sleep(for: .seconds(pause)) }
            networkError = nil
            for i in 0..<count where !delivered.contains(i) {
                // widerrufen, Löschung verlangt oder Nacht gelöscht: sofort aufhören
                guard mayDonate, FileManager.default.fileExists(atPath: folder.path) else { return .stop }
                let chunk = body.subdata(in: (i * partSize)..<min(body.count, (i + 1) * partSize))
                // App Attest: jede Teil-Anfrage mit eigener Assertion über das ganze Paket
                let assertion = await AppAttestClient.assertionHeaders(kind: "nacht", donor: donor.id, night: night, bodyHash: hash)
                do {
                    let res = try await api.uploadPart(donor, night: night, index: i, count: count, totalHash: hash,
                                                       data: chunk, assertion: assertion)
                    lastCode = res.status
                    keyMismatch = res.keyMismatch
                    if lastCode == 201 { break rounds }
                    if lastCode == 202 { delivered.insert(i); report(tr("Wird übertragen"), Double(delivered.count) / Double(count)); continue }
                    if [403, 429, 503, 507].contains(lastCode) { break rounds }
                    Log.donation.notice("Teil \(i): HTTP \(lastCode)")
                    continue rounds          // anderer Fehler: nächste Runde
                } catch let e as URLError {
                    networkError = e
                    // nur Mobilfunk oder Datensparmodus: Warten lohnt nicht
                    if e.networkUnavailableReason == .expensive || e.networkUnavailableReason == .constrained { break rounds }
                    continue rounds
                } catch {
                    continue rounds
                }
            }
            if delivered.count == count { break }
        }
        if lastCode == 201 { return .sent }
        if let e = networkError {
            // wirklich kein WLAN (nur Mobilfunk) oder Datensparmodus – sonst nur unterbrochen
            let why: String
            switch e.networkUnavailableReason {
            case .expensive: why = NightDonationState.waitWifi
            case .constrained: why = NightDonationState.lowData
            default: why = NightDonationState.interrupted
            }
            state.waiting = why; state.save(folder)
            return .stop
        }
        switch lastCode {
        case 429, 503, 507: state.waiting = NightDonationState.waitServer; state.save(folder); return .stop
        case 403:
            // Server kennt diesen Schlüssel nicht (z. B. Nummer aus einem Backup): neue Nummer, beim nächsten Mal neu
            if keyMismatch { DataDonation.shared.replaceDonorID() }
            Log.donation.error("Spende abgelehnt (403)")
            state.waiting = NightDonationState.rejected; state.save(folder); return .stop
        default: return .later(NightDonationState.interrupted)
        }
    }

    /// HTTP-Status der Löschanfrage (0 = keine Verbindung, 409 = Schlüssel passt nicht zur Nummer)
    private func sendDeletion(_ donor: SuyaAPI.Donor) async -> Int {
        let assertion = await AppAttestClient.assertionHeaders(kind: "loeschen", donor: donor.id, night: "", bodyHash: "")
        do {
            let res = try await api.deleteDonations(donor, assertion: assertion)
            // 403 heißt Schlüssel falsch oder Echtheitsprüfung fehlgeschlagen – nur Ersteres ist endgültig
            if res.keyMismatch { return 409 }
            if res.status != 200 { Log.donation.error("Löschen: HTTP \(res.status)") }
            return res.status
        } catch {
            Log.donation.notice("Löschen: \(error.localizedDescription, privacy: .public)")
            return 0
        }
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

    nonisolated static func buildPackage(folder: URL, watch: [Int]) throws -> URL {
        let mel = try Data(contentsOf: melURL(folder), options: .mappedIfSafe)
        let total = mel.count / 2 / LogMel.bands
        let epochs = min(total / LogMel.framesPerEpoch, watch.count)
        let used = epochs * LogMel.framesPerEpoch

        // Lautstärke je Sekunde (levels.csv: time,rms_db,…)
        let levels = Night(folder).column(.levels, 1)
        let sounds = NightModel.soundFrames(folder).map { [$0.lowerBound, $0.upperBound] }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let head: [String: Any] = [
            "format": 1, "app": "\(version) (\(build))", "device": Device.model,
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
        raw.append(mel.prefix(used * LogMel.bands * 2))   // schon Float16, Bild für Bild
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

/// Spendenstand einer Nacht (donation.json im Ordner der Nacht): zufällige Nacht-Kennung, gesendet/übersprungen,
/// worauf gerade gewartet wird. Gründe als Kürzel (Text: `reasonText`).
struct NightDonationState: Codable {
    var id: String
    var sent: Date?
    var skipped: String?
    var waiting: String?
    /// von Hand gespendet (z. B. eine Nacht von vor der Zustimmung): automatisch weiter versuchen
    var manual: Bool?
    var done: Bool { sent != nil || skipped != nil }

    static let beforeConsent = "vorZustimmung", short = "kurz", noAudio = "ohneTon", noStart = "ohneStart",
               noWatch = "ohneWatch", waitWatch = "warteWatch", waitWifi = "warteWLAN", waitServer = "warteServer",
               rejected = "abgelehnt", converting = "umwandeln", interrupted = "unterbrochen", lowData = "datensparen",
               gaps = "aussetzer"

    static func reasonText(_ code: String) -> String {
        switch code {
        case beforeConsent: tr("Vor deiner Zustimmung aufgenommen – wird nicht gespendet.")
        case short: tr("Kürzer als 5 Stunden – wird nicht gespendet.")
        case noAudio: tr("Ohne Ton aufgenommen oder schon gelöscht – wird nicht gespendet.")
        case noStart: tr("Ohne Startzeit – wird nicht gespendet.")
        case noWatch: tr("Ohne Schlafphasen der Watch – wird nicht gespendet.")
        case waitWatch: tr("Wartet auf die Schlafphasen der Watch.")
        case waitWifi: tr("Wird gesendet, sobald das iPhone im WLAN ist.")
        case waitServer: tr("Der Server nimmt gerade nichts an. Suya versucht es später wieder.")
        case rejected: tr("Der Server hat die Spende abgelehnt.")
        case interrupted: tr("Die Übertragung wurde unterbrochen. Suya versucht es beim nächsten Öffnen wieder.")
        case lowData: tr("Der Datensparmodus ist an. Ohne ihn wird im WLAN gesendet.")
        case gaps: tr("Die Aufnahme hatte Aussetzer – wird nicht gespendet.")
        default: tr("Wird vorbereitet.")
        }
    }

    static func load(_ folder: URL) -> NightDonationState? {
        let url = Night(folder).url(.donation)
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Self.self, from: data) { return s }
        return NightDonationState(id: UUID().uuidString.lowercased())
    }

    /// nur lesen, ohne eine neue Kennung zu erfinden (für die Anzeige)
    static func existing(_ folder: URL) -> NightDonationState? {
        guard let data = try? Data(contentsOf: Night(folder).url(.donation)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save(_ folder: URL) {
        guard Night(folder).isPresent, let data = try? JSONEncoder().encode(self) else { return }
        data.save(to: Night(folder).url(.donation), "Spendenstand")
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

    static func registerIfPossible(_ donor: SuyaAPI.Donor, api: SuyaAPI) async {
        let service = DCAppAttestService.shared
        guard !registered, service.isSupported, await api.attestEnabled() else { return }
        do {
            let id = try await service.generateKey()
            guard let c = await api.challenge(), let cBytes = Data(base64Encoded: c) else { return }
            let attestation = try await service.attestKey(id, clientDataHash: Data(SHA256.hash(data: cBytes)))
            let res = try await api.registerAttestation(donor, keyID: id, attestation: attestation, challenge: c)
            if res.status == 201 {
                d.set(id, forKey: "attest.keyID")
                d.set(true, forKey: "attest.registered")
            } else {
                Log.donation.notice("App Attest abgelehnt: HTTP \(res.status) \(res.code ?? "", privacy: .public)")
            }
        } catch {
            // nicht unterstützt (z. B. selbst signierte Version): ohne App Attest weiter
            Log.donation.notice("App Attest: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Kopfzeilen X-Assertion/X-Challenge für eine Anfrage (leer, wenn diese Installation nicht registriert ist).
    static func assertionHeaders(kind: String, donor: String, night: String, bodyHash: String) async -> [String: String] {
        guard registered, let id = keyID, let c = await SuyaAPI().challenge() else { return [:] }
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

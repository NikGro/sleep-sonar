import Foundation

/// Schnittstelle zum Suya-Server (suya.ng-lab.de). Einzige Stelle mit Pfaden, Köpfen und Fehlercodes.
/// Die Übertragung (`transport`) ist austauschbar, damit sich die Abläufe ohne Netz prüfen lassen.
struct SuyaAPI: Sendable {
    static let server = URL(string: "https://suya.ng-lab.de")!

    /// Wer spendet: Nummer (in der App sichtbar) und geheimer Schlüssel der Installation
    struct Donor: Sendable, Equatable {
        let id: String
        let key: String
    }

    struct Response: Sendable {
        let status: Int
        let json: [String: any Sendable]
        /// maschinenlesbarer Fehler des Servers, z. B. „key_mismatch“
        var code: String? { json["code"] as? String }
        /// Schlüssel gehört nicht zu dieser Nummer (z. B. Nummer aus dem Backup eines anderen iPhones)
        var keyMismatch: Bool {
            status == 403 && (code == "key_mismatch" || (json["fehler"] as? String) == "Schlüssel passt nicht")
        }
    }

    enum Network: Sendable {
        /// Spenden: nur WLAN ohne Datensparmodus
        case wifiOnly
        /// Löschen, Fehlerbericht, App Attest: jede Verbindung
        case any
    }

    typealias Transport = @Sendable (URLRequest, Data?, Network) async throws -> (Data, Int)

    var transport: Transport = SuyaAPI.urlSession

    // MARK: Anfragen

    func uploadPart(_ donor: Donor, night: String, index: Int, count: Int, totalHash: String, data: Data,
                    assertion: [String: String]) async throws -> Response {
        var r = request("api/donation/part", donor: donor)
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.setValue(night, forHTTPHeaderField: "X-Night")
        r.setValue(String(index), forHTTPHeaderField: "X-Part")
        r.setValue(String(count), forHTTPHeaderField: "X-Parts")
        r.setValue(totalHash, forHTTPHeaderField: "X-Total-Hash")
        assertion.forEach { r.setValue($0.value, forHTTPHeaderField: $0.key) }
        return try await send(r, body: data, .wifiOnly)
    }

    func deleteDonations(_ donor: Donor, assertion: [String: String]) async throws -> Response {
        var r = request("api/donation/delete", donor: donor)
        assertion.forEach { r.setValue($0.value, forHTTPHeaderField: $0.key) }
        return try await send(r, body: nil, .any)
    }

    func registerAttestation(_ donor: Donor, keyID: String, attestation: Data, challenge: String) async throws -> Response {
        var r = request("api/attest/register", donor: donor)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONSerialization.data(withJSONObject: [
            "keyId": keyID, "attestation": attestation.base64EncodedString(), "challenge": challenge])
        return try await send(r, body: body, .any)
    }

    func challenge() async -> String? {
        var r = URLRequest(url: Self.server.appendingPathComponent("api/attest/challenge"))
        r.httpMethod = "GET"
        guard let res = try? await send(r, body: nil, .any), res.status == 200 else { return nil }
        return res.json["challenge"] as? String
    }

    /// Verlangt der Server App Attest?
    func attestEnabled() async -> Bool {
        var r = URLRequest(url: Self.server.appendingPathComponent("api/status"))
        r.httpMethod = "GET"
        guard let res = try? await send(r, body: nil, .any) else { return false }
        return res.json["attest"] as? Bool ?? false
    }

    struct BugReport: Sendable {
        var text: String
        var contact: String
        var technical: [String: String]
        var crashes: [String]
        var log: String?
    }

    func sendBugReport(_ report: BugReport) async throws -> Response {
        var r = URLRequest(url: Self.server.appendingPathComponent("api/bug-report"), timeoutInterval: 60)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["text": report.text, "contact": report.contact,
                                   "technical": report.technical, "crashes": report.crashes]
        if let log = report.log, !log.isEmpty { body["log"] = log }
        return try await send(r, body: try JSONSerialization.data(withJSONObject: body), .any)
    }

    // MARK: Übertragung

    private func request(_ path: String, donor: Donor) -> URLRequest {
        var r = URLRequest(url: Self.server.appendingPathComponent(path))
        r.httpMethod = "POST"
        r.setValue(donor.id, forHTTPHeaderField: "X-Donor")
        r.setValue(donor.key, forHTTPHeaderField: "X-Key")
        return r
    }

    private func send(_ r: URLRequest, body: Data?, _ network: Network) async throws -> Response {
        let (data, status) = try await transport(r, body, network)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return Response(status: status, json: obj.compactMapValues { Self.sendable($0) })
    }

    private static func sendable(_ v: Any) -> (any Sendable)? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber {
            // JSON-Wahrheitswerte kommen als NSNumber; an der Typkennung unterscheiden
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            return n.intValue
        }
        if let a = v as? [Int] { return a }
        return nil
    }

    private static let wifiSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.allowsExpensiveNetworkAccess = false     // kein Mobilfunk
        c.allowsConstrainedNetworkAccess = false   // kein Datensparmodus
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 30 * 60
        return URLSession(configuration: c)
    }()

    static let urlSession: Transport = { request, body, network in
        let session = network == .wifiOnly ? wifiSession : URLSession.shared
        let data: Data
        let response: URLResponse
        if let body {
            (data, response) = try await session.upload(for: request, from: body)
        } else {
            (data, response) = try await session.data(for: request)
        }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

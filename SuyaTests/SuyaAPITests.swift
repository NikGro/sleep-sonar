import Foundation
import Testing
@testable import Suya

/// Schnittstelle zum Server ohne Netz: geprüft werden Pfade, Köpfe und das Lesen der Antworten.
struct SuyaAPITests {
    final class Recorder: @unchecked Sendable {
        var requests: [(URLRequest, Data?, SuyaAPI.Network)] = []
        var reply: (Int, [String: Any]) = (200, [:])
    }

    private func api(_ r: Recorder) -> SuyaAPI {
        SuyaAPI(transport: { request, body, network in
            r.requests.append((request, body, network))
            return (try JSONSerialization.data(withJSONObject: r.reply.1), r.reply.0)
        })
    }

    let donor = SuyaAPI.Donor(id: "ABCD1234", key: String(repeating: "k", count: 40))

    @Test func uploadPartUsesEnglishHeadersAndWifi() async throws {
        let r = Recorder()
        r.reply = (202, ["ok": true, "missing": [1]])
        let res = try await api(r).uploadPart(donor, night: "nacht-01", index: 0, count: 2, totalHash: "ab",
                                              data: Data([1, 2, 3]), assertion: ["X-Assertion": "a", "X-Challenge": "c"])
        #expect(res.status == 202)
        let (req, body, network) = try #require(r.requests.first)
        #expect(req.url?.path == "/api/donation/part")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "X-Donor") == "ABCD1234")
        #expect(req.value(forHTTPHeaderField: "X-Key") == donor.key)
        #expect(req.value(forHTTPHeaderField: "X-Night") == "nacht-01")
        #expect(req.value(forHTTPHeaderField: "X-Part") == "0")
        #expect(req.value(forHTTPHeaderField: "X-Parts") == "2")
        #expect(req.value(forHTTPHeaderField: "X-Total-Hash") == "ab")
        #expect(req.value(forHTTPHeaderField: "X-Assertion") == "a")
        #expect(body == Data([1, 2, 3]))
        #expect(network == .wifiOnly)
    }

    @Test func keyMismatchFromCodeOrOldText() async throws {
        let r = Recorder()
        r.reply = (403, ["code": "key_mismatch"])
        #expect(try await api(r).deleteDonations(donor, assertion: [:]).keyMismatch)
        r.reply = (403, ["fehler": "Schlüssel passt nicht"])
        #expect(try await api(r).deleteDonations(donor, assertion: [:]).keyMismatch)
        r.reply = (403, ["code": "attest_failed"])
        #expect(try await api(r).deleteDonations(donor, assertion: [:]).keyMismatch == false)
        #expect(r.requests.allSatisfy { $0.2 == .any })   // Löschen auch über Mobilfunk
    }

    @Test func statusAndChallenge() async throws {
        let r = Recorder()
        r.reply = (200, ["ok": true, "attest": true, "challenge": "Y2g="])
        #expect(await api(r).attestEnabled())
        #expect(await api(r).challenge() == "Y2g=")
        r.reply = (200, ["ok": true, "attest": false])
        #expect(await api(r).attestEnabled() == false)
    }

    @Test func bugReportBody() async throws {
        let r = Recorder()
        r.reply = (201, ["ok": true, "id": "20261114-1"])
        let res = try await api(r).sendBugReport(.init(text: "kaputt", contact: "", technical: ["app": "1"], crashes: [], log: "x"))
        #expect(res.json["id"] as? String == "20261114-1")
        let (req, body, _) = try #require(r.requests.first)
        #expect(req.url?.path == "/api/bug-report")
        let obj = try #require(try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any])
        #expect(obj["text"] as? String == "kaputt")
        #expect(obj["log"] as? String == "x")
        #expect((obj["technical"] as? [String: String])?["app"] == "1")
    }
}

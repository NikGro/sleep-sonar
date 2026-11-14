import Foundation
import Testing
@testable import Suya

struct NightTests {
    private func folder() throws -> Night {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("night-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Night(url)
    }

    @Test func timesFromFiles() throws {
        let n = try folder()
        let start = Date(timeIntervalSince1970: 1_800_000_000.25)
        let audio = start.addingTimeInterval(2)
        let end = start.addingTimeInterval(8 * 3600)
        try n.writeMeta(["start": Night.timestamp(start), "end": Night.timestamp(end)])
        try "file,start\naudio_000.m4a,\(Night.timestamp(audio))\n".write(to: n.url(.audioIndex), atomically: true, encoding: .utf8)
        #expect(abs(n.start!.timeIntervalSince(start)) < 0.01)
        #expect(abs(n.audioStart!.timeIntervalSince(audio)) < 0.01)
        #expect(abs(n.end!.timeIntervalSince(end)) < 0.01)
        // ohne audio_index.csv gilt der Beginn der Aufnahme
        try FileManager.default.removeItem(at: n.url(.audioIndex))
        #expect(abs(n.audioStart!.timeIntervalSince(start)) < 0.01)
    }

    @Test func parsesTimestampsWithAndWithoutFraction() {
        #expect(Night.date("2026-11-14T09:00:00.500Z") == Date(timeIntervalSince1970: 1_794_646_800.5))
        #expect(Night.date("2026-11-14T09:00:00Z") == Date(timeIntervalSince1970: 1_794_646_800))
        #expect(Night.date("kaputt") == nil)
    }

    @Test func columnsAndGaps() throws {
        let n = try folder()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var csv = "time,rms_db,peak_db\n"
        for s in [0, 1, 2, 63, 64] { csv += "\(Night.timestamp(t0.addingTimeInterval(Double(s)))),-\(40 + s),-10\n" }
        csv += "kaputt\n"
        try csv.write(to: n.url(.levels), atomically: true, encoding: .utf8)
        #expect(n.column(.levels, 1) == [-40, -41, -42, -103, -104])
        #expect(n.timestamps(.levels).count == 5)
        #expect(NightModel.untrackedGapSeconds(n.folder) == 60)
        // mit gaps.csv sind Lücken bekannt und aufgefüllt
        try "from_s,to_s\n2,62\n".write(to: n.url(.gaps), atomically: true, encoding: .utf8)
        #expect(NightModel.untrackedGapSeconds(n.folder) == 0)
        #expect(NightModel.gapFrames(n.folder) == [20..<620])
    }

    @Test func soundMarksFromCSV() throws {
        let n = try folder()
        try "seconds,state\n100.0,an\n200.0,aus\n".write(to: n.url(.sounds), atomically: true, encoding: .utf8)
        #expect(NightModel.soundFrames(n.folder) == [980..<2350])
    }
}

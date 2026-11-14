import AVFoundation
import Foundation

/// Hält fest, was die App während einer Nachtaufnahme als Schlafklang abspielt (Ausgang des Mischers,
/// 16 kHz mono, AAC). Grundlage, um den Klang später aus dem Mikrofon herauszurechnen (Echo-Unterdrückung):
/// erst als Test an exportierten Nächten, danach live. Liegt neben dem Ton der Nacht
/// (`klang_ref_000.caf` …), wird mit ihm nach 24 h gelöscht und nie gespendet.
/// `klang_ref.csv`: Datei, Beginn als Unix-Zeit und Host-Zeit in Sekunden (zum Ausrichten auf das Mikrofon).
final class SoundReference: @unchecked Sendable {
    static let shared = SoundReference()
    static let prefix = "klang_ref_"

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "suya.soundref", qos: .utility)
    private var folder: URL?
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    /// Nachtaufnahme beginnt / endet (Hauptthread)
    func setFolder(_ f: URL?) {
        lock.lock(); folder = f; lock.unlock()
        queue.async { [self] in close() }
    }

    /// Klang-Engine stoppt: aktuelle Datei abschließen, beim nächsten Start beginnt eine neue
    func endSegment() { queue.async { [self] in close() } }

    /// aus dem Tap des Mischers (Audio-Thread)
    func push(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        lock.lock(); let f = folder; lock.unlock()
        guard let f, let copy = Self.copy(buffer) else { return }
        queue.async { [self] in write(copy, folder: f, hostTime: hostTime) }
    }

    private func write(_ buffer: AVAudioPCMBuffer, folder: URL, hostTime: UInt64) {
        if file == nil || converter?.inputFormat != buffer.format { open(folder: folder, input: buffer.format, hostTime: hostTime) }
        guard let file, let converter else { return }
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * outFormat.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        if err == nil, out.frameLength > 0 { try? file.write(from: out) }
    }

    private func open(folder: URL, input: AVAudioFormat, hostTime: UInt64) {
        close()
        let fm = FileManager.default
        let n = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(Self.prefix) }.count
        let name = String(format: "%@%03d.caf", Self.prefix, n)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000]
        file = try? AVAudioFile(forWriting: folder.appendingPathComponent(name), settings: settings,
                                commonFormat: .pcmFormatFloat32, interleaved: false)
        converter = AVAudioConverter(from: input, to: outFormat)
        converter?.downmix = true
        let host = AVAudioTime.seconds(forHostTime: hostTime)
        let line = String(format: "%@,%.3f,%.6f\n", name, Date().timeIntervalSince1970, host)
        let csv = Night(folder).url(.soundReference)
        if let h = try? FileHandle(forWritingTo: csv) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(line.utf8)); try? h.close()
        } else {
            try? Data(("datei,beginn_unix,beginn_host\n" + line).utf8).write(to: csv)
        }
    }

    private func close() { file = nil; converter = nil }

    private static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let c = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength),
              let src = b.floatChannelData, let dst = c.floatChannelData else { return nil }
        c.frameLength = b.frameLength
        for ch in 0..<Int(b.format.channelCount) {
            dst[ch].update(from: src[ch], count: Int(b.frameLength))
        }
        return c
    }

    /// Referenzdateien einer Nacht (werden mit dem Ton gelöscht)
    static func files(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) || $0.lastPathComponent == "klang_ref.csv" }
    }
}

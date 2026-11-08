import AVFoundation
import Foundation

/// Speicher sparen: die ganze Tonaufnahme einer Nacht löschen, aber die Ausschnitte der erkannten
/// Geräusche behalten (zum Anhören). Vorher werden Geräusche und Modell-Schlafphasen berechnet,
/// denn beides braucht die Aufnahme. Pegel, Bewegung und Watch-Daten bleiben unverändert.
enum NightAudioTrim {
    enum TrimError: LocalizedError {
        case modelFailed
        var errorDescription: String? { tr("Das Modell konnte die Nacht nicht auswerten. Der Ton bleibt erhalten.") }
    }

    static func audioBytes(_ folder: URL) -> Int64 {
        NightExport.audioFiles(in: folder).reduce(0) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Gibt die frei gewordenen Bytes zurück.
    @MainActor
    static func trim(_ folder: URL) async throws -> Int64 {
        let before = audioBytes(folder)
        let events = try await SoundEventDetector.analyze(folder: folder) { _ in }
        if NightModel.isAvailable, NightModel.cached(folder) == nil {
            _ = try? await Task.detached(priority: .utility) { try NightModel.stages(folder: folder) }.value
        }
        // ohne Ergebnis den Ton nicht löschen – sonst bliebe von der Nacht nichts übrig
        guard NightModel.cached(folder) != nil else { throw TrimError.modelFailed }
        try await Task.detached(priority: .userInitiated) {
            let dir = folder.appendingPathComponent("clips", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for e in events {
                let url = NightClipPlayer.clipURL(e, folder: folder)
                guard !FileManager.default.fileExists(atPath: url.path),
                      let buf = NightClipPlayer.clip(e, folder: folder) else { continue }
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                               AVSampleRateKey: buf.format.sampleRate,
                                               AVNumberOfChannelsKey: buf.format.channelCount,
                                               AVEncoderBitRateKey: 32000]
                let out = try AVAudioFile(forWriting: url, settings: settings,
                                          commonFormat: buf.format.commonFormat, interleaved: buf.format.isInterleaved)
                try out.write(from: buf)
            }
            for f in NightExport.audioFiles(in: folder) { try FileManager.default.removeItem(at: f) }
        }.value
        return before - audioBytes(folder)
    }
}

import AVFAudio
import Foundation
import SonarDSP
import UIKit

/// Sendet einen Dauerton über den Lautsprecher und wertet das Mikrofon aus.
@MainActor
final class SonarEngine: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var reading: SonarReading?
    @Published private(set) var errorMessage: String?
    @Published private(set) var sampleRate: Double = 0

    private var engine: AVAudioEngine?
    private var tone: ToneState?
    private var worker: Worker?

    func start(carrierHz: Double, volume: Float) async {
        guard !isRunning else { return }
        errorMessage = nil
        reading = nil

        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Kein Mikrofonzugriff. Einstellungen → SleepSonar → Mikrofon erlauben."
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            // .measurement schaltet Echo-Unterdrückung und Automatik-Pegel ab
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
            try session.setPreferredSampleRate(48_000)
            try session.setActive(true)

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let inFormat = input.outputFormat(forBus: 0)
            let rate = inFormat.sampleRate > 0 ? inFormat.sampleRate : session.sampleRate
            guard carrierHz < rate / 2 - 500 else {
                errorMessage = "Abtastrate \(Int(rate)) Hz ist zu niedrig für \(Int(carrierHz)) Hz."
                return
            }

            // Sender
            let tone = ToneState(frequency: carrierHz, sampleRate: rate, amplitude: volume)
            let outFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let source = Self.makeSourceNode(format: outFormat, tone: tone)
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: outFormat)

            // Empfänger
            let worker = Worker(sampleRate: rate, carrierHz: carrierHz) { [weak self] r in
                Task { @MainActor in self?.reading = r }
            }
            Self.installTap(on: input, format: inFormat, worker: worker)

            try engine.start()
            self.engine = engine
            self.tone = tone
            self.worker = worker
            self.sampleRate = rate
            isRunning = true
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            errorMessage = "Audio-Fehler: \(error.localizedDescription)"
            stop()
        }
    }

    func setVolume(_ v: Float) { tone?.targetAmplitude = v }

    // Die Audio-Closures laufen auf Audio-Threads, deshalb außerhalb des MainActors erzeugen.
    nonisolated private static func makeSourceNode(format: AVAudioFormat, tone: ToneState) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            tone.render(frameCount: Int(frameCount), into: audioBufferList)
            return noErr
        }
    }

    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, worker: Worker) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            worker.handle(buffer: buffer, time: time)
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        tone = nil
        worker = nil
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Sinusgenerator für den Echtzeit-Thread (keine Allokationen).
final class ToneState: @unchecked Sendable {
    private var phase = 0.0
    private let increment: Double
    private var amplitude: Float = 0
    var targetAmplitude: Float

    init(frequency: Double, sampleRate: Double, amplitude: Float) {
        increment = 2 * .pi * frequency / sampleRate
        targetAmplitude = amplitude
    }

    func render(frameCount: Int, into list: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let target = targetAmplitude
        for i in 0..<frameCount {
            // sanft ein-/ausblenden, damit es nicht knackt
            amplitude += (target - amplitude) * 0.0005
            let v = amplitude * Float(sin(phase))
            phase += increment
            if phase > 2 * .pi { phase -= 2 * .pi }
            for b in buffers {
                b.mData?.assumingMemoryBound(to: Float.self)[i] = v
            }
        }
    }
}

/// Läuft auf dem Tap-Thread: füttert den Prozessor, wertet zweimal pro Sekunde aus.
final class Worker: @unchecked Sendable {
    private let processor: SonarProcessor
    private let publish: @Sendable (SonarReading) -> Void
    private var lastAnalysis = Date.distantPast

    init(sampleRate: Double, carrierHz: Double, publish: @escaping @Sendable (SonarReading) -> Void) {
        processor = SonarProcessor(sampleRate: sampleRate, carrierHz: carrierHz)
        self.publish = publish
    }

    func handle(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        let st: Int64? = time.isSampleTimeValid ? time.sampleTime : nil
        processor.process(UnsafeBufferPointer(start: data, count: n), sampleTime: st)
        let now = Date()
        if now.timeIntervalSince(lastAnalysis) >= 0.5 {
            lastAnalysis = now
            publish(processor.analyze())
        }
    }
}

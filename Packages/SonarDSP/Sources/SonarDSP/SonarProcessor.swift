import Foundation

/// Ergebnis einer Auswertung.
public struct SonarReading: Sendable, Equatable {
    public enum Status: String, Sendable {
        case warmingUp      // noch zu wenig Daten
        case noEcho         // kein brauchbares Echo (niemand da / zu leise / falsche Frequenz)
        case moving         // Körperbewegung
        case collecting     // ruhig, aber noch keine sichere Atemfrequenz
        case ok
    }

    public var status: Status
    /// Atemzüge pro Minute
    public var breathsPerMinute: Double?
    /// 0…1 (Autokorrelation)
    public var breathConfidence: Double
    /// Hub der Atembewegung (Spitze-Spitze, letzte 10 s) in mm
    public var breathAmplitudeMM: Double?
    /// Experimentell: Herzschläge pro Minute
    public var heartBPM: Double?
    /// Peak/Mittel im Spektrum; ab ca. 6 einigermaßen eindeutig
    public var heartConfidence: Double
    /// Mittlere Wegänderung der letzten Sekunde in mm/s
    public var movementMMPerSecond: Double
    /// Ruhige Zeit seit der letzten Bewegung in s
    public var quietSeconds: Double
    /// Körperecho / Rauschen
    public var snr: Double
    /// Pegel des empfangenen Trägers in dB relativ zum Sendepegel
    /// (= dBFS bei 100 % Sendepegel). Fällt er ohne Bewegung ab, regelt der Lautsprecher herunter.
    public var levelDB: Double
    /// Wegkurve der letzten bis zu 30 s in mm, 10 Hz, mittelwertfrei
    public var waveform: [Double]

    public var isBreathReliable: Bool { breathConfidence >= SonarProcessor.breathConfidenceMin }
    public var isHeartReliable: Bool { heartConfidence >= SonarProcessor.heartConfidenceMin }
}

/// Wertet Mikrofonsamples eines Dauertons aus (Phasen-Sonar).
///
/// Ablauf: Mischen mit dem Träger (I/Q) → Mittelung auf 100 Hz → 50 Hz
/// → Kreisfit (statisches Echo = Mittelpunkt) → Phase um den Mittelpunkt
/// → Weg in mm (λ/4π pro Radiant) → Atmung, Puls, Bewegung.
/// Nicht threadsicher: von genau einem Thread benutzen.
public final class SonarProcessor {
    public static let speedOfSound = 343.0
    public static let movementThreshold = 15.0   // mm/s
    public static let snrMin = 1.8
    public static let breathConfidenceMin = 0.5
    public static let heartConfidenceMin = 6.0

    public let sampleRate: Double
    public let carrierHz: Double
    public let analysisRate = 50.0

    private let wavelengthMM: Double
    private let block: Int
    private let cyclesPerSample: Double
    private var acc = Complex.zero
    private var accCount = 0
    private var pending: Complex?
    private var z50: [Complex] = []
    private let maxSamples: Int
    private var nextSampleTime: Int64 = 0
    private var gain = 1.0

    public init(sampleRate: Double = 48_000, carrierHz: Double = 20_000) {
        self.sampleRate = sampleRate
        self.carrierHz = carrierHz
        self.wavelengthMM = Self.speedOfSound / carrierHz * 1000
        self.block = Int((sampleRate / 100).rounded())
        self.cyclesPerSample = carrierHz / sampleRate
        self.maxSamples = Int(30 * analysisRate)
        z50.reserveCapacity(maxSamples + 1)
    }

    public func reset() {
        acc = .zero
        accCount = 0
        pending = nil
        z50.removeAll(keepingCapacity: true)
    }

    /// Samples verarbeiten. `sampleTime` = absolute Position des ersten Samples
    /// (gleiche Uhr wie der Sender); nil = direkt an den vorigen Block anschließen.
    /// `gain` = aktueller Sendepegel (0…1). Das Signal wird darauf normiert, damit
    /// Pegeländerungen nicht als Bewegung erscheinen. Unter 0,5 % keine Normierung
    /// (Kontrolltest ohne Ton).
    public func process(_ samples: UnsafeBufferPointer<Float>, sampleTime: Int64? = nil, gain: Double = 1) {
        guard !samples.isEmpty else { return }
        self.gain = gain >= 0.005 ? gain : 1
        let start = sampleTime ?? nextSampleTime
        nextSampleTime = start + Int64(samples.count)
        // Trägerphase exakt aus der absoluten Position, dann per Rotation weiter
        let startCycles = (Double(start) * cyclesPerSample).truncatingRemainder(dividingBy: 1)
        var c = cos(2 * .pi * startCycles)
        var s = sin(2 * .pi * startCycles)
        let w = 2 * .pi * cyclesPerSample
        let cw = cos(w), sw = sin(w)
        var re = acc.re, im = acc.im, count = accCount
        for x in samples {
            let v = Double(x)
            re += v * c
            im -= v * s
            let nc = c * cw - s * sw
            s = s * cw + c * sw
            c = nc
            count += 1
            if count == block {
                on100Hz(Complex(re, im) / (Double(block) * self.gain))
                re = 0; im = 0; count = 0
            }
        }
        acc = Complex(re, im)
        accCount = count
    }

    public func process(_ samples: [Float], sampleTime: Int64? = nil, gain: Double = 1) {
        samples.withUnsafeBufferPointer { process($0, sampleTime: sampleTime, gain: gain) }
    }

    private func on100Hz(_ z: Complex) {
        if let p = pending {
            z50.append((p + z) / 2)
            pending = nil
            if z50.count > maxSamples { z50.removeFirst(z50.count - maxSamples) }
        } else {
            pending = z
        }
    }

    /// Auswertung der letzten bis zu 30 s.
    public func analyze() -> SonarReading {
        let fs = analysisRate
        let z = z50
        var reading = SonarReading(status: .warmingUp, breathsPerMinute: nil, breathConfidence: 0,
                                   breathAmplitudeMM: nil, heartBPM: nil, heartConfidence: 0,
                                   movementMMPerSecond: 0, quietSeconds: 0, snr: 0,
                                   levelDB: -120, waveform: [])
        if !z.isEmpty {
            var m = Complex.zero
            let tail = z.suffix(50)
            for v in tail { m = m + v }
            reading.levelDB = 20 * log10((m / Double(tail.count)).magnitude + 1e-12)
        }
        guard z.count >= Int(8 * fs) else { return reading }

        // Statisches Echo (Mittelpunkt) und Körperecho (Radius)
        var mean = Complex.zero
        for v in z { mean = mean + v }
        mean = mean / Double(z.count)
        var spread = 0.0
        for v in z { spread += (v - mean).magnitudeSquared }
        spread = (spread / Double(z.count)).squareRoot()

        let fitWindow = z.suffix(1000)
        let fit = DSP.circleFit(fitWindow)

        // Rauschen aus Nachbardifferenzen (Atmung ist dagegen sehr langsam)
        let nz = Array(z.suffix(500))
        var dsum = 0.0
        for i in 1..<nz.count { dsum += (nz[i] - nz[i - 1]).magnitudeSquared }
        let noise = (dsum / Double(nz.count - 1) / 2).squareRoot()

        var disp: [Double]
        let radius: Double
        let mmPerRad = wavelengthMM / (4 * .pi)
        if let fit, fit.radius < 20 * spread * 2.0.squareRoot() {
            radius = fit.radius
            let phases = z.map { ($0 - fit.center).angle }
            disp = DSP.unwrap(phases).map { -$0 * mmPerRad }
        } else {
            // Rückfall: Projektion auf die Hauptachse (PCA)
            var sxx = 0.0, sxy = 0.0, syy = 0.0
            for v in z {
                let d = v - mean
                sxx += d.re * d.re; sxy += d.re * d.im; syy += d.im * d.im
            }
            let n = Double(z.count)
            sxx /= n; sxy /= n; syy /= n
            let tr = sxx + syy, det = sxx * syy - sxy * sxy
            let l1 = tr / 2 + max(0, tr * tr / 4 - det).squareRoot()
            var ux = sxy, uy = l1 - sxx
            if abs(ux) + abs(uy) < 1e-30 { ux = 1; uy = 0 }
            let un = (ux * ux + uy * uy).squareRoot()
            ux /= un; uy /= un
            radius = max(l1.squareRoot() * 2, 1e-12)
            disp = z.map { (($0.re - mean.re) * ux + ($0.im - mean.im) * uy) / radius * mmPerRad }
        }

        reading.snr = radius / (noise + 1e-15)
        guard reading.snr >= Self.snrMin else {
            reading.status = .noEcho
            return reading
        }

        // Bewegung: Geschwindigkeit der geglätteten Wegkurve in 0,5-s-Abschnitten
        let smooth = DSP.movingAverage(disp, 10)
        let half = Int(fs / 2)
        var velocity = [Double](repeating: 0, count: smooth.count - 1)
        for i in 1..<smooth.count { velocity[i - 1] = abs(smooth[i] - smooth[i - 1]) * fs }
        let segments = velocity.count / half
        var segV = [Double](repeating: 0, count: segments)   // chronologisch
        for k in 0..<segments {
            let end = velocity.count - k * half
            let slice = velocity[(end - half)..<end]
            segV[segments - 1 - k] = slice.reduce(0, +) / Double(half)
        }
        reading.movementMMPerSecond = segV.suffix(2).reduce(0, +) / Double(min(2, segV.count))

        // Ruhige Zeit seit der letzten Bewegung
        var start = 0
        if let lastMoving = segV.lastIndex(where: { $0 > Self.movementThreshold }) {
            // Segment k (chronologisch) endet bei velocity-Index (velocity.count - (segments-1-k)*half)
            let segEnd = velocity.count - (segments - 1 - lastMoving) * half
            start = segEnd + half
        }
        start = max(start, disp.count - Int(30 * fs))
        start = min(start, disp.count)
        let quiet = Array(disp[start...])
        reading.quietSeconds = Double(quiet.count) / fs

        // Atmung
        if quiet.count >= Int(10 * fs) {
            let breath = DSP.movingAverage(DSP.detrend(quiet), 20)
            if let peak = DSP.autocorrPeak(breath, lagMin: Int(1.5 * fs), lagMax: Int(10 * fs)) {
                reading.breathsPerMinute = 60 * fs / peak.lag
                reading.breathConfidence = max(0, peak.value)
            }
            let last = breath.suffix(Int(10 * fs))
            if let lo = last.min(), let hi = last.max() { reading.breathAmplitudeMM = hi - lo }

            // Puls (experimentell): Bandpass, Atem-Oberwellen ausblenden
            let fast = DSP.movingAverage(quiet, 5)
            let slow = DSP.movingAverage(quiet, 30)
            let band = Array(zip(fast, slow).map { $0 - $1 }.suffix(Int(20 * fs)))
            var exclude: [Double] = []
            if let rr = reading.breathsPerMinute, reading.isBreathReliable {
                exclude = (2...11).map { Double($0) * rr }
            }
            if let hp = DSP.spectralPeak(band, fs: fs, bpmLow: 50, bpmHigh: 150, exclude: exclude) {
                reading.heartBPM = hp.bpm
                reading.heartConfidence = hp.confidence
            }
        }

        // Wegkurve für die Anzeige: 10 Hz, letzte 30 s
        let shown = DSP.movingAverage(DSP.detrend(Array(disp.suffix(Int(30 * fs)))), 10)
        var wave: [Double] = []
        wave.reserveCapacity(shown.count / 5 + 1)
        var i = 0
        while i < shown.count { wave.append(shown[i]); i += 5 }
        reading.waveform = wave

        if reading.movementMMPerSecond > Self.movementThreshold {
            reading.status = .moving
        } else if reading.isBreathReliable, reading.breathsPerMinute != nil {
            reading.status = .ok
        } else {
            reading.status = .collecting
        }
        return reading
    }
}

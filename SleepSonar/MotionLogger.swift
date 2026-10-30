import CoreMotion
import Foundation

/// Bewegungssensor mit 25 Hz, fasst je Sekunde zusammen:
/// mittlere und maximale Beschleunigung (ohne Schwerkraft) sowie Lage des iPhones.
/// Starke Werte = iPhone wird angefasst/bewegt.
final class MotionLogger: @unchecked Sendable {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "motion"
        return q
    }()
    private var sum = 0.0
    private var maxValue = 0.0
    private var count = 0
    private var lastFlush = Date()
    private let onSecond: @Sendable (_ activity: Double, _ maxDelta: Double, _ pitch: Double, _ roll: Double) -> Void

    /// Ab dieser mittleren Beschleunigung (g) gilt das iPhone als angefasst.
    static let handledThreshold = 0.02

    init(onSecond: @escaping @Sendable (Double, Double, Double, Double) -> Void) {
        self.onSecond = onSecond
    }

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 25
        manager.startDeviceMotionUpdates(to: queue) { [weak self] m, _ in
            guard let self, let m else { return }
            let a = m.userAcceleration
            let mag = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            self.sum += mag
            self.maxValue = max(self.maxValue, mag)
            self.count += 1
            let now = Date()
            if now.timeIntervalSince(self.lastFlush) >= 1, self.count > 0 {
                let deg = 180 / Double.pi
                self.onSecond(self.sum / Double(self.count), self.maxValue,
                              m.attitude.pitch * deg, m.attitude.roll * deg)
                self.sum = 0; self.maxValue = 0; self.count = 0
                self.lastFlush = now
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}

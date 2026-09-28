import Foundation
import CoreMotion

/// Notices the phone being shaken, including with the screen locked.
///
/// UIKit's shake gesture only reaches an app on screen, and a sleep timer runs
/// with the screen off. CoreMotion keeps delivering while background audio holds
/// the app awake, so it is used instead — and only while `start` is in effect,
/// because the sensors cost battery.
@MainActor
final class ShakeDetector {

    var onShake: (() -> Void)?

    private let motion = CMMotionManager()
    private var lastShake = Date.distantPast

    /// User acceleration, in g, that counts as a deliberate shake rather than
    /// rolling over in bed.
    private static let threshold = 1.8

    var isRunning: Bool { motion.isDeviceMotionActive }

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 0.1
        // Captured as a plain value: a static on a main-actor class is itself
        // main-actor isolated, and the handler's isolation is CoreMotion's.
        let threshold = Self.threshold
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let a = data?.userAcceleration else { return }
            let magnitude = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            guard magnitude > threshold else { return }
            Task { @MainActor in self?.detected() }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }

    private func detected() {
        // One shake is several samples over threshold; count it once.
        guard Date().timeIntervalSince(lastShake) > 1.5 else { return }
        lastShake = Date()
        onShake?()
    }
}

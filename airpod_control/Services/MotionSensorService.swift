import Foundation
import CoreMotion

struct MotionPacket: Sendable {
    let timestamp: Date
    /// Hardware capture time from CMDeviceMotion.timestamp (seconds since device boot).
    /// Use this for rate-limiting — it reflects when motion was *captured*, not when
    /// the callback ran. Using Date() for shouldAccept causes all backed-up callbacks
    /// to share the same wall-clock instant, making all but the first be rejected.
    let deviceTimestamp: TimeInterval
    let attitude: AttitudeValue
    let rotationRate: Vector3Value
    let gravity: Vector3Value
    let userAcceleration: Vector3Value
}

enum MotionSensorError: LocalizedError {
    case unavailable
    case unauthorized
    case streamFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Headphone motion is unavailable on this Mac right now."
        case .unauthorized:
            return "Motion permission is denied or restricted."
        case .streamFailed(let message):
            return message
        }
    }
}

@MainActor
final class MotionSensorService: NSObject, CMHeadphoneMotionManagerDelegate {
    enum HeadphoneConnectionStatus: String {
        case unknown
        case connected
        case disconnected
    }

    private var manager = CMHeadphoneMotionManager()
    private(set) var isStreaming = false
    private(set) var headphoneConnectionStatus: HeadphoneConnectionStatus = .unknown
    private var onConnected: (@MainActor @Sendable () -> Void)?
    private var onDisconnected: (@MainActor @Sendable () -> Void)?

    override init() {
        super.init()
        if RuntimeEnvironment.shouldUsePhysicalMotionHardware {
            configureConnectionMonitoring()
        } else {
            dbgLog("BAIL MotionSensorService.configureConnectionMonitoring reason=test_or_preview")
        }
    }

    var authorizationState: AuthorizationState {
        AuthorizationState(status: CMHeadphoneMotionManager.authorizationStatus())
    }

    var isHeadphoneMotionAvailable: Bool {
        manager.isDeviceMotionAvailable
    }

    func setConnectionHandlers(
        onConnected: @escaping @MainActor @Sendable () -> Void,
        onDisconnected: @escaping @MainActor @Sendable () -> Void
    ) {
        self.onConnected = onConnected
        self.onDisconnected = onDisconnected
    }

    func startStreaming(
        onMotion: @escaping @MainActor @Sendable (MotionPacket) -> Void,
        onError: @escaping @MainActor @Sendable (MotionSensorError) -> Void
    ) throws {
        dbgLog("ENTRY MotionSensorService.startStreaming auth=\(authorizationState.rawValue) available=\(isHeadphoneMotionAvailable)")
        if authorizationState == .denied || authorizationState == .restricted {
            dbgLog("BAIL MotionSensorService.startStreaming reason=unauthorized auth=\(authorizationState.rawValue)")
            throw MotionSensorError.unauthorized
        }

        guard isHeadphoneMotionAvailable else {
            dbgLog("BAIL MotionSensorService.startStreaming reason=unavailable")
            throw MotionSensorError.unavailable
        }

        // Use the main queue for CoreMotion callbacks so Swift 6 actor isolation
        // is satisfied without background-queue thunk crashes. The expensive
        // gesture-matching work (shouldSuppressContinuousRecognition) was removed
        // from the per-frame pipeline in r32, so the remaining work per callback is
        // lightweight and will not cause main-queue congestion.
        manager.startDeviceMotionUpdates(to: .main) { motion, error in
            if let error {
                dbgLog("BAIL CMHeadphoneMotionManager.callback reason=error error=\(error.localizedDescription)")
                MainActor.assumeIsolated {
                    onError(.streamFailed(error.localizedDescription))
                }
                return
            }
            guard let motion else {
                dbgLog("BAIL CMHeadphoneMotionManager.callback reason=nil_motion")
                MainActor.assumeIsolated {
                    onError(.streamFailed("No motion sample returned."))
                }
                return
            }

            let packet = MotionPacket(
                timestamp: Date(),
                deviceTimestamp: motion.timestamp,
                attitude: AttitudeValue(
                    roll: SensorSampleModel.sanitize(motion.attitude.roll),
                    pitch: SensorSampleModel.sanitize(motion.attitude.pitch),
                    yaw: SensorSampleModel.sanitize(motion.attitude.yaw)
                ),
                rotationRate: Vector3Value(
                    x: SensorSampleModel.sanitize(motion.rotationRate.x),
                    y: SensorSampleModel.sanitize(motion.rotationRate.y),
                    z: SensorSampleModel.sanitize(motion.rotationRate.z)
                ),
                gravity: Vector3Value(
                    x: SensorSampleModel.sanitize(motion.gravity.x),
                    y: SensorSampleModel.sanitize(motion.gravity.y),
                    z: SensorSampleModel.sanitize(motion.gravity.z)
                ),
                userAcceleration: Vector3Value(
                    x: SensorSampleModel.sanitize(motion.userAcceleration.x),
                    y: SensorSampleModel.sanitize(motion.userAcceleration.y),
                    z: SensorSampleModel.sanitize(motion.userAcceleration.z)
                )
            )
            MainActor.assumeIsolated {
                onMotion(packet)
            }
        }
        isStreaming = true
        dbgLog("EXTERNAL CMHeadphoneMotionManager.startDeviceMotionUpdates queue=main return=started")
        dbgLog("DONE MotionSensorService.startStreaming isStreaming=\(isStreaming)")
    }

    func stopStreaming() {
        dbgLog("ENTRY MotionSensorService.stopStreaming isStreaming=\(isStreaming)")
        manager.stopDeviceMotionUpdates()
        isStreaming = false
        dbgLog("EXTERNAL CMHeadphoneMotionManager.stopDeviceMotionUpdates return=stopped")
        dbgLog("DONE MotionSensorService.stopStreaming isStreaming=\(isStreaming)")
    }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        headphoneConnectionStatus = .connected
        dbgLog("INPUT headphone_connection state=connected available=\(manager.isDeviceMotionAvailable)")
        onConnected?()
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        headphoneConnectionStatus = .disconnected
        dbgLog("INPUT headphone_connection state=disconnected available=\(manager.isDeviceMotionAvailable)")
        onDisconnected?()
    }

    private func configureConnectionMonitoring() {
        manager.delegate = self
        manager.startConnectionStatusUpdates()
        dbgLog("EXTERNAL CMHeadphoneMotionManager.startConnectionStatusUpdates return=started")
    }
}

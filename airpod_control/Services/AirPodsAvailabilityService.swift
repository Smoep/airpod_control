import Foundation

struct AirPodsAvailabilitySnapshot {
    let isConnected: Bool
    let isHeadphoneMotionAvailable: Bool
    let authorizationState: AuthorizationState
    let connectionState: ConnectionState
}

final class AirPodsAvailabilityService {
    private let staleConnectionInterval: TimeInterval = 2.0

    func snapshot(
        from motionService: MotionSensorService,
        streamState: StreamState,
        lastUpdateTimestamp: Date?
    ) -> AirPodsAvailabilitySnapshot {
        let now = Date()
        let hasFreshSample = if let lastUpdateTimestamp {
            now.timeIntervalSince(lastUpdateTimestamp) <= staleConnectionInterval
        } else {
            false
        }

        let connectionState: ConnectionState
        if !motionService.isHeadphoneMotionAvailable {
            connectionState = .unsupported
        } else if hasFreshSample || streamState == .active || streamState == .starting {
            connectionState = .connected
        } else {
            connectionState = .disconnected
        }

        return AirPodsAvailabilitySnapshot(
            isConnected: connectionState == .connected,
            isHeadphoneMotionAvailable: motionService.isHeadphoneMotionAvailable,
            authorizationState: motionService.authorizationState,
            connectionState: connectionState
        )
    }
}

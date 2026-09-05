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
        snapshot(
            isHeadphoneMotionAvailable: motionService.isHeadphoneMotionAvailable,
            authorizationState: motionService.authorizationState,
            streamState: streamState,
            lastUpdateTimestamp: lastUpdateTimestamp,
            now: Date()
        )
    }

    /// Connection is deliberately sample-driven. `isDeviceMotionAvailable` says
    /// whether Core Motion currently exposes the capability, but it can remain stale
    /// while the AirPods are in their case and must not be presented as "Connected".
    func snapshot(
        isHeadphoneMotionAvailable: Bool,
        authorizationState: AuthorizationState,
        streamState: StreamState,
        lastUpdateTimestamp: Date?,
        now: Date
    ) -> AirPodsAvailabilitySnapshot {
        let hasFreshSample = if let lastUpdateTimestamp {
            now.timeIntervalSince(lastUpdateTimestamp) <= staleConnectionInterval
        } else {
            false
        }

        let connectionState: ConnectionState
        if hasFreshSample {
            connectionState = .connected
        } else if streamState == .starting {
            connectionState = .connecting
        } else {
            connectionState = .disconnected
        }

        return AirPodsAvailabilitySnapshot(
            isConnected: connectionState == .connected,
            isHeadphoneMotionAvailable: isHeadphoneMotionAvailable,
            authorizationState: authorizationState,
            connectionState: connectionState
        )
    }
}

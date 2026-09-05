import Foundation
import CoreMotion

enum ConnectionState: String, Codable {
    case disconnected
    case connecting
    case connected
    case unsupported
}

enum StreamState: Equatable {
    case stopped
    case waiting
    case starting
    case active
    case error(String)

    var label: String {
        switch self {
        case .stopped:
            return "Stopped"
        case .waiting:
            return "Waiting for AirPods"
        case .starting:
            return "Starting"
        case .active:
            return "Active"
        case .error(let message):
            return "Error: \(message)"
        }
    }
}

enum SamplingMode: String, CaseIterable, Identifiable, Codable {
    case rawDeviceRate = "Raw"
    case hz60 = "60 Hz"
    case hz30 = "30 Hz"

    var id: String { rawValue }

    var minimumInterval: TimeInterval {
        switch self {
        case .rawDeviceRate:
            return 0
        case .hz60:
            return 1.0 / 60.0
        case .hz30:
            return 1.0 / 30.0
        }
    }
}

enum AuthorizationState: String, Codable {
    case notDetermined
    case restricted
    case denied
    case authorized
    case unknown

    init(status: CMAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .restricted:
            self = .restricted
        case .denied:
            self = .denied
        case .authorized:
            self = .authorized
        @unknown default:
            self = .unknown
        }
    }
}

struct AvailabilityState: Codable {
    var isHeadphoneMotionAvailable: Bool
    var authorizationState: AuthorizationState
    var connectionState: ConnectionState
    var lastUpdateTimestamp: Date?
}

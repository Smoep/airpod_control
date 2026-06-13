import Foundation
import CoreMotion

struct Vector3Value: Codable, Sendable {
    let x: Double
    let y: Double
    let z: Double
}

struct AttitudeValue: Codable, Sendable {
    let roll: Double
    let pitch: Double
    let yaw: Double
}

struct DerivedMetrics: Codable, Sendable {
    let headTilt: Double
    let nodAngle: Double
    let shakeAngle: Double
    let movementMagnitude: Double
    let updateFrequencyHz: Double
}

struct SensorSampleModel: Identifiable, Codable, Sendable {
    let id: UUID
    let timestamp: Date
    let attitude: AttitudeValue
    let rotationRate: Vector3Value
    let gravity: Vector3Value
    let userAcceleration: Vector3Value
    let derived: DerivedMetrics

    init(
        id: UUID = UUID(),
        timestamp: Date,
        attitude: AttitudeValue,
        rotationRate: Vector3Value,
        gravity: Vector3Value,
        userAcceleration: Vector3Value,
        updateFrequencyHz: Double
    ) {
        self.id = id
        self.timestamp = timestamp
        self.attitude = attitude
        self.rotationRate = rotationRate
        self.gravity = gravity
        self.userAcceleration = userAcceleration
        self.derived = DerivedMetrics(
            headTilt: attitude.roll,
            nodAngle: attitude.pitch,
            shakeAngle: attitude.yaw,
            movementMagnitude: SensorSampleModel.magnitude(for: userAcceleration),
            updateFrequencyHz: updateFrequencyHz
        )
    }

    static func from(deviceMotion: CMDeviceMotion, timestamp: Date, updateFrequencyHz: Double) -> SensorSampleModel {
        let attitude = AttitudeValue(
            roll: sanitize(deviceMotion.attitude.roll),
            pitch: sanitize(deviceMotion.attitude.pitch),
            yaw: sanitize(deviceMotion.attitude.yaw)
        )
        let rotationRate = Vector3Value(
            x: sanitize(deviceMotion.rotationRate.x),
            y: sanitize(deviceMotion.rotationRate.y),
            z: sanitize(deviceMotion.rotationRate.z)
        )
        let gravity = Vector3Value(
            x: sanitize(deviceMotion.gravity.x),
            y: sanitize(deviceMotion.gravity.y),
            z: sanitize(deviceMotion.gravity.z)
        )
        let userAcceleration = Vector3Value(
            x: sanitize(deviceMotion.userAcceleration.x),
            y: sanitize(deviceMotion.userAcceleration.y),
            z: sanitize(deviceMotion.userAcceleration.z)
        )

        return SensorSampleModel(
            timestamp: timestamp,
            attitude: attitude,
            rotationRate: rotationRate,
            gravity: gravity,
            userAcceleration: userAcceleration,
            updateFrequencyHz: sanitize(updateFrequencyHz)
        )
    }

    nonisolated static func sanitize(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return value
    }

    nonisolated static func magnitude(for vector: Vector3Value) -> Double {
        sqrt((vector.x * vector.x) + (vector.y * vector.y) + (vector.z * vector.z))
    }
}

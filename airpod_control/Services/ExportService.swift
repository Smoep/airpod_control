import Foundation
import AppKit
import UniformTypeIdentifiers

enum ExportServiceError: LocalizedError, Equatable {
    case noSamples
    case cancelled
    case readFailed(String)
    case invalidBackup(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSamples:
            return "No samples are available for export."
        case .cancelled:
            return "Export cancelled."
        case .readFailed(let message):
            return "Failed to read backup file: \(message)"
        case .invalidBackup(let message):
            return "The selected backup is not valid: \(message)"
        case .writeFailed(let message):
            return "Failed to write export file: \(message)"
        }
    }
}

final class ExportService {
    func copySnapshot(_ sample: SensorSampleModel, availabilityState: AvailabilityState) {
        let snapshotText = """
        timestamp=\(sample.timestamp.ISO8601Format())
        connection=\(availabilityState.connectionState.rawValue)
        authorization=\(availabilityState.authorizationState.rawValue)
        attitude.roll=\(sample.attitude.roll)
        attitude.pitch=\(sample.attitude.pitch)
        attitude.yaw=\(sample.attitude.yaw)
        rotationRate.x=\(sample.rotationRate.x)
        rotationRate.y=\(sample.rotationRate.y)
        rotationRate.z=\(sample.rotationRate.z)
        gravity.x=\(sample.gravity.x)
        gravity.y=\(sample.gravity.y)
        gravity.z=\(sample.gravity.z)
        userAcceleration.x=\(sample.userAcceleration.x)
        userAcceleration.y=\(sample.userAcceleration.y)
        userAcceleration.z=\(sample.userAcceleration.z)
        movementMagnitude=\(sample.derived.movementMagnitude)
        updateFrequencyHz=\(sample.derived.updateFrequencyHz)
        """

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snapshotText, forType: .string)
    }

    func exportCSV(samples: [SensorSampleModel], metadata: ExportMetadata) throws {
        guard !samples.isEmpty else {
            throw ExportServiceError.noSamples
        }

        let header = [
            "timestamp",
            "roll",
            "pitch",
            "yaw",
            "rotation_x",
            "rotation_y",
            "rotation_z",
            "gravity_x",
            "gravity_y",
            "gravity_z",
            "user_accel_x",
            "user_accel_y",
            "user_accel_z",
            "head_tilt",
            "nod_angle",
            "shake_angle",
            "movement_magnitude",
            "update_hz"
        ].joined(separator: ",")

        let rows = samples.map { sample in
            [
                sample.timestamp.ISO8601Format(),
                String(sample.attitude.roll),
                String(sample.attitude.pitch),
                String(sample.attitude.yaw),
                String(sample.rotationRate.x),
                String(sample.rotationRate.y),
                String(sample.rotationRate.z),
                String(sample.gravity.x),
                String(sample.gravity.y),
                String(sample.gravity.z),
                String(sample.userAcceleration.x),
                String(sample.userAcceleration.y),
                String(sample.userAcceleration.z),
                String(sample.derived.headTilt),
                String(sample.derived.nodAngle),
                String(sample.derived.shakeAngle),
                String(sample.derived.movementMagnitude),
                String(sample.derived.updateFrequencyHz)
            ].joined(separator: ",")
        }

        let metadataRow = "# exportedAt=\(metadata.exportedAt.ISO8601Format()),sampleRateHz=\(metadata.sampleRateHz),sampleCount=\(metadata.sampleCount),connection=\(metadata.availabilityState.connectionState.rawValue),authorization=\(metadata.availabilityState.authorizationState.rawValue),motionAvailable=\(metadata.availabilityState.isHeadphoneMotionAvailable)"

        let content = ([metadataRow, header] + rows).joined(separator: "\n")
        try save(content: content, suggestedFileName: "airpods_motion_export", fileExtension: "csv")
    }

    func exportJSON(samples: [SensorSampleModel], metadata: ExportMetadata) throws {
        guard !samples.isEmpty else {
            throw ExportServiceError.noSamples
        }

        let payload = ExportPayload(metadata: metadata, samples: samples)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        guard let content = String(data: data, encoding: .utf8) else {
            throw ExportServiceError.writeFailed("Could not encode JSON as UTF-8.")
        }

        try save(content: content, suggestedFileName: "airpods_motion_export", fileExtension: "json")
    }

    func exportGestureBackup(_ payload: GestureBackupPayload) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        guard let content = String(data: data, encoding: .utf8) else {
            throw ExportServiceError.writeFailed("Could not encode backup JSON as UTF-8.")
        }

        try save(content: content, suggestedFileName: "airpod_control_gesture_backup", fileExtension: "json")
    }

    func importGestureBackup() throws -> GestureBackupPayload {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Restore"
        panel.title = "Restore Gesture Backup"

        guard panel.runModal() == .OK, let fileURL = panel.url else {
            throw ExportServiceError.cancelled
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ExportServiceError.readFailed(error.localizedDescription)
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(GestureBackupPayload.self, from: data)
            guard payload.schema == 1 else {
                throw ExportServiceError.invalidBackup("Unsupported schema \(payload.schema).")
            }
            return payload
        } catch let exportError as ExportServiceError {
            throw exportError
        } catch {
            throw ExportServiceError.invalidBackup(error.localizedDescription)
        }
    }

    private func save(content: String, suggestedFileName: String, fileExtension: String) throws {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(suggestedFileName).\(fileExtension)"
        panel.allowedContentTypes = [contentType(for: fileExtension)]

        guard panel.runModal() == .OK, let fileURL = panel.url else {
            throw ExportServiceError.cancelled
        }

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            throw ExportServiceError.writeFailed(error.localizedDescription)
        }
    }

    private func contentType(for fileExtension: String) -> UTType {
        switch fileExtension.lowercased() {
        case "csv":
            return UTType.commaSeparatedText
        case "json":
            return UTType.json
        default:
            return UTType.plainText
        }
    }
}

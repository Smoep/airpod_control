import Foundation

struct ExportMetadata: Codable {
    let exportedAt: Date
    let startTimestamp: Date?
    let endTimestamp: Date?
    let sampleRateHz: Double
    let availabilityState: AvailabilityState
    let sampleCount: Int
}

struct ExportPayload: Codable {
    let metadata: ExportMetadata
    let samples: [SensorSampleModel]
}

struct GestureBackupPayload: Codable {
    let schema: Int
    let exportedAt: Date
    let appRevision: String
    let gestures: [AirGestureDefinition]
    let recognitionSettings: AirGestureRecognitionSettings
    let appearanceSettings: AirGestureAppearanceSettings

    init(
        schema: Int = 1,
        exportedAt: Date = Date(),
        appRevision: String,
        gestures: [AirGestureDefinition],
        recognitionSettings: AirGestureRecognitionSettings,
        appearanceSettings: AirGestureAppearanceSettings
    ) {
        self.schema = schema
        self.exportedAt = exportedAt
        self.appRevision = appRevision
        self.gestures = gestures
        self.recognitionSettings = recognitionSettings
        self.appearanceSettings = appearanceSettings
    }
}

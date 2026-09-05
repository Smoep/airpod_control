import AppKit
import Carbon
import Foundation
import Observation
import OSLog

enum AlwaysOnGateDisplayState: String, Equatable {
    case inactive = "Idle"
    case waiting = "Neutral"
    case slow = "Slow"
    case capturing = "Capture"
    case resetting = "Reset"
}

enum AlwaysOnStartGate {
    static func shouldStartCandidate(
        poseDistance: Double,
        angularSpeed: Double,
        startThreshold: Double,
        speedThreshold: Double
    ) -> Bool {
        poseDistance >= startThreshold && angularSpeed >= speedThreshold
    }

    static func displayState(
        poseDistance: Double,
        angularSpeed: Double,
        startThreshold: Double,
        speedThreshold: Double
    ) -> AlwaysOnGateDisplayState {
        guard poseDistance >= startThreshold else { return .waiting }
        guard angularSpeed >= speedThreshold else { return .slow }
        return .capturing
    }

    static func shouldRefreshSlowDriftNeutral(
        poseDistance: Double,
        angularSpeed: Double,
        startThreshold: Double,
        speedThreshold: Double,
        slowDuration: TimeInterval,
        settleDuration: TimeInterval
    ) -> Bool {
        displayState(
            poseDistance: poseDistance,
            angularSpeed: angularSpeed,
            startThreshold: startThreshold,
            speedThreshold: speedThreshold
        ) == .slow && slowDuration >= settleDuration
    }
}

@Observable
@MainActor
final class LiveSensorStore {
    private let motionService = MotionSensorService()
    private let availabilityService = AirPodsAvailabilityService()
    private let exportService = ExportService()
    private let gestureStore = AirGestureStore.shared

    @ObservationIgnored private var allSamples: [SensorSampleModel] = []
    @ObservationIgnored private var previousSampleTimestamp: Date?
    @ObservationIgnored private var previousDeviceTimestamp: TimeInterval?
    @ObservationIgnored private var noSampleWatchdogTask: Task<Void, Never>?
    @ObservationIgnored private var streamStartTimestamp: Date?
    @ObservationIgnored private var maxSamples: Int = 4_000

    @ObservationIgnored private var activationBaselineAttitude: AttitudeValue?
    @ObservationIgnored private var previousAttitudeForGestures: AttitudeValue?
    @ObservationIgnored private var projectedGesturePoint = AirGesturePoint(x: 0.5, y: 0.5, timestamp: 0)
    @ObservationIgnored private var detectionPath: [AirGesturePoint] = []
    @ObservationIgnored private var detectionLastMotionTimestamp: Date?
    @ObservationIgnored private var continuousStepIndexByGesture: [UUID: Int] = [:]
    @ObservationIgnored private var didFireContinuousGestureInActivationSession = false
    @ObservationIgnored private var recordingPath: [AirGesturePoint] = []
    @ObservationIgnored private var recordingStartUptime: TimeInterval?
    @ObservationIgnored private var previousActivationState = false
    @ObservationIgnored private var isAlwaysOnWaitingForNeutral = false
    @ObservationIgnored private var alwaysOnNeutralSince: Date?
    @ObservationIgnored private var alwaysOnResetStartedAt: Date?
    @ObservationIgnored private var alwaysOnNeutralCandidateReason: String?
    @ObservationIgnored private var alwaysOnCooldownStartedAt: Date?
    @ObservationIgnored private var alwaysOnCaptureStartedAt: Date?
    @ObservationIgnored private var alwaysOnCalmSince: Date?
    @ObservationIgnored private var alwaysOnPreRollPath: [AirGesturePoint] = []
    @ObservationIgnored private var alwaysOnGesturePeakDistance: Double = 0
    @ObservationIgnored private var alwaysOnGesturePeakSpeed: Double = 0
    @ObservationIgnored private var alwaysOnRequiresReturnFromPeak = false
    @ObservationIgnored private var alwaysOnReturnAxisMask = 0
    // lastGestureMotionTimestamp removed — recenter idle timer now uses detectionLastMotionTimestamp.
    @ObservationIgnored private var fnPressedSampleCount = 0
    @ObservationIgnored private var fnReleasedSampleCount = 0
    @ObservationIgnored private var isFnActivationPressed = false
    @ObservationIgnored private var lastPublishedSampleUptime: TimeInterval = 0
    @ObservationIgnored private let publishedSampleInterval: TimeInterval = 0.2

    private let fnActivationDebounceSamples = 4
    private let minimumDiscreteMatchMargin = 0.10
    private let alwaysOnPreRollDuration: TimeInterval = 0.15
    private let alwaysOnRearmCalmDuration: TimeInterval = 0.25
    private let alwaysOnMaximumCaptureDuration: TimeInterval = 0.90
    private let streamStartupNoSampleTimeout: TimeInterval = 2.0
    private let streamStaleSampleTimeout: TimeInterval = 4.0
    private let alwaysOnReturnAxisYaw = 1
    private let alwaysOnReturnAxisPitch = 2
    private let alwaysOnReturnAxisRoll = 4
    private let calibrationGestureNames = [
        "CAL 01 Right",
        "CAL 02 Down",
        "CAL 03 Roll Right",
        "CAL 04 Right Down",
        "CAL 05 Down Right",
        "CAL 06 Right Down Up",
        "CAL 07 Circle CW"
    ]

    var streamState: StreamState = .stopped
    var samplingMode: SamplingMode = .hz60
    var lastUpdateTimestamp: Date?
    var latestSample: SensorSampleModel?
    var statusMessage: String = "Ready"
    var errorMessage: String?
    var exportDurationSeconds: Double = 15

    var gestures: [AirGestureDefinition] = []
    var recognitionSettings = AirGestureRecognitionSettings()
    var appearanceSettings = AirGestureAppearanceSettings()
    var debugMode: Bool = false
    var verboseDebugMode: Bool = false

    var isGestureDetectionEnabled: Bool = true
    var isRecordingGestureArmed: Bool = false
    var isRecordingGestureActive: Bool = false
    var isActivationActive: Bool = false
    var rawFnActivationState: Bool = false
    var isContinuousRecognitionSuppressed: Bool = false
    // Per-frame computation state. Marked @ObservationIgnored so that writes during the
    // 60-120 Hz motion pipeline do NOT trigger SwiftUI observation invalidations. Views
    // never read these directly anymore — they read the throttled debug snapshot strings.
    @ObservationIgnored var liveRelativeYaw: Double = 0
    @ObservationIgnored var liveRelativePitch: Double = 0
    @ObservationIgnored var liveRelativeRoll: Double = 0
    // Head translation (in metres) integrated from userAcceleration. Only meaningful for
    // short impulse gestures — accumulates drift over time and decays back to zero when
    // head is still. Reset to zero on every activation begin.
    @ObservationIgnored var liveHeadTranslationX: Double = 0
    @ObservationIgnored var liveHeadTranslationY: Double = 0
    @ObservationIgnored var liveHeadTranslationZ: Double = 0
    @ObservationIgnored private var translationVelocityX: Double = 0
    @ObservationIgnored private var translationVelocityY: Double = 0
    @ObservationIgnored private var translationVelocityZ: Double = 0
    @ObservationIgnored private var lastTranslationUptime: TimeInterval?
    var lastContinuousGestureName: String = "-"
    var lastContinuousTriggerName: String = "-"
    var lastContinuousStepIndex: Int = 0
    var continuousFireCount: Int = 0

    var gestureDraftName: String = ""
    var gestureDraftInputType: AirGestureInputType = .discrete
    var gestureDraftAxis: AirGestureAxis = .yaw
    var gestureDraftSensitivity: Double = 5
    var gestureDraftTrigger = GestureTrigger(type: .openApp)
    var gestureDraftReverseTrigger = GestureTrigger(type: .windowAction, windowAction: .leftHalf)
    var gestureDraftSamples: [AirGestureSample] = []
    var editingGestureID: UUID? = nil

    var gestureRecordingPointCount: Int = 0
    var lastRecognizedGestureName: String = "-"
    var lastRecognizedGestureScore: Double = 0
    /// True when the most recent discrete evaluation passed the confidence threshold
    /// AND the trigger was dispatched. The Gestures UI uses this to distinguish
    /// "matched but below threshold" from "matched and executed".
    var lastRecognizedGestureExecuted: Bool = false
    var calibrationTargetGestureID: UUID? = nil
    /// Most recent action-execution outcome shown on a status pill so the user can
    /// distinguish "gesture matched but blocked by threshold" vs "action dispatched
    /// but failed" vs "action dispatched OK". Updated by GestureTriggerExecutor.
    var lastActionStatus: String = "-"

    var liveHeadPoint: AirGesturePoint = AirGesturePoint(x: 0.5, y: 0.5, timestamp: 0)
    /// High-frequency mutation during motion pipeline; no views read this directly.
    /// Marked @ObservationIgnored to prevent progressive SwiftUI invalidation.
    @ObservationIgnored var liveHeadTrail: [AirGesturePoint] = []
    // Throttled snapshot of head attitude (radians) used to drive the globe overlay.
    // Published at the same rate as liveHeadPoint (~30 Hz) to keep the overlay smooth
    // without saturating SwiftUI invalidation.
    var liveHeadAttitudeRoll: Double = 0
    var liveHeadAttitudePitch: Double = 0
    var liveHeadAttitudeYaw: Double = 0
    /// Internal low-pass state for the globe overlay so the Responsiveness slider
    /// has a visible effect on globe motion (lower alpha => more smoothing/lag).
    @ObservationIgnored private var smoothedGlobeRoll: Double = 0
    @ObservationIgnored private var smoothedGlobePitch: Double = 0
    @ObservationIgnored private var smoothedGlobeYaw: Double = 0
    /// Throttled snapshot of head translation (metres). Updated alongside the
    /// attitude snapshot so SwiftUI views (e.g. the recording canvas) can observe
    /// translation activity without subscribing to the per-frame internal state.
    var liveHeadTranslationSnapshotX: Double = 0
    var liveHeadTranslationSnapshotY: Double = 0
    var liveHeadTranslationSnapshotZ: Double = 0
    var alwaysOnGateDisplayState: AlwaysOnGateDisplayState = .inactive
    var alwaysOnGateDistanceProgress: Double = 0
    var alwaysOnGateSpeedProgress: Double = 0
    var alwaysOnGateDistance: Double = 0
    var alwaysOnGateSpeed: Double = 0

    // Throttled display snapshots — these are formatted strings/values updated at most
    // ~5 Hz from the per-frame pipeline. The debug card binds to these instead of the
    // raw 60-100 Hz state so SwiftUI does not rebuild the heavy GlassCard body on every
    // motion sample. Without this, repeated Fn activations cause progressive UI slowdown
    // because layout/text caches grow per unique value string and SwiftUI invalidation
    // becomes the dominant main-queue cost.
    var debugCursorXY: String = "0.500 / 0.500"
    var debugRelativeYPR: String = "0.000 / 0.000 / 0.000"
    var debugSensorHz: String = "-"
    /// Recomputed at ~5 Hz; no views read this directly. Marked @ObservationIgnored
    /// to prevent progressive invalidation from accumulating over time.
    @ObservationIgnored var continuousDebugSummaries: [String] = []
    @ObservationIgnored private var lastDebugSnapshotUptime: TimeInterval = 0
    private let debugSnapshotInterval: TimeInterval = 0.2
    @ObservationIgnored private var lastLiveHeadPublishUptime: TimeInterval = 0
    @ObservationIgnored private var lastAlwaysOnGatePublishUptime: TimeInterval = 0
    @ObservationIgnored private var lastRecordingStatusUptime: TimeInterval = 0
    /// Throttle recording UI diagnostic writes (status string + point count) to ~10 Hz.
    /// These updates happen for every motion sample (~100 Hz) which floods @Observable
    /// with main-queue invalidations — the live globe / AxisTrace updates compete on the
    /// same queue and start visibly lagging. The diagnostics don't need per-frame
    /// precision; the matcher still sees every captured point in `recordingPath`.
    private let recordingStatusInterval: TimeInterval = 0.1
    /// How often the live head pose snapshot is republished to SwiftUI. This is the
    /// real upper bound on overlay/globe responsiveness. Keep this below sensor rate:
    /// publishing every motion frame feeds SwiftUI/Canvas too many unique values and
    /// recreates the progressive slowdown that eventually makes the app feel wedged.
    private let liveHeadPublishInterval: TimeInterval = 1.0 / 30.0

    var streamDiagnostics: String {
        let availability = availabilityState
        return "Authorization: \(availability.authorizationState.rawValue), Motion available: \(availability.isHeadphoneMotionAvailable ? "yes" : "no"), Connection: \(availability.connectionState.rawValue)"
    }

    var recentSamples: [SensorSampleModel] {
        allSamples.suffix(240)
    }

    var exportableSamples: [SensorSampleModel] {
        guard let latestSample else { return [] }
        let windowStart = latestSample.timestamp.addingTimeInterval(-exportDurationSeconds)
        return allSamples.filter { $0.timestamp >= windowStart }
    }

    var availabilityState: AvailabilityState {
        let snapshot = availabilityService.snapshot(
            from: motionService,
            streamState: streamState,
            lastUpdateTimestamp: lastUpdateTimestamp
        )

        return AvailabilityState(
            isHeadphoneMotionAvailable: snapshot.isHeadphoneMotionAvailable,
            authorizationState: snapshot.authorizationState,
            connectionState: snapshot.connectionState,
            lastUpdateTimestamp: lastUpdateTimestamp
        )
    }

    var shouldShowHeadOverlay: Bool {
        appearanceSettings.showOverlayWhenActive
            && streamState == .active
            && (isRecordingGestureArmed || isRecordingGestureActive || (isGestureDetectionEnabled && isActivationActive))
    }

    var recordingPreviewPath: [AirGesturePoint] {
        if isRecordingGestureActive || isRecordingGestureArmed {
            return recordingPath
        }
        return liveHeadTrail
    }

    private func recomputeContinuousDebugSummaries() -> [String] {
        gestures
            .filter { $0.inputType == .continuous && $0.isEnabled }
            .map { gesture in
                let liveDisplacement = continuousDisplacement(
                    for: gesture,
                    relativeYaw: liveRelativeYaw,
                    relativePitch: liveRelativePitch,
                    relativeRoll: liveRelativeRoll
                )
                let liveStepIndex = continuousStepIndex(
                    for: gesture,
                    relativeYaw: liveRelativeYaw,
                    relativePitch: liveRelativePitch,
                    relativeRoll: liveRelativeRoll
                )
                let committedStepIndex = continuousStepIndexByGesture[gesture.id, default: 0]
                let threshold = gesture.continuousStepThreshold
                return "\(gesture.name) · \(gesture.axis.rawValue) · live \(liveDisplacement.formatted(.number.precision(.fractionLength(3)))) · live step \(liveStepIndex) · committed step \(committedStepIndex) · threshold \(threshold.formatted(.number.precision(.fractionLength(3))))"
            }
    }

    init() {
        debugMode = gestureStore.loadDebugMode()
        verboseDebugMode = gestureStore.loadVerboseDebugMode()
        DebugFileLog.setEnabled(debugMode, reason: "settings_load")
        DebugFileLog.setVerboseEnabled(verboseDebugMode, reason: "settings_load")
        gestures = gestureStore.load()
        recognitionSettings = gestureStore.loadRecognitionSettings()
        appearanceSettings = gestureStore.loadAppearanceSettings()
        isGestureDetectionEnabled = gestureStore.loadTrackingEnabled()
        seedCalibrationGestureSetIfNeeded()
        let permissionSnapshot = ActionPermissionService.currentSnapshot()
        dbgLog("LIFECYCLE settings_load gestures=\(gestures.count) tracking=\(isGestureDetectionEnabled) debugMode=\(debugMode) activationLayer=\(recognitionSettings.activationLayer.rawValue) accessibility=\(permissionSnapshot.accessibilityGranted) post_events=\(permissionSnapshot.postEventsGranted) input_monitoring=\(permissionSnapshot.inputMonitoringGranted)")
    }

    func startStreaming() {
        dbgLog("ENTRY start_streaming mode=\(samplingMode.rawValue) diagnostics=\(streamDiagnostics)")
        if case .active = streamState { return }

        errorMessage = nil
        lastUpdateTimestamp = nil
        previousSampleTimestamp = nil
        resetGestureTrackingRuntime()
        streamState = .starting
        streamStartTimestamp = Date()
        statusMessage = "Starting stream... \(streamDiagnostics)"

        do {
            try motionService.startStreaming(
                onMotion: { [weak self] packet in
                    self?.processMotionSample(packet)
                },
                onError: { [weak self] error in
                    dbgLog("BAIL start_streaming reason=motion_callback_error error=\(error.localizedDescription)")
                    self?.streamState = .error(error.localizedDescription)
                    self?.statusMessage = "Stream error. \(self?.streamDiagnostics ?? "")"
                    self?.errorMessage = self?.friendlyMessage(for: error) ?? error.localizedDescription
                }
            )
            startNoSampleWatchdog()
            dbgLog("DONE start_streaming state=starting")
        } catch {
            streamState = .error(error.localizedDescription)
            statusMessage = "Unable to start"
            if let motionError = error as? MotionSensorError {
                errorMessage = friendlyMessage(for: motionError)
            } else {
                errorMessage = error.localizedDescription
            }
            dbgLog("BAIL start_streaming reason=throw error=\(error.localizedDescription) diagnostics=\(streamDiagnostics)")
        }
    }

    func stopStreaming() {
        dbgLog("ENTRY stop_streaming state=\(streamState.label)")
        motionService.stopStreaming()
        stopNoSampleWatchdog()
        streamStartTimestamp = nil
        resetGestureTrackingRuntime()
        streamState = .stopped
        statusMessage = "Streaming stopped"
        dbgLog("DONE stop_streaming state=stopped")
    }

    func reconnectMotionInput() {
        dbgLog("ENTRY reconnect_motion_input tracking=\(isGestureDetectionEnabled) state=\(streamState.label)")
        if !isGestureDetectionEnabled {
            setTrackingEnabled(true)
            dbgLog("DONE reconnect_motion_input result=tracking_enabled")
            return
        }

        stopStreaming()
        motionService.resetManager(reason: "manual_reconnect")
        startStreaming()
        dbgLog("DONE reconnect_motion_input result=restarted")
    }

    func armGestureRecording() {
        guard gestureDraftInputType == .discrete else { return }
        errorMessage = nil
        ensureMotionInputRunningForRecording()
        recenterGesturePreviewToCurrentHead()
        isRecordingGestureArmed = true
        isRecordingGestureActive = false
        recordingPath.removeAll(keepingCapacity: true)
        recordingStartUptime = nil
        lastRecordingStatusUptime = 0
        gestureRecordingPointCount = 0
        statusMessage = "Recording — move your head now."
    }

    func beginEditingGesture(_ id: UUID) {
        guard let gesture = gestures.first(where: { $0.id == id }) else { return }
        recenterGesturePreviewToCurrentHead()
        calibrationTargetGestureID = id
        editingGestureID = id
        gestureDraftName = gesture.name
        gestureDraftInputType = gesture.inputType
        gestureDraftAxis = gesture.axis
        gestureDraftSensitivity = gesture.sensitivity
        gestureDraftTrigger = normalizedTrigger(gesture.trigger)
        gestureDraftReverseTrigger = normalizedTrigger(gesture.reverseTrigger ?? GestureTrigger(type: .windowAction, windowAction: .leftHalf))
        gestureDraftSamples = gesture.samples
        statusMessage = "Editing gesture \"\(gesture.name)\""
    }

    func clearGestureDraft() {
        recenterGesturePreviewToCurrentHead()
        editingGestureID = nil
        gestureDraftName = ""
        gestureDraftInputType = .discrete
        gestureDraftAxis = .yaw
        gestureDraftSensitivity = 5
        gestureDraftTrigger = GestureTrigger(type: .openApp)
        gestureDraftReverseTrigger = GestureTrigger(type: .windowAction, windowAction: .leftHalf)
        gestureDraftSamples = []
    }

    func cancelGestureRecording() {
        isRecordingGestureArmed = false
        isRecordingGestureActive = false
        recordingPath.removeAll(keepingCapacity: true)
        recordingStartUptime = nil
        gestureRecordingPointCount = 0
        statusMessage = "Recording cancelled"
        stopMotionInputIfTrackingPaused()
    }

    func stopGestureRecordingAndSave() {
        guard isRecordingGestureArmed || isRecordingGestureActive else { return }
        errorMessage = nil
        isRecordingGestureArmed = false
        isRecordingGestureActive = false

        guard recordingPath.count >= 16 else {
            statusMessage = "Recording too short"
            errorMessage = "Need more movement points. Move your head in a clear pattern for a bit longer."
            recordingPath.removeAll(keepingCapacity: true)
            gestureRecordingPointCount = 0
            stopMotionInputIfTrackingPaused()
            return
        }

        let sampleIndex = gestureDraftSamples.count + 1
        let sampleName = gestureDraftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(draft)" : gestureDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        dbgLog("GESTURE_SAMPLE name=\"\(sampleName)\" index=\(sampleIndex) \(gesturePathSummary(recordingPath))")

        let sample = AirGestureSample(points: recordingPath)
        gestureDraftSamples.append(sample)

        recordingPath.removeAll(keepingCapacity: true)
        recordingStartUptime = nil
        gestureRecordingPointCount = 0
        statusMessage = "Added recording #\(gestureDraftSamples.count). Save gesture when ready."
        stopMotionInputIfTrackingPaused()
    }

    func removeDraftSample(_ id: UUID) {
        gestureDraftSamples.removeAll { $0.id == id }
    }

    func saveDiscreteGestureDraft() {
        errorMessage = nil
        guard !gestureDraftSamples.isEmpty else {
            errorMessage = "Record at least one sample before saving this gesture."
            return
        }

        let trimmedName = gestureDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? "Gesture \(gestures.count + 1)" : trimmedName

        let didUpdate = upsertGestureDraft(
            name: name,
            inputType: .discrete,
            samples: gestureDraftSamples,
            reverseTrigger: nil
        )

        persistGestures()
        statusMessage = didUpdate
            ? "Updated gesture \"\(name)\" with \(gestureDraftSamples.count) recording(s)."
            : "Saved gesture \"\(name)\" with \(gestureDraftSamples.count) recording(s)."
    }

    func saveContinuousGestureDraft() {
        errorMessage = nil
        let trimmedName = gestureDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? "Continuous \(gestures.count + 1)" : trimmedName

        let didUpdate = upsertGestureDraft(
            name: name,
            inputType: .continuous,
            samples: [],
            reverseTrigger: gestureDraftReverseTrigger
        )

        persistGestures()
        statusMessage = didUpdate
            ? "Updated continuous gesture \"\(name)\""
            : "Saved continuous gesture \"\(name)\""
    }

    func recenterGesturePreviewToCurrentHead() {
        let uptime = ProcessInfo.processInfo.systemUptime
        if let latestSample {
            beginActivationSession(with: latestSample.attitude, uptime: uptime)
        } else {
            projectedGesturePoint = AirGesturePoint(x: 0.5, y: 0.5, timestamp: uptime)
            liveHeadPoint = projectedGesturePoint
            resetLiveVisualSnapshots()
            liveHeadTrail.removeAll(keepingCapacity: true)
        }
    }

    func deleteGesture(_ gestureID: UUID) {
        gestures.removeAll { $0.id == gestureID }
        continuousStepIndexByGesture[gestureID] = nil
        if calibrationTargetGestureID == gestureID {
            calibrationTargetGestureID = gestures.first?.id
        }
        persistGestures()
    }

    func toggleGesture(_ gestureID: UUID, isEnabled: Bool) {
        guard let index = gestures.firstIndex(where: { $0.id == gestureID }) else { return }
        gestures[index].isEnabled = isEnabled
        gestures[index].updatedAt = Date()
        persistGestures()
    }

    func resetToCalibrationGestureSet() {
        gestures = calibrationGestureSet()
        calibrationTargetGestureID = gestures.first?.id
        persistGestures()
        statusMessage = "Loaded calibration gesture set"
        errorMessage = nil
        dbgLog("STATE calibration_set_loaded count=\(gestures.count) source=user_action")
    }

    func persistRecognitionSettings() {
        guard gestureStore.saveRecognitionSettings(recognitionSettings) else {
            statusMessage = "Settings save failed"
            errorMessage = "Could not save recognition settings. See \(DebugFileLog.logPath) for details."
            return
        }
        dbgLog("STATE settings_saved kind=recognition activationLayer=\(recognitionSettings.activationLayer.rawValue) scale=\(recognitionSettings.movementScale) confidence=\(recognitionSettings.confidenceThreshold) alwaysOnStart=\(recognitionSettings.alwaysOnStartThreshold) alwaysOnSpeed=\(recognitionSettings.alwaysOnGestureSpeed)rad_s calmMotion=\(recognitionSettings.motionThreshold) alwaysOnFinish=\(recognitionSettings.alwaysOnFinishDelay)s alwaysOnReturn=\(recognitionSettings.alwaysOnReturnToNeutralRadius) alwaysOnSettle=\(recognitionSettings.alwaysOnNeutralSettleDuration)s")
    }

    func persistAppearanceSettings() {
        guard gestureStore.saveAppearanceSettings(appearanceSettings) else {
            statusMessage = "Settings save failed"
            errorMessage = "Could not save overlay settings. See \(DebugFileLog.logPath) for details."
            return
        }
        dbgLog("STATE settings_saved kind=appearance overlay=\(appearanceSettings.showOverlayWhenActive) trail=\(appearanceSettings.showTrail) opacity=\(appearanceSettings.overlayOpacity) scale=\(appearanceSettings.overlayScale)")
    }

    func persistDebugMode() {
        DebugFileLog.setEnabled(debugMode, reason: "settings_toggle")
    }

    func persistVerboseDebugMode() {
        DebugFileLog.setVerboseEnabled(verboseDebugMode, reason: "settings_toggle")
    }

    func setTrackingEnabled(_ enabled: Bool) {
        guard isGestureDetectionEnabled != enabled else { return }

        isGestureDetectionEnabled = enabled
        gestureStore.saveTrackingEnabled(enabled)
        if enabled {
            startStreaming()
        } else {
            stopStreaming()
            lastRecognizedGestureExecuted = false
            lastActionStatus = "Tracking off"
        }
        statusMessage = enabled ? "Tracking enabled" : "Tracking paused"
        dbgLog("STATE tracking enabled=\(enabled)")
    }

    func clearDebugLog() {
        DebugFileLog.clearLog(reason: "settings_button")
        statusMessage = "Debug log cleared"
    }

    func clearGestureCorpus() {
        DebugFileLog.clearGestureCorpus(reason: "settings_button")
        statusMessage = "Gesture corpus cleared"
    }

    func resetGestureSettingsToDefaults() {
        recognitionSettings = AirGestureRecognitionSettings()
        appearanceSettings = AirGestureAppearanceSettings()
        persistRecognitionSettings()
        persistAppearanceSettings()
        statusMessage = "Gesture settings reset to defaults"
        errorMessage = nil
        GestureDiagnostics.logger.notice("settings_reset")
        dbgLog("STATE settings_reset recognition=default appearance=default")
    }

    func copyCurrentSnapshot() {
        guard let latestSample else {
            errorMessage = "No sample available to copy."
            return
        }
        exportService.copySnapshot(latestSample, availabilityState: availabilityState)
        statusMessage = "Copied snapshot to clipboard"
    }

    func exportCSV() {
        do {
            let samples = exportableSamples
            let metadata = buildExportMetadata(samples: samples)
            try exportService.exportCSV(samples: samples, metadata: metadata)
            statusMessage = "CSV export complete"
        } catch {
            if let exportError = error as? ExportServiceError, exportError == .cancelled {
                statusMessage = "CSV export cancelled"
            } else {
                errorMessage = error.localizedDescription
                statusMessage = "CSV export failed"
            }
        }
    }

    func exportJSON() {
        do {
            let samples = exportableSamples
            let metadata = buildExportMetadata(samples: samples)
            try exportService.exportJSON(samples: samples, metadata: metadata)
            statusMessage = "JSON export complete"
        } catch {
            if let exportError = error as? ExportServiceError, exportError == .cancelled {
                statusMessage = "JSON export cancelled"
            } else {
                errorMessage = error.localizedDescription
                statusMessage = "JSON export failed"
            }
        }
    }

    func exportGestureBackup() {
        do {
            let payload = GestureBackupPayload(
                appRevision: AppRevision.current,
                gestures: gestures,
                recognitionSettings: recognitionSettings,
                appearanceSettings: appearanceSettings
            )
            try exportService.exportGestureBackup(payload)
            statusMessage = "Gesture backup exported"
            errorMessage = nil
            dbgLog("DONE export_gesture_backup gestures=\(gestures.count) revision=\(AppRevision.current)")
        } catch {
            if let exportError = error as? ExportServiceError, exportError == .cancelled {
                statusMessage = "Gesture backup export cancelled"
            } else {
                errorMessage = error.localizedDescription
                statusMessage = "Gesture backup export failed"
                dbgLog("BAIL export_gesture_backup reason=failed error=\(error.localizedDescription)")
            }
        }
    }

    func restoreGestureBackup() {
        do {
            let payload = try exportService.importGestureBackup()
            gestures = payload.gestures
            recognitionSettings = payload.recognitionSettings
            appearanceSettings = payload.appearanceSettings
            calibrationTargetGestureID = gestures.first(where: { $0.inputType == .discrete })?.id
            persistGestures()
            persistRecognitionSettings()
            persistAppearanceSettings()
            statusMessage = "Gesture backup restored"
            errorMessage = nil
            dbgLog("DONE restore_gesture_backup gestures=\(gestures.count) sourceRevision=\(payload.appRevision)")
        } catch {
            if let exportError = error as? ExportServiceError, exportError == .cancelled {
                statusMessage = "Gesture backup restore cancelled"
            } else {
                errorMessage = error.localizedDescription
                statusMessage = "Gesture backup restore failed"
                dbgLog("BAIL restore_gesture_backup reason=failed error=\(error.localizedDescription)")
            }
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func processMotionSample(_ packet: MotionPacket) {
        let now = packet.timestamp
        let deviceDeltaMs = previousDeviceTimestamp.map { (packet.deviceTimestamp - $0) * 1000 }

        let updateFrequencyHz: Double
        if let previousSampleTimestamp {
            let delta = now.timeIntervalSince(previousSampleTimestamp)
            updateFrequencyHz = delta > 0 ? 1.0 / delta : 0
        } else {
            updateFrequencyHz = 0
        }
        self.previousSampleTimestamp = now

        // Rate-limit using hardware capture time (motion.timestamp), not wall-clock Date().
        // When the main queue backs up, multiple CoreMotion callbacks queue and then fire
        // together. With Date() they all share the same wall-clock instant so only the
        // first passes shouldAccept and the cursor appears frozen. With deviceTimestamp
        // each callback carries its true capture time, so all backed-up samples that are
        // sufficiently spaced are accepted and the cursor catches up correctly.
        guard shouldAccept(deviceTimestamp: packet.deviceTimestamp) else {
            dbgVerboseLog(String(format: "BAIL motion_sample reason=rate_limit dt=%.1fms min=%.1fms", deviceDeltaMs ?? 0, samplingMode.minimumInterval * 1000))
            return
        }
        previousDeviceTimestamp = packet.deviceTimestamp

        let sample = SensorSampleModel(
            timestamp: now,
            attitude: packet.attitude,
            rotationRate: packet.rotationRate,
            gravity: packet.gravity,
            userAcceleration: packet.userAcceleration,
            updateFrequencyHz: updateFrequencyHz
        )

        dbgVerboseLog(String(format: "INPUT motion device_t=%.3fs dt=%.1fms hz=%.1f roll=%.5frad pitch=%.5frad yaw=%.5frad rot=(%.5f,%.5f,%.5f)rad/s gravity=(%.4f,%.4f,%.4f)g accel=(%.4f,%.4f,%.4f)g", packet.deviceTimestamp, deviceDeltaMs ?? 0, updateFrequencyHz, sample.attitude.roll, sample.attitude.pitch, sample.attitude.yaw, sample.rotationRate.x, sample.rotationRate.y, sample.rotationRate.z, sample.gravity.x, sample.gravity.y, sample.gravity.z, sample.userAcceleration.x, sample.userAcceleration.y, sample.userAcceleration.z))

        allSamples.append(sample)
        // Trim in batches of 500 to avoid O(n) array shifting on every sample once the
        // buffer is full (removeFirst(1) at 60 Hz on a 4000-element array = ~240K element
        // copies/sec on the main queue).
        if allSamples.count > maxSamples + 500 {
            allSamples.removeFirst(allSamples.count - maxSamples)
        }

        // Keep the published diagnostic sample throttled. Gesture recognition uses the
        // full-rate local sample below; latestSample is only for explicit diagnostics
        // actions such as copy/export/inspect.
        let nowUptime = ProcessInfo.processInfo.systemUptime
        if nowUptime - lastPublishedSampleUptime >= publishedSampleInterval {
            lastPublishedSampleUptime = nowUptime
            latestSample = sample
            lastUpdateTimestamp = now
        }
        // Avoid reassigning these every motion frame — under @Observable, even
        // same-value writes invalidate observers and rebuild any view reading them.
        if case .active = streamState {} else {
            streamState = .active
            dbgLog("STATE stream starting -> active")
        }
        if statusMessage != "Streaming live" {
            statusMessage = "Streaming live"
        }

        processGesturePipeline(with: sample)
    }

    private func shouldAccept(deviceTimestamp: TimeInterval) -> Bool {
        let minInterval = samplingMode.minimumInterval
        guard minInterval > 0 else { return true }
        guard let prev = previousDeviceTimestamp else { return true }
        return deviceTimestamp - prev >= minInterval
    }

    private func startNoSampleWatchdog() {
        stopNoSampleWatchdog()

        noSampleWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.evaluateNoSampleState()
            }
        }
    }

    private func stopNoSampleWatchdog() {
        noSampleWatchdogTask?.cancel()
        noSampleWatchdogTask = nil
    }

    private func evaluateNoSampleState() {
        switch streamState {
        case .starting:
            guard lastUpdateTimestamp == nil else { return }
            let startedFor = Date().timeIntervalSince(streamStartTimestamp ?? Date())
            guard startedFor >= streamStartupNoSampleTimeout else { return }

            streamState = .error("No samples received after start.")
            statusMessage = "No data received"
            errorMessage = "No samples received after Start Stream. \(streamDiagnostics). If your AirPods are connected, verify Motion & Fitness permission and that headphone motion is supported on the current connection."
            motionService.stopStreaming()
            motionService.resetManager(reason: "no_samples")
            dbgLog(String(format: "BAIL start_streaming reason=no_samples started=%.2fs diagnostics=%@", startedFor, streamDiagnostics))

        case .active:
            guard isGestureDetectionEnabled || isRecordingGestureArmed || isRecordingGestureActive else { return }
            guard let lastUpdateTimestamp else { return }
            let staleFor = Date().timeIntervalSince(lastUpdateTimestamp)
            guard staleFor >= streamStaleSampleTimeout else { return }

            dbgLog(String(format: "WARN motion_stream_stale stale=%.1fs timeout=%.1fs action=reconnect diagnostics=%@", staleFor, streamStaleSampleTimeout, streamDiagnostics))
            reconnectMotionInput()

        case .stopped, .error:
            return
        }
    }

    private func processGesturePipeline(with sample: SensorSampleModel) {
        // Treat sample recording as if activation is on so the recording captures the
        // exact same data (cursor projection + integrated translation) that live
        // detection sees. Without this, recording with no Fn press produced flat
        // x/y/translation and the matcher could never align the two paths.
        let isNowActive = isActivationLayerActive() || isRecordingGestureArmed

        if !previousActivationState && isNowActive {
            dbgLog("STATE idle -> armed layer=\(recognitionSettings.activationLayer.rawValue) recordingArmed=\(isRecordingGestureArmed)")
            beginActivationSession(with: sample.attitude, uptime: ProcessInfo.processInfo.systemUptime)
            // Snap cursor to center immediately so smoothing always starts from a clean
            // neutral position rather than blending from wherever it drifted while inactive.
            projectedGesturePoint = AirGesturePoint(x: 0.5, y: 0.5, timestamp: ProcessInfo.processInfo.systemUptime)
        }

        // Guard same-value @Observable write — isActivationActive only changes on Fn
        // press/release transitions, but isNowActive is computed every frame. Without
        // this guard the Runtime card invalidates 60-120x/sec for no actual change.
        if isActivationActive != isNowActive {
            dbgLog("STATE activation \(isActivationActive ? "active" : "idle") -> \(isNowActive ? "active" : "idle") layer=\(recognitionSettings.activationLayer.rawValue)")
            isActivationActive = isNowActive
        }

        let (deltaYaw, deltaPitch, deltaRoll) = gestureDeltas(from: sample.attitude)
        // Include roll in the motion magnitude so a pure head tilt counts as activity
        // and gets recorded into the detection path. Without this a tilt-only gesture
        // would be discarded as "no motion".
        let motionMagnitude = sqrt((deltaYaw * deltaYaw) + (deltaPitch * deltaPitch) + (deltaRoll * deltaRoll))
        let currentUptime = ProcessInfo.processInfo.systemUptime

        dbgVerboseLog(String(format: "INPUT detection active=%@ recording=%@ dx=%.5frad dy=%.5frad droll=%.5frad magnitude=%.5frad threshold=%.5frad", isNowActive.description, isRecordingGestureArmed.description, deltaYaw, deltaPitch, deltaRoll, motionMagnitude, recognitionSettings.motionThreshold))

        let adjustedRelative = relativeDisplacement(from: sample.attitude)
        liveRelativeYaw = adjustedRelative.0
        liveRelativePitch = adjustedRelative.1
        liveRelativeRoll = adjustedRelative.2

        // Integrate translation from userAcceleration (gravity already removed by
        // CoreMotion). userAcceleration is in g; convert to m/s^2 for human-scale numbers.
        // High-pass via velocity decay fights drift; displacement decay returns to zero
        // when the head is still. This is only useful for short impulse-style gestures.
        updateHeadTranslation(userAcceleration: sample.userAcceleration, uptime: currentUptime, isActive: isNowActive)

        if isNowActive {
            let rawPoint = nextProjectedPoint(relativeYaw: adjustedRelative.0, relativePitch: adjustedRelative.1, uptime: currentUptime)
            projectedGesturePoint = smoothProjectedPoint(from: projectedGesturePoint, to: rawPoint)
            // Throttle liveHeadPoint publishes to ~30 Hz max. Even though projectedGesturePoint
            // is updated every motion frame (so smoothing math is correct), the @Observable
            // publish that drives the overlay cursor .position() update is rate-limited.
            // Without this, every motion frame triggers a SwiftUI layout pass on the overlay,
            // which compounds with Core Animation work and degrades over time.
            if currentUptime - lastLiveHeadPublishUptime >= liveHeadPublishInterval {
                lastLiveHeadPublishUptime = currentUptime
                liveHeadPoint = projectedGesturePoint
                // Publish attitude (relative to baseline) for the globe overlay at the
                // same throttled rate. The globe is rendered as a mirror — when the
                // user turns their head right, the nose/right-ear should move to the
                // viewer's right. CoreMotion yaw rotates the opposite way, so we negate it.
                let scale = min(max(recognitionSettings.movementScale, 0.5), 8.0)
                // Smoothing has been removed from the user-facing settings: globe and
                // cursor publish raw scaled angles every motion frame for a 1:1 feel.
                let alpha = 1.0
                let targetRoll  = -adjustedRelative.2 * scale
                let targetPitch = -adjustedRelative.1 * scale
                let targetYaw   = -adjustedRelative.0 * scale
                smoothedGlobeRoll  += (targetRoll  - smoothedGlobeRoll)  * alpha
                smoothedGlobePitch += (targetPitch - smoothedGlobePitch) * alpha
                smoothedGlobeYaw   += (targetYaw   - smoothedGlobeYaw)   * alpha
                liveHeadAttitudeRoll  = smoothedGlobeRoll
                liveHeadAttitudePitch = smoothedGlobePitch
                liveHeadAttitudeYaw   = smoothedGlobeYaw
                liveHeadTranslationSnapshotX = liveHeadTranslationX
                liveHeadTranslationSnapshotY = liveHeadTranslationY
                liveHeadTranslationSnapshotZ = liveHeadTranslationZ
            }
            updateLiveTrail(point: projectedGesturePoint)
        } else {
            // Keep the projected point at center while inactive so the next activation
            // always starts from a neutral position. Only publish if it actually changed
            // to avoid pointless @Observable invalidations every frame.
            let center = AirGesturePoint(x: 0.5, y: 0.5, timestamp: currentUptime)
            projectedGesturePoint = center
            if liveHeadPoint.x != 0.5 || liveHeadPoint.y != 0.5 {
                liveHeadPoint = center
            }
            if liveHeadAttitudeRoll != 0 || liveHeadAttitudePitch != 0 || liveHeadAttitudeYaw != 0 {
                liveHeadAttitudeRoll = 0
                liveHeadAttitudePitch = 0
                liveHeadAttitudeYaw = 0
            }
            smoothedGlobeRoll = 0
            smoothedGlobePitch = 0
            smoothedGlobeYaw = 0
            if liveHeadTranslationSnapshotX != 0 || liveHeadTranslationSnapshotY != 0 || liveHeadTranslationSnapshotZ != 0 {
                liveHeadTranslationSnapshotX = 0
                liveHeadTranslationSnapshotY = 0
                liveHeadTranslationSnapshotZ = 0
            }
        }

        updateDebugSnapshotsIfDue(uptime: currentUptime, sample: sample)

        if isRecordingGestureArmed {
            dbgVerboseLog("STATE armed -> recording point=(\(String(format: "%.3f", projectedGesturePoint.x))norm,\(String(format: "%.3f", projectedGesturePoint.y))norm)")
            if !isRecordingGestureActive {
                isRecordingGestureActive = true
            }
            appendRecordingPoint(projectedGesturePoint, uptime: currentUptime)
            previousActivationState = isActivationActive
            return
        }

        guard isGestureDetectionEnabled else { return }

        if !isActivationActive {
            if previousActivationState {
                dbgLog("STATE armed -> idle reason=activation_inactive")
                finalizeDiscreteGestures(sampleTimestamp: sample.timestamp, force: true)
            }
            detectionPath.removeAll(keepingCapacity: true)
            detectionLastMotionTimestamp = nil
            continuousStepIndexByGesture.removeAll(keepingCapacity: true)
            didFireContinuousGestureInActivationSession = false
            isContinuousRecognitionSuppressed = false
            previousActivationState = false
            return
        }

        // Build a richer pose-aware point so discrete gesture detection can capture
        // tilt (roll) and translational displacement on top of the 2D cursor location.
        let posePoint = AirGesturePoint(
            x: projectedGesturePoint.x,
            y: projectedGesturePoint.y,
            timestamp: projectedGesturePoint.timestamp,
            yaw: adjustedRelative.0,
            pitch: adjustedRelative.1,
            roll: adjustedRelative.2,
            tx: liveHeadTranslationX,
            ty: liveHeadTranslationY,
            tz: liveHeadTranslationZ
        )

        if recognitionSettings.activationLayer == .alwaysOn {
            let angularSpeed = alwaysOnAngularSpeed(from: sample.rotationRate)
            processAlwaysOnDiscreteGestures(
                sampleTimestamp: sample.timestamp,
                attitude: sample.attitude,
                uptime: currentUptime,
                point: posePoint,
                deltaYaw: deltaYaw,
                deltaPitch: deltaPitch,
                deltaRoll: deltaRoll,
                angularSpeed: angularSpeed
            )
        } else {
            processDiscreteGestures(sampleTimestamp: sample.timestamp, point: posePoint, deltaYaw: deltaYaw, deltaPitch: deltaPitch, deltaRoll: deltaRoll)
        }

        // Continuous recognition is allowed to run, but each step is suppressed if the
        // active path is already a plausible discrete gesture. This prevents one Fn
        // session from dispatching both a continuous shortcut and a release gesture.
        if isContinuousRecognitionSuppressed {
            isContinuousRecognitionSuppressed = false
        }
        if !(recognitionSettings.activationLayer == .alwaysOn && isAlwaysOnWaitingForNeutral) {
            processContinuousGestures(sampleTimestamp: sample.timestamp, relativeYaw: adjustedRelative.0, relativePitch: adjustedRelative.1, relativeRoll: adjustedRelative.2)
        }

        previousActivationState = true
    }

    private func appendRecordingPoint(_ point: AirGesturePoint, uptime: TimeInterval) {
        if recordingStartUptime == nil {
            recordingStartUptime = uptime
        }

        let relativeTimestamp = uptime - (recordingStartUptime ?? uptime)
        // Capture the full head pose (cursor position + roll + translation) so the
        // matcher has every degree of freedom available when comparing later.
        let timedPoint = AirGesturePoint(
            x: point.x,
            y: point.y,
            timestamp: relativeTimestamp,
            yaw: liveRelativeYaw,
            pitch: liveRelativePitch,
            roll: liveRelativeRoll,
            tx: liveHeadTranslationX,
            ty: liveHeadTranslationY,
            tz: liveHeadTranslationZ
        )
        recordingPath.append(timedPoint)

        if recordingPath.count > 1_000 {
            recordingPath.removeFirst(recordingPath.count - 900)
        }

        // Throttle the @Observable diagnostic writes to ~10 Hz so the live globe and
        // axis traces don't compete with hundreds of per-frame SwiftUI invalidations
        // (statusMessage in particular is observed cross-tab and allocates a string).
        if uptime - lastRecordingStatusUptime >= recordingStatusInterval {
            lastRecordingStatusUptime = uptime
            gestureRecordingPointCount = recordingPath.count
            statusMessage = "Recording sample... \(gestureRecordingPointCount) points"
        }
    }

    private func processAlwaysOnDiscreteGestures(
        sampleTimestamp: Date,
        attitude: AttitudeValue,
        uptime: TimeInterval,
        point: AirGesturePoint,
        deltaYaw: Double,
        deltaPitch: Double,
        deltaRoll: Double,
        angularSpeed: Double
    ) {
        let motionMagnitude = motionMagnitudeForDiscrete(deltaYaw: deltaYaw, deltaPitch: deltaPitch, deltaRoll: deltaRoll)
        let poseDistance = alwaysOnDistanceFromNeutral(point)

        if isAlwaysOnWaitingForNeutral {
            publishAlwaysOnGateSnapshot(
                uptime: uptime,
                state: .resetting,
                poseDistance: poseDistance,
                angularSpeed: angularSpeed
            )
            updateAlwaysOnNeutralReset(
                sampleTimestamp: sampleTimestamp,
                attitude: attitude,
                uptime: uptime,
                poseDistance: poseDistance,
                motionMagnitude: motionMagnitude
            )
            return
        }

        if detectionPath.isEmpty {
            updateAlwaysOnPreRoll(with: point)
            let startThreshold = recognitionSettings.alwaysOnStartThreshold
            let speedThreshold = recognitionSettings.alwaysOnGestureSpeed
            let gateState = AlwaysOnStartGate.displayState(
                poseDistance: poseDistance,
                angularSpeed: angularSpeed,
                startThreshold: startThreshold,
                speedThreshold: speedThreshold
            )
            guard gateState == .capturing else {
                publishAlwaysOnGateSnapshot(
                    uptime: uptime,
                    state: gateState,
                    poseDistance: poseDistance,
                    angularSpeed: angularSpeed
                )
                if poseDistance < startThreshold {
                    maybeRefreshAlwaysOnNeutralBaseline(
                        sampleTimestamp: sampleTimestamp,
                        attitude: attitude,
                        uptime: uptime,
                        poseDistance: poseDistance,
                        motionMagnitude: motionMagnitude
                    )
                } else {
                    if maybeRefreshAlwaysOnSlowDriftBaseline(
                        sampleTimestamp: sampleTimestamp,
                        attitude: attitude,
                        uptime: uptime,
                        poseDistance: poseDistance,
                        angularSpeed: angularSpeed
                    ) {
                        return
                    }
                    dbgVerboseLog(String(format: "STATE always_on start_ignored reason=slow distance=%.4f start=%.4f speed=%.3frad_s minSpeed=%.3frad_s", poseDistance, startThreshold, angularSpeed, speedThreshold))
                }
                return
            }
            alwaysOnCalmSince = nil
            alwaysOnNeutralSince = nil
            alwaysOnGesturePeakDistance = poseDistance
            alwaysOnGesturePeakSpeed = angularSpeed
            let seedPath = alwaysOnPreRollPath.dropLast()
            if !seedPath.isEmpty {
                detectionPath = Array(seedPath)
                detectionLastMotionTimestamp = sampleTimestamp
            }
            publishAlwaysOnGateSnapshot(
                uptime: uptime,
                state: .capturing,
                poseDistance: poseDistance,
                angularSpeed: angularSpeed,
                force: true
            )
            dbgLog(String(format: "STATE always_on neutral -> moving distance=%.4f start=%.4f speed=%.3frad_s minSpeed=%.3frad_s", poseDistance, startThreshold, angularSpeed, speedThreshold))
        } else {
            alwaysOnGesturePeakDistance = max(alwaysOnGesturePeakDistance, poseDistance)
            alwaysOnGesturePeakSpeed = max(alwaysOnGesturePeakSpeed, angularSpeed)
            publishAlwaysOnGateSnapshot(
                uptime: uptime,
                state: .capturing,
                poseDistance: poseDistance,
                angularSpeed: angularSpeed
            )
        }

        let wasCollecting = !detectionPath.isEmpty
        processDiscreteGestures(
            sampleTimestamp: sampleTimestamp,
            point: point,
            deltaYaw: deltaYaw,
            deltaPitch: deltaPitch,
            deltaRoll: deltaRoll,
            motionThreshold: recognitionSettings.motionThreshold,
            finalizeDelay: recognitionSettings.alwaysOnFinishDelay
        )

        if wasCollecting && detectionPath.isEmpty {
            isAlwaysOnWaitingForNeutral = true
            alwaysOnNeutralSince = nil
            alwaysOnResetStartedAt = sampleTimestamp
            alwaysOnNeutralCandidateReason = nil
            alwaysOnRequiresReturnFromPeak = lastRecognizedGestureExecuted
            alwaysOnReturnAxisMask = 0
            continuousStepIndexByGesture.removeAll(keepingCapacity: true)
            dbgLog(String(format: "STATE always_on moving -> reset_wait returnRadius=%.4f settle=%.2fs peak=%.4f requiresReturn=%@", recognitionSettings.alwaysOnReturnToNeutralRadius, recognitionSettings.alwaysOnNeutralSettleDuration, alwaysOnGesturePeakDistance, alwaysOnRequiresReturnFromPeak.description))
        }
    }

    private func maybeRefreshAlwaysOnNeutralBaseline(
        sampleTimestamp: Date,
        attitude: AttitudeValue,
        uptime: TimeInterval,
        poseDistance: Double,
        motionMagnitude: Double
    ) {
        let calmThreshold = recognitionSettings.motionThreshold
        guard poseDistance <= recognitionSettings.alwaysOnReturnToNeutralRadius,
              AlwaysOnCalmGate.isCalm(motionMagnitude: motionMagnitude, threshold: calmThreshold) else {
            alwaysOnNeutralSince = nil
            return
        }

        if alwaysOnNeutralSince == nil {
            alwaysOnNeutralSince = sampleTimestamp
        }

        guard let neutralSince = alwaysOnNeutralSince,
              sampleTimestamp.timeIntervalSince(neutralSince) >= recognitionSettings.alwaysOnNeutralSettleDuration,
              poseDistance > 0.015 else {
            return
        }

        beginActivationSession(with: attitude, uptime: uptime)
        alwaysOnNeutralSince = nil
        dbgLog(String(format: "STATE always_on neutral_refreshed distance=%.4f motion=%.4f calmMotion=%.4f", poseDistance, motionMagnitude, calmThreshold))
    }

    private func maybeRefreshAlwaysOnSlowDriftBaseline(
        sampleTimestamp: Date,
        attitude: AttitudeValue,
        uptime: TimeInterval,
        poseDistance: Double,
        angularSpeed: Double
    ) -> Bool {
        if alwaysOnNeutralSince == nil {
            alwaysOnNeutralSince = sampleTimestamp
        }

        guard let neutralSince = alwaysOnNeutralSince else { return false }
        let slowFor = sampleTimestamp.timeIntervalSince(neutralSince)
        guard AlwaysOnStartGate.shouldRefreshSlowDriftNeutral(
            poseDistance: poseDistance,
            angularSpeed: angularSpeed,
            startThreshold: recognitionSettings.alwaysOnStartThreshold,
            speedThreshold: recognitionSettings.alwaysOnGestureSpeed,
            slowDuration: slowFor,
            settleDuration: recognitionSettings.alwaysOnNeutralSettleDuration
        ) else {
            return false
        }

        beginActivationSession(with: attitude, uptime: uptime)
        alwaysOnNeutralSince = nil
        dbgLog(String(format: "STATE always_on slow_drift -> neutral distance=%.4f speed=%.3frad_s minSpeed=%.3frad_s settle=%.2fs", poseDistance, angularSpeed, recognitionSettings.alwaysOnGestureSpeed, recognitionSettings.alwaysOnNeutralSettleDuration))
        return true
    }

    private var alwaysOnCalmSpeedThreshold: Double {
        min(max(recognitionSettings.alwaysOnGestureSpeed * 0.33, 0.20), 0.35)
    }

    private func alwaysOnAngularSpeed(from rotationRate: Vector3Value) -> Double {
        sqrt(
            (rotationRate.x * rotationRate.x)
            + (rotationRate.y * rotationRate.y)
            + (rotationRate.z * rotationRate.z)
        )
    }

    private func publishAlwaysOnGateSnapshot(
        uptime: TimeInterval,
        state: AlwaysOnGateDisplayState,
        poseDistance: Double,
        angularSpeed: Double,
        force: Bool = false
    ) {
        guard force || state != alwaysOnGateDisplayState || uptime - lastAlwaysOnGatePublishUptime >= liveHeadPublishInterval else { return }
        lastAlwaysOnGatePublishUptime = uptime

        let startThreshold = max(recognitionSettings.alwaysOnStartThreshold, 0.0001)
        let speedThreshold = max(recognitionSettings.alwaysOnGestureSpeed, 0.0001)
        alwaysOnGateDisplayState = state
        alwaysOnGateDistance = poseDistance
        alwaysOnGateSpeed = angularSpeed
        alwaysOnGateDistanceProgress = min(max(poseDistance / startThreshold, 0), 1)
        alwaysOnGateSpeedProgress = min(max(angularSpeed / speedThreshold, 0), 1)
    }

    private func updateAlwaysOnPreRoll(with point: AirGesturePoint) {
        alwaysOnPreRollPath.append(point)
        let cutoff = point.timestamp - alwaysOnPreRollDuration
        if let firstKeptIndex = alwaysOnPreRollPath.firstIndex(where: { $0.timestamp >= cutoff }), firstKeptIndex > 0 {
            alwaysOnPreRollPath.removeFirst(firstKeptIndex)
        }
        if alwaysOnPreRollPath.count > 30 {
            alwaysOnPreRollPath.removeFirst(alwaysOnPreRollPath.count - 30)
        }
    }

    private func updateAlwaysOnCooldown(
        sampleTimestamp: Date,
        attitude: AttitudeValue,
        uptime: TimeInterval,
        angularSpeed: Double,
        poseDistance: Double,
        returnDistance: Double
    ) -> Bool {
        guard let cooldownStarted = alwaysOnCooldownStartedAt else { return false }

        let returnRadius = recognitionSettings.alwaysOnReturnToNeutralRadius
        if alwaysOnRequiresReturnFromPeak && returnDistance > returnRadius {
            alwaysOnCalmSince = nil
            if alwaysOnNeutralCandidateReason != "return_required" {
                alwaysOnNeutralCandidateReason = "return_required"
                dbgLog(String(format: "STATE always_on cooldown waiting_for_return returnDistance=%.4f poseDistance=%.4f radius=%.4f axes=%@ speed=%.3frad_s", returnDistance, poseDistance, returnRadius, alwaysOnReturnAxisDescription(alwaysOnReturnAxisMask), angularSpeed))
            }
            return true
        }

        if angularSpeed <= alwaysOnCalmSpeedThreshold {
            if alwaysOnCalmSince == nil {
                alwaysOnCalmSince = sampleTimestamp
            }
        } else {
            alwaysOnCalmSince = nil
        }

        let cooldownFor = sampleTimestamp.timeIntervalSince(cooldownStarted)
        let calmFor = sampleTimestamp.timeIntervalSince(alwaysOnCalmSince ?? sampleTimestamp)
        guard cooldownFor >= recognitionSettings.alwaysOnCooldownDuration,
              calmFor >= alwaysOnRearmCalmDuration else {
            return true
        }

        beginActivationSession(with: attitude, uptime: uptime)
        isAlwaysOnWaitingForNeutral = false
        alwaysOnCooldownStartedAt = nil
        alwaysOnCaptureStartedAt = nil
        alwaysOnCalmSince = nil
        alwaysOnNeutralCandidateReason = nil
        alwaysOnPreRollPath.removeAll(keepingCapacity: true)
        alwaysOnGesturePeakDistance = 0
        alwaysOnGesturePeakSpeed = 0
        alwaysOnRequiresReturnFromPeak = false
        alwaysOnReturnAxisMask = 0
        dbgLog(String(format: "STATE always_on cooldown -> calm cooldown=%.2fs calm=%.2fs speed=%.3frad_s calmThreshold=%.3frad_s distance=%.4f", cooldownFor, calmFor, angularSpeed, alwaysOnCalmSpeedThreshold, poseDistance))
        return true
    }

    private func finalizeAlwaysOnCandidate(sampleTimestamp: Date, reason: String, angularSpeed: Double) {
        let gestureSize = alwaysOnPathAmplitude(detectionPath)
        let pathCount = detectionPath.count
        guard gestureSize >= recognitionSettings.alwaysOnGestureSize else {
            lastRecognizedGestureExecuted = false
            lastRecognizedGestureName = "(too small)"
            lastRecognizedGestureScore = 0
            lastActionStatus = String(format: "Too small (%.3f < %.3f)", gestureSize, recognitionSettings.alwaysOnGestureSize)
            dbgLog(String(format: "DECISION always_on_candidate result=reject reason=too_small path=%d size=%.4f threshold=%.4f peakSpeed=%.3frad_s speed=%.3frad_s", pathCount, gestureSize, recognitionSettings.alwaysOnGestureSize, alwaysOnGesturePeakSpeed, angularSpeed))
            detectionPath.removeAll(keepingCapacity: true)
            detectionLastMotionTimestamp = nil
            enterAlwaysOnCooldown(sampleTimestamp: sampleTimestamp, reason: "too_small", gestureSize: gestureSize)
            return
        }

        let returnAxisMask = alwaysOnReturnAxisMask(for: detectionPath)
        dbgLog(String(format: "STATE always_on capturing -> evaluate reason=%@ path=%d size=%.4f peakSpeed=%.3frad_s", reason, pathCount, gestureSize, alwaysOnGesturePeakSpeed))
        finalizeDiscreteGestures(sampleTimestamp: sampleTimestamp, force: true)
        enterAlwaysOnCooldown(sampleTimestamp: sampleTimestamp, reason: reason, gestureSize: gestureSize, returnAxisMask: returnAxisMask)
    }

    private func enterAlwaysOnCooldown(sampleTimestamp: Date, reason: String, gestureSize: Double, returnAxisMask: Int? = nil) {
        isAlwaysOnWaitingForNeutral = true
        alwaysOnCooldownStartedAt = sampleTimestamp
        alwaysOnCaptureStartedAt = nil
        alwaysOnCalmSince = nil
        alwaysOnNeutralSince = nil
        alwaysOnResetStartedAt = sampleTimestamp
        alwaysOnNeutralCandidateReason = nil
        alwaysOnPreRollPath.removeAll(keepingCapacity: true)
        alwaysOnRequiresReturnFromPeak = gestureSize >= recognitionSettings.alwaysOnGestureSize
        alwaysOnReturnAxisMask = returnAxisMask ?? 0
        continuousStepIndexByGesture.removeAll(keepingCapacity: true)
        dbgLog(String(format: "STATE always_on evaluate -> cooldown reason=%@ fired=%@ returnRequired=%@ returnAxes=%@ cooldown=%.2fs size=%.4f peakDistance=%.4f peakSpeed=%.3frad_s", reason, lastRecognizedGestureExecuted.description, alwaysOnRequiresReturnFromPeak.description, alwaysOnReturnAxisDescription(alwaysOnReturnAxisMask), recognitionSettings.alwaysOnCooldownDuration, gestureSize, alwaysOnGesturePeakDistance, alwaysOnGesturePeakSpeed))
    }

    private func alwaysOnPathAmplitude(_ points: [AirGesturePoint]) -> Double {
        guard let first = points.first else { return 0 }
        var minYaw = first.yaw
        var maxYaw = first.yaw
        var minPitch = first.pitch
        var maxPitch = first.pitch
        var minRoll = first.roll
        var maxRoll = first.roll

        for point in points.dropFirst() {
            minYaw = min(minYaw, point.yaw)
            maxYaw = max(maxYaw, point.yaw)
            minPitch = min(minPitch, point.pitch)
            maxPitch = max(maxPitch, point.pitch)
            minRoll = min(minRoll, point.roll)
            maxRoll = max(maxRoll, point.roll)
        }

        let yawAmplitude = maxYaw - minYaw
        let pitchAmplitude = maxPitch - minPitch
        let rollAmplitude = maxRoll - minRoll
        return sqrt((yawAmplitude * yawAmplitude) + (pitchAmplitude * pitchAmplitude) + (rollAmplitude * rollAmplitude))
    }

    private func processDiscreteGestures(
        sampleTimestamp: Date,
        point: AirGesturePoint,
        deltaYaw: Double,
        deltaPitch: Double,
        deltaRoll: Double,
        motionThreshold: Double? = nil,
        finalizeDelay: Double? = nil
    ) {
        // Combine all rotational axes plus current translation-velocity magnitude so
        // tilt-only and slide-only gestures count as "moving" and don't trigger an
        // instant finalize before any path is recorded.
        let activeMotionThreshold = motionThreshold ?? recognitionSettings.motionThreshold
        let motionMagnitude = motionMagnitudeForDiscrete(deltaYaw: deltaYaw, deltaPitch: deltaPitch, deltaRoll: deltaRoll)

        // Always append while activation is held so the live detection trace mirrors
        // what `appendRecordingPoint` captures during sample recording. This makes
        // matching symmetric and lets pure-tilt or pure-translation gestures (which
        // have near-zero yaw/pitch motion) actually accumulate a path.
        detectionPath.append(point)
        dbgVerboseLog(String(format: "INPUT detection kind=discrete path=%d x=%.3fnorm y=%.3fnorm yaw=%.5frad pitch=%.5frad roll=%.5frad tx=%.5fm ty=%.5fm tz=%.5fm dyaw=%.5frad dpitch=%.5frad droll=%.5frad motion=%.5f threshold=%.5f", detectionPath.count, point.x, point.y, point.yaw, point.pitch, point.roll, point.tx, point.ty, point.tz, deltaYaw, deltaPitch, deltaRoll, motionMagnitude, activeMotionThreshold))
        if detectionPath.count > 700 {
            detectionPath.removeFirst(detectionPath.count - 600)
        }
        // Seed the last-motion timestamp on the very first frame so the idle finalize
        // delay starts counting from the start of the gesture, not from time-zero.
        if detectionLastMotionTimestamp == nil {
            detectionLastMotionTimestamp = sampleTimestamp
        }

        // The motion gate now only decides *when to finalize* the gesture once the
        // user goes still — it no longer gates whether we record at all.
        if motionMagnitude > activeMotionThreshold {
            dbgVerboseLog(String(format: "DECISION discrete_collect result=continue motion=%.5f threshold=%.5f", motionMagnitude, activeMotionThreshold))
            detectionLastMotionTimestamp = sampleTimestamp
            return
        }

        // In Fn mode the whole press is treated as one gesture: do NOT finalize on
        // mid-gesture pauses. The pipeline already finalizes once when Fn is released
        // (the `force: true` call from the activation transition). Finalising
        // mid-gesture would consume the recorded path and cause subsequent motion to
        // be matched against only its tail, which is the main cause of "Last Match
        // shows the right gesture but the action doesn't run".
        if recognitionSettings.activationLayer == .fn {
            dbgVerboseLog("BAIL finalize_discrete reason=fn_hold path=\(detectionPath.count)")
            return
        }

        finalizeDiscreteGestures(sampleTimestamp: sampleTimestamp, force: false, finalizeDelay: finalizeDelay)
    }

    private func motionMagnitudeForDiscrete(deltaYaw: Double, deltaPitch: Double, deltaRoll: Double) -> Double {
        let translationSpeed = sqrt(
            translationVelocityX * translationVelocityX
            + translationVelocityY * translationVelocityY
            + translationVelocityZ * translationVelocityZ
        )
        return sqrt(
            (deltaYaw * deltaYaw)
            + (deltaPitch * deltaPitch)
            + (deltaRoll * deltaRoll)
        ) + translationSpeed * 0.05
    }

    private func finalizeDiscreteGestures(sampleTimestamp: Date, force: Bool, finalizeDelay: Double? = nil) {
        dbgLog("ENTRY finalize_discrete force=\(force) path=\(detectionPath.count)")
        guard !detectionPath.isEmpty else {
            dbgLog("BAIL finalize_discrete reason=empty_path")
            return
        }

        if didFireContinuousGestureInActivationSession {
            dbgLog("BAIL finalize_discrete reason=continuous_already_fired path=\(detectionPath.count)")
            detectionPath.removeAll(keepingCapacity: true)
            detectionLastMotionTimestamp = nil
            return
        }

        if !force {
            guard let lastMotion = detectionLastMotionTimestamp else {
                dbgLog("BAIL finalize_discrete reason=no_last_motion")
                return
            }
            let idleMs = sampleTimestamp.timeIntervalSince(lastMotion) * 1000
            let idleDelay = finalizeDelay ?? recognitionSettings.idleFinalizeDelay
            guard sampleTimestamp.timeIntervalSince(lastMotion) > idleDelay else {
                dbgLog(String(format: "BAIL finalize_discrete reason=idle_delay idle=%.1fms threshold=%.1fms", idleMs, idleDelay * 1000))
                return
            }
        }

        let candidates = gestures.filter { $0.inputType == .discrete && $0.isEnabled }
        let evaluation = AirGestureMatcher.rankedEvaluation(
            performedPath: detectionPath,
            gestures: candidates,
            minimumPathLength: 0
        )
        let ranked = evaluation.matches
        let best = ranked.first
        let secondScore = ranked.dropFirst().first?.score ?? 0
        let margin = (best?.score ?? 0) - secondScore
        let replayOutcome: String
        if let best {
            if best.score < recognitionSettings.confidenceThreshold {
                replayOutcome = "below_threshold"
            } else if margin < minimumDiscreteMatchMargin {
                replayOutcome = "ambiguous"
            } else {
                replayOutcome = "fire"
            }
        } else {
            replayOutcome = candidates.isEmpty ? "no_candidates" : "no_match"
        }

        // Log every candidate so the score field in the UI plus the diagnostics log
        // explain why a gesture did or didn't fire.
        let pathCount = detectionPath.count
        let summary = ranked.map { "\($0.gesture.name)=\(String(format: "%.2f", $0.score))" }.joined(separator: ",")
        GestureDiagnostics.logger.debug("discrete_eval path=\(pathCount, privacy: .public) candidates=\(candidates.count, privacy: .public) scores=[\(summary, privacy: .public)] threshold=\(self.recognitionSettings.confidenceThreshold, privacy: .public)")
        dbgLog("DECISION discrete_eval path=\(pathCount) candidates=\(candidates.count) scores=[\(summary)] threshold=\(recognitionSettings.confidenceThreshold)")
        dbgLog("GESTURE_ATTEMPT intended=\"\(calibrationTargetGestureName)\" \(gesturePathSummary(detectionPath)) scores=[\(summary)] threshold=\(recognitionSettings.confidenceThreshold)")
        if let replayJSON = GestureReplayLogEncoder.encode(
            capturedAt: sampleTimestamp,
            activationLayer: recognitionSettings.activationLayer.rawValue,
            intended: calibrationTargetGestureName,
            outcome: replayOutcome,
            matched: best?.gesture.name,
            path: detectionPath,
            scores: ranked.map { GestureReplayLogEncoder.Score(name: $0.gesture.name, score: $0.score) },
            threshold: recognitionSettings.confidenceThreshold,
            marginThreshold: minimumDiscreteMatchMargin
        ) {
            dbgLog("GESTURE_REPLAY \(replayJSON)")
        }
        // Keep the corpus at full capture resolution. The normal log uses a compact
        // 64-point payload to stay readable, but Trackpad Control showed that lossy or
        // synthetic inputs can give the wrong answer when evaluating matcher changes.
        if let corpusJSON = GestureReplayLogEncoder.encode(
            capturedAt: sampleTimestamp,
            activationLayer: recognitionSettings.activationLayer.rawValue,
            intended: calibrationTargetGestureName,
            outcome: replayOutcome,
            matched: best?.gesture.name,
            path: detectionPath,
            scores: ranked.map { GestureReplayLogEncoder.Score(name: $0.gesture.name, score: $0.score) },
            threshold: recognitionSettings.confidenceThreshold,
            marginThreshold: minimumDiscreteMatchMargin,
            maximumPoints: detectionPath.count
        ) {
            DebugFileLog.appendGestureReplay(corpusJSON)
        }
        for (breakdownIndex, breakdown) in evaluation.breakdowns.enumerated() {
            guard breakdownIndex < 8 || DebugFileLog.isVerboseEnabled else { continue }
            let line = String(
                format: "DECISION score_breakdown gesture=\"%@\" sample=%d final=%.3f chosen=%@ product=%.3f axis=%.3f phase=%.3f terminal=%.3f dominant=%.3f composite=%.3f reversal=%.3f axes=%@ performedPhases=[%@] samplePhases=[%@] axisDetails=%@",
                breakdown.gestureName,
                breakdown.sampleNumber,
                breakdown.finalScore,
                breakdown.chosenScore,
                breakdown.productScore,
                breakdown.axisScore,
                breakdown.phaseScore,
                breakdown.terminalScore,
                breakdown.dominantScore,
                breakdown.compositeScore,
                breakdown.reversalScore,
                breakdown.axes,
                breakdown.performedPhases,
                breakdown.samplePhases,
                breakdown.axisDetails
            )
            if breakdownIndex < 8 {
                dbgLog(line)
            } else {
                dbgVerboseLog(line)
            }
        }
        if evaluation.breakdowns.count > 8 && !DebugFileLog.isVerboseEnabled {
            dbgLog("DECISION score_breakdown_omitted count=\(evaluation.breakdowns.count - 8) reason=verbose_frame_logging_disabled")
        }

        if let best {
            lastRecognizedGestureName = best.gesture.name
            lastRecognizedGestureScore = best.score

            if best.score >= recognitionSettings.confidenceThreshold && margin >= minimumDiscreteMatchMargin {
                lastRecognizedGestureExecuted = true
                lastActionStatus = "Dispatching: \(best.gesture.trigger.displayName)"
                dbgLog(String(format: "DECISION discrete_match result=fire gesture=%@ score=%.3f threshold=%.3f margin=%.3f margin_threshold=%.3f action=%@", best.gesture.name, best.score, recognitionSettings.confidenceThreshold, margin, minimumDiscreteMatchMargin, best.gesture.trigger.displayName))
                dbgLog("STATE armed -> triggered gesture=\(best.gesture.name)")
                GestureTriggerExecutor.execute(best.gesture.trigger, using: self)
                dbgLog("STATE triggered -> cooldown gesture=\(best.gesture.name)")
            } else if best.score >= recognitionSettings.confidenceThreshold {
                lastRecognizedGestureExecuted = false
                lastActionStatus = String(
                    format: "Ambiguous match (margin %.2f < %.2f)",
                    margin,
                    minimumDiscreteMatchMargin
                )
                dbgLog(String(format: "DECISION discrete_match result=reject reason=low_margin gesture=%@ score=%.3f second=%.3f margin=%.3f threshold=%.3f margin_threshold=%.3f", best.gesture.name, best.score, secondScore, margin, recognitionSettings.confidenceThreshold, minimumDiscreteMatchMargin))
            } else {
                lastRecognizedGestureExecuted = false
                lastActionStatus = String(
                    format: "Below threshold (%.2f < %.2f)",
                    best.score,
                    recognitionSettings.confidenceThreshold
                )
                dbgLog(String(format: "DECISION discrete_match result=reject reason=below_threshold gesture=%@ score=%.3f threshold=%.3f", best.gesture.name, best.score, recognitionSettings.confidenceThreshold))
            }
        } else {
            // Surface zero-result outcomes in the UI as well so the user can tell the
            // difference between "no match found" and "matched but below threshold".
            lastRecognizedGestureName = candidates.isEmpty ? "(no discrete gestures)" : "(no match)"
            lastRecognizedGestureScore = 0
            lastRecognizedGestureExecuted = false
            dbgLog("DECISION discrete_match result=reject reason=\(candidates.isEmpty ? "no_candidates" : "no_match")")
        }

        detectionPath.removeAll(keepingCapacity: true)
        detectionLastMotionTimestamp = nil
        dbgLog("DONE finalize_discrete")
    }

    private func processContinuousGestures(sampleTimestamp: Date, relativeYaw: Double, relativePitch: Double, relativeRoll: Double) {
        let candidates = gestures.filter { $0.inputType == .continuous && $0.isEnabled }

        for gesture in candidates {
            let stepIndex = continuousStepIndex(
                for: gesture,
                relativeYaw: relativeYaw,
                relativePitch: relativePitch,
                relativeRoll: relativeRoll
            )
            let previousStepIndex = continuousStepIndexByGesture[gesture.id, default: 0]
            guard stepIndex != previousStepIndex else { continue }

            let displacement = continuousDisplacement(
                for: gesture,
                relativeYaw: relativeYaw,
                relativePitch: relativePitch,
                relativeRoll: relativeRoll
            )
            dbgLog(String(format: "DECISION continuous_step gesture=%@ axis=%@ displacement=%.5f threshold=%.5f previous=%d next=%d", gesture.name, gesture.axis.rawValue, displacement, gesture.continuousStepThreshold, previousStepIndex, stepIndex))

            if let suppression = discreteSuppressionCandidate(sampleTimestamp: sampleTimestamp) {
                isContinuousRecognitionSuppressed = true
                continuousStepIndexByGesture[gesture.id] = stepIndex
                dbgLog(String(format: "BAIL continuous_step reason=discrete_candidate continuous=%@ candidate=%@ score=%.3f path=%d", gesture.name, suppression.gesture.name, suppression.score, detectionPath.count))
                continue
            }

            let distance = stepIndex - previousStepIndex
            let direction = distance > 0 ? 1 : -1

            // Volume and brightness accumulate all steps so fast movement = bigger change.
            // Desktop switching and other shortcuts cap at 1 fire per evaluation to prevent
            // over-firing past the last available space/state, which causes error bleeps.
            // NOTE: canExecuteWithoutKeyboardPermissions also returns true for Ctrl+Arrow
            // (desktop switch) so we must check the actual key name, not that function.
            let k = gesture.trigger.shortcut.key.lowercased()
            let isSteppingMediaKey = gesture.trigger.type == .keyboardShortcut
                && (k == "volume_up" || k == "volume_down" || k == "brightness_up" || k == "brightness_down")
            let fireCount = isSteppingMediaKey ? abs(distance) : 1

            for _ in 0..<fireCount {
                let positive = direction > 0
                let trigger = positive ? gesture.trigger : (gesture.reverseTrigger ?? gesture.trigger)
                lastContinuousGestureName = gesture.name
                lastContinuousTriggerName = trigger.displayName
                lastContinuousStepIndex = stepIndex
                continuousFireCount += 1
                statusMessage = "Continuous: \(gesture.name) -> \(trigger.displayName)"
                GestureDiagnostics.logger.debug("continuous_fire gesture=\(gesture.name, privacy: .public) direction=\(positive ? "+" : "-", privacy: .public) step=\(stepIndex, privacy: .public)")
                dbgLog("STATE armed -> triggered gesture=\(gesture.name) direction=\(positive ? "+" : "-") step=\(stepIndex) action=\(trigger.displayName)")
                didFireContinuousGestureInActivationSession = true
                GestureTriggerExecutor.execute(trigger, using: self)
                dbgLog("STATE triggered -> cooldown gesture=\(gesture.name)")
            }

            continuousStepIndexByGesture[gesture.id] = stepIndex
        }
    }

    private func continuousStepIndex(
        for gesture: AirGestureDefinition,
        relativeYaw: Double,
        relativePitch: Double,
        relativeRoll: Double
    ) -> Int {
        let displacement = continuousDisplacement(
            for: gesture,
            relativeYaw: relativeYaw,
            relativePitch: relativePitch,
            relativeRoll: relativeRoll
        )
        return Int(displacement / gesture.continuousStepThreshold)
    }

    private func continuousDisplacement(
        for gesture: AirGestureDefinition,
        relativeYaw: Double,
        relativePitch: Double,
        relativeRoll: Double
    ) -> Double {
        let responseScale = min(max(recognitionSettings.movementScale * 0.8, 1.0), 2.5)

        switch gesture.axis {
        case .yaw:
            // Default direction is inverted from raw CoreMotion yaw so that a head turn
            // to the right registers as a positive step.
            return -relativeYaw * responseScale
        case .pitch:
            // Same convention for pitch — head down = positive step.
            return -relativePitch * responseScale
        case .roll:
            return relativeRoll * responseScale
        case .lateralX:
            // Translation in metres; scale up so a few cm of head shift produces a usable
            // step. responseScale is already a factor of movementScale so this stays tunable.
            return liveHeadTranslationX * 12.0 * responseScale
        case .verticalY:
            return liveHeadTranslationY * 12.0 * responseScale
        case .depthZ:
            return liveHeadTranslationZ * 12.0 * responseScale
        }
    }

    private func discreteSuppressionCandidate(sampleTimestamp: Date) -> AirGestureMatcher.MatchResult? {
        let discreteCandidates = gestures.filter { $0.inputType == .discrete && $0.isEnabled }
        guard !discreteCandidates.isEmpty else {
            return nil
        }

        guard detectionPath.count >= 12 else {
            return nil
        }

        guard let lastMotion = detectionLastMotionTimestamp else {
            return nil
        }

        let hasRecentDiscreteMotion = sampleTimestamp.timeIntervalSince(lastMotion) <= max(recognitionSettings.idleFinalizeDelay, 0.16)
        guard hasRecentDiscreteMotion else {
            return nil
        }

        let ranked = AirGestureMatcher.rankedMatches(
            performedPath: detectionPath,
            gestures: discreteCandidates,
            minimumPathLength: 0
        )

        guard let best = ranked.first else {
            return nil
        }

        let suppressionThreshold = max(recognitionSettings.confidenceThreshold + 0.15, 0.82)
        guard best.score >= suppressionThreshold else {
            return nil
        }
        return best
    }

    private func gestureDeltas(from attitude: AttitudeValue) -> (Double, Double, Double) {
        guard let previous = previousAttitudeForGestures else {
            previousAttitudeForGestures = attitude
            return (0, 0, 0)
        }

        previousAttitudeForGestures = attitude
        return (
            wrappedDelta(current: attitude.yaw, previous: previous.yaw),
            wrappedDelta(current: attitude.pitch, previous: previous.pitch),
            wrappedDelta(current: attitude.roll, previous: previous.roll)
        )
    }

    private func relativeDisplacement(from attitude: AttitudeValue) -> (Double, Double, Double) {
        guard let baseline = activationBaselineAttitude else {
            return (0, 0, 0)
        }

        return (
            wrappedDelta(current: attitude.yaw, previous: baseline.yaw),
            wrappedDelta(current: attitude.pitch, previous: baseline.pitch),
            wrappedDelta(current: attitude.roll, previous: baseline.roll)
        )
    }

    private func wrappedDelta(current: Double, previous: Double) -> Double {
        var delta = current - previous
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return delta
    }

    private func nextProjectedPoint(relativeYaw: Double, relativePitch: Double, uptime: TimeInterval) -> AirGesturePoint {
        let scale = recognitionSettings.movementScale
        let nextX = min(max(0.5 + (relativeYaw * scale), 0), 1)
        let nextY = min(max(0.5 - (relativePitch * scale), 0), 1)
        return AirGesturePoint(x: nextX, y: nextY, timestamp: uptime, yaw: relativeYaw, pitch: relativePitch)
    }

    private func gesturePathSummary(_ path: [AirGesturePoint]) -> String {
        guard let firstPoint = path.first, let lastPoint = path.last else {
            return "points=0 duration=0.000s dominant=none phases=[]"
        }

        let duration = max(0, lastPoint.timestamp - firstPoint.timestamp)
        let yawStats = axisStats(path.map(\.yaw))
        let pitchStats = axisStats(path.map(\.pitch))
        let rollStats = axisStats(path.map(\.roll))
        let dominant = dominantAxis(yaw: yawStats, pitch: pitchStats, roll: rollStats)
        let phases = phaseSignature(for: path).joined(separator: ">")

        return String(
            format: "points=%d duration=%.3fs yaw[min=%.5f max=%.5f delta=%.5f amp=%.5f] pitch[min=%.5f max=%.5f delta=%.5f amp=%.5f] roll[min=%.5f max=%.5f delta=%.5f amp=%.5f] dominant=%@ phases=[%@]",
            path.count,
            duration,
            yawStats.min,
            yawStats.max,
            yawStats.delta,
            yawStats.amplitude,
            pitchStats.min,
            pitchStats.max,
            pitchStats.delta,
            pitchStats.amplitude,
            rollStats.min,
            rollStats.max,
            rollStats.delta,
            rollStats.amplitude,
            dominant,
            phases.isEmpty ? "none" : phases
        )
    }

    private func axisStats(_ values: [Double]) -> (min: Double, max: Double, delta: Double, amplitude: Double) {
        guard let firstValue = values.first else { return (0, 0, 0, 0) }
        var minimumValue = firstValue
        var maximumValue = firstValue
        for value in values {
            minimumValue = min(minimumValue, value)
            maximumValue = max(maximumValue, value)
        }
        let finalValue = values.last ?? firstValue
        return (minimumValue, maximumValue, finalValue - firstValue, maximumValue - minimumValue)
    }

    private func dominantAxis(
        yaw: (min: Double, max: Double, delta: Double, amplitude: Double),
        pitch: (min: Double, max: Double, delta: Double, amplitude: Double),
        roll: (min: Double, max: Double, delta: Double, amplitude: Double)
    ) -> String {
        let candidates = [
            (label: "yaw", stats: yaw),
            (label: "pitch", stats: pitch),
            (label: "roll", stats: roll)
        ]
        guard let best = candidates.max(by: { $0.stats.amplitude < $1.stats.amplitude }), best.stats.amplitude >= 0.03 else {
            return "none"
        }
        let direction = best.stats.delta >= 0 ? "+" : "-"
        return "\(best.label)\(direction)"
    }

    private func phaseSignature(for path: [AirGesturePoint]) -> [String] {
        guard path.count >= 6 else { return [] }

        let windowSize = max(4, path.count / 12)
        let minimumDelta = 0.025
        var phases: [String] = []
        var startIndex = 0

        while startIndex + windowSize < path.count {
            let startPoint = path[startIndex]
            let endPoint = path[startIndex + windowSize]
            let deltas = [
                (label: "yaw", value: endPoint.yaw - startPoint.yaw),
                (label: "pitch", value: endPoint.pitch - startPoint.pitch),
                (label: "roll", value: endPoint.roll - startPoint.roll)
            ]

            if let strongest = deltas.max(by: { abs($0.value) < abs($1.value) }), abs(strongest.value) >= minimumDelta {
                let phase = "\(strongest.label)\(strongest.value >= 0 ? "+" : "-")"
                if phases.last != phase {
                    phases.append(phase)
                }
            }

            startIndex += max(2, windowSize / 2)
        }

        return phases
    }

    private func smoothProjectedPoint(from previous: AirGesturePoint, to current: AirGesturePoint) -> AirGesturePoint {
        // Smoothing slider was removed; pass the raw projected point through so the
        // detection path matches the recording path (which is also unsmoothed).
        return current
    }

    private func updateDebugSnapshotsIfDue(uptime: TimeInterval, sample: SensorSampleModel) {
        guard uptime - lastDebugSnapshotUptime >= debugSnapshotInterval else { return }
        lastDebugSnapshotUptime = uptime
        debugCursorXY = String(format: "%.3f / %.3f", liveHeadPoint.x, liveHeadPoint.y)
        debugRelativeYPR = String(format: "%.3f / %.3f / %.3f", liveRelativeYaw, liveRelativePitch, liveRelativeRoll)
        debugSensorHz = String(format: "%.1f Hz", sample.derived.updateFrequencyHz)
        continuousDebugSummaries = recomputeContinuousDebugSummaries()
    }

    private func updateLiveTrail(point: AirGesturePoint) {
        if isActivationActive && appearanceSettings.showTrail {
            if let last = liveHeadTrail.last {
                let dx = point.x - last.x
                let dy = point.y - last.y
                let distance = sqrt((dx * dx) + (dy * dy))
                let timeDelta = point.timestamp - last.timestamp
                // Throttle trail to ~25 Hz: rebuilding a SwiftUI Path with 80+ points on
                // every 60-100 Hz motion frame causes Core Animation layer-tree churn that
                // visibly compounds across multiple Fn-press sessions. Skipping
                // sub-threshold tiny points was already done; now also enforce a 40ms
                // minimum spacing so the overlay renders at most ~25 fps even when the
                // head moves continuously.
                if timeDelta < 0.040 {
                    return
                }
                if distance < 0.003 {
                    return
                }
            }
            liveHeadTrail.append(point)
            // Lower cap (was 220) and batch-trim (was per-frame O(n) shift). 80 points at
            // 25 Hz = 3.2s of trail, which is plenty for visual feedback.
            if liveHeadTrail.count > 120 {
                liveHeadTrail.removeFirst(liveHeadTrail.count - 80)
            }
        } else if !isActivationActive {
            liveHeadTrail.removeAll(keepingCapacity: true)
        }
    }

    private func ensureMotionInputRunningForRecording() {
        switch streamState {
        case .active, .starting:
            return
        case .stopped, .error(_):
            startStreaming()
        }
    }

    private func stopMotionInputIfTrackingPaused() {
        guard !isGestureDetectionEnabled else { return }
        stopStreaming()
        statusMessage = "Tracking paused"
    }

    private func resetGestureTrackingRuntime() {
        activationBaselineAttitude = nil
        previousAttitudeForGestures = nil
        projectedGesturePoint = AirGesturePoint(x: 0.5, y: 0.5, timestamp: 0)
        detectionPath.removeAll(keepingCapacity: true)
        detectionLastMotionTimestamp = nil
        continuousStepIndexByGesture.removeAll(keepingCapacity: true)
        previousDeviceTimestamp = nil
        recordingPath.removeAll(keepingCapacity: true)
        recordingStartUptime = nil
        gestureRecordingPointCount = 0
        isRecordingGestureArmed = false
        isRecordingGestureActive = false
        isAlwaysOnWaitingForNeutral = false
        alwaysOnNeutralSince = nil
        alwaysOnResetStartedAt = nil
        alwaysOnNeutralCandidateReason = nil
        alwaysOnCooldownStartedAt = nil
        alwaysOnCaptureStartedAt = nil
        alwaysOnCalmSince = nil
        alwaysOnPreRollPath.removeAll(keepingCapacity: true)
        alwaysOnGesturePeakDistance = 0
        alwaysOnGesturePeakSpeed = 0
        alwaysOnRequiresReturnFromPeak = false
        alwaysOnReturnAxisMask = 0
        isActivationActive = false
        previousActivationState = false
        fnPressedSampleCount = 0
        fnReleasedSampleCount = 0
        isFnActivationPressed = false
        rawFnActivationState = false
        isContinuousRecognitionSuppressed = false
        liveRelativeYaw = 0
        liveRelativePitch = 0
        liveRelativeRoll = 0
        liveHeadTranslationX = 0
        liveHeadTranslationY = 0
        liveHeadTranslationZ = 0
        translationVelocityX = 0
        translationVelocityY = 0
        translationVelocityZ = 0
        lastTranslationUptime = nil
        lastContinuousGestureName = "-"
        lastContinuousTriggerName = "-"
        lastContinuousStepIndex = 0
        continuousFireCount = 0
        liveHeadPoint = AirGesturePoint(x: 0.5, y: 0.5, timestamp: 0)
        resetLiveVisualSnapshots()
        liveHeadTrail.removeAll(keepingCapacity: true)
    }

    private func beginActivationSession(with attitude: AttitudeValue, uptime: TimeInterval) {
        activationBaselineAttitude = attitude
        previousAttitudeForGestures = attitude
        projectedGesturePoint = AirGesturePoint(x: 0.5, y: 0.5, timestamp: uptime)
        liveHeadPoint = projectedGesturePoint
        liveHeadTrail.removeAll(keepingCapacity: true)
        detectionPath.removeAll(keepingCapacity: true)
        detectionLastMotionTimestamp = nil
        alwaysOnPreRollPath.removeAll(keepingCapacity: true)
        continuousStepIndexByGesture.removeAll(keepingCapacity: true)
        translationVelocityX = 0
        translationVelocityY = 0
        translationVelocityZ = 0
        liveHeadTranslationX = 0
        liveHeadTranslationY = 0
        liveHeadTranslationZ = 0
        lastTranslationUptime = nil
        resetLiveVisualSnapshots()
        GestureDiagnostics.logger.debug("activation_start layer=\(self.recognitionSettings.activationLayer.rawValue, privacy: .public)")
        dbgLog(String(format: "ENTRY activation_session layer=%@ baseline_roll=%.5frad baseline_pitch=%.5frad baseline_yaw=%.5frad uptime=%.3fs", recognitionSettings.activationLayer.rawValue, attitude.roll, attitude.pitch, attitude.yaw, uptime))
    }

    private func resetLiveVisualSnapshots() {
        liveHeadAttitudeRoll = 0
        liveHeadAttitudePitch = 0
        liveHeadAttitudeYaw = 0
        smoothedGlobeRoll = 0
        smoothedGlobePitch = 0
        smoothedGlobeYaw = 0
        liveHeadTranslationSnapshotX = 0
        liveHeadTranslationSnapshotY = 0
        liveHeadTranslationSnapshotZ = 0
        resetAlwaysOnGateSnapshot()
    }

    private func resetAlwaysOnGateSnapshot() {
        alwaysOnGateDisplayState = recognitionSettings.activationLayer == .alwaysOn ? .waiting : .inactive
        alwaysOnGateDistanceProgress = 0
        alwaysOnGateSpeedProgress = 0
        alwaysOnGateDistance = 0
        alwaysOnGateSpeed = 0
        lastAlwaysOnGatePublishUptime = 0
    }

    private func updateHeadTranslation(userAcceleration: Vector3Value, uptime: TimeInterval, isActive: Bool) {
        guard isActive else {
            // Bleed everything to zero when inactive so the next session starts clean.
            translationVelocityX = 0
            translationVelocityY = 0
            translationVelocityZ = 0
            liveHeadTranslationX = 0
            liveHeadTranslationY = 0
            liveHeadTranslationZ = 0
            lastTranslationUptime = uptime
            return
        }

        guard let last = lastTranslationUptime else {
            lastTranslationUptime = uptime
            return
        }
        let dt = max(0, min(0.1, uptime - last))
        lastTranslationUptime = uptime
        guard dt > 0 else { return }

        // userAcceleration is in g (gravity already removed). Convert to m/s^2.
        let g = 9.80665
        let ax = userAcceleration.x * g
        let ay = userAcceleration.y * g
        let az = userAcceleration.z * g

        // Deadband — accelerometer noise floor for stationary head is well above
        // 0.02 g once you include AirPods sensor jitter. A 0.02 g floor was letting
        // tiny biased samples integrate into multi-metre phantom drift over a few
        // seconds (slide_x = -17 while sitting still). Raising to 0.05 g cuts
        // virtually all drift while still capturing intentional head pushes/pulls.
        let noiseFloor = 0.05 * g
        let axClean = abs(ax) < noiseFloor ? 0 : ax
        let ayClean = abs(ay) < noiseFloor ? 0 : ay
        let azClean = abs(az) < noiseFloor ? 0 : az

        // Integrate acceleration -> velocity, then velocity -> displacement.
        translationVelocityX += axClean * dt
        translationVelocityY += ayClean * dt
        translationVelocityZ += azClean * dt

        // High-pass: bleed velocity toward zero each frame to fight integration drift.
        // Time-constant tightened to 0.2s (was 0.4s) so any residual bias decays
        // twice as fast and can't accumulate into runaway displacement.
        let velocityDecay = exp(-dt / 0.2)
        translationVelocityX *= velocityDecay
        translationVelocityY *= velocityDecay
        translationVelocityZ *= velocityDecay

        liveHeadTranslationX += translationVelocityX * dt
        liveHeadTranslationY += translationVelocityY * dt
        liveHeadTranslationZ += translationVelocityZ * dt

        // Displacement decay: pulls position back to zero faster (0.6s, was 1.2s)
        // for the same drift-suppression reason.
        let displacementDecay = exp(-dt / 0.6)
        liveHeadTranslationX *= displacementDecay
        liveHeadTranslationY *= displacementDecay
        liveHeadTranslationZ *= displacementDecay
    }

    private func updateAlwaysOnNeutralReset(
        sampleTimestamp: Date,
        attitude: AttitudeValue,
        uptime: TimeInterval,
        poseDistance: Double,
        motionMagnitude: Double
    ) {
        let returnRadius = recognitionSettings.alwaysOnReturnToNeutralRadius
        let startThreshold = recognitionSettings.alwaysOnStartThreshold
        let peakDistance = max(alwaysOnGesturePeakDistance, poseDistance)
        let recoveryRadius = max(returnRadius, min(returnRadius + startThreshold, peakDistance * 0.65))
        let isBackAtOriginalNeutral = poseDistance <= returnRadius
        let isClearlyBackFromGesturePeak = peakDistance > returnRadius + startThreshold
            && poseDistance <= recoveryRadius
        let hasMovedBackFromPeak = peakDistance > max(returnRadius + startThreshold, startThreshold * 2)
            && poseDistance <= peakDistance * 0.82
            && (peakDistance - poseDistance) >= startThreshold * 0.5
        let calmThreshold = recognitionSettings.motionThreshold
        guard AlwaysOnCalmGate.isCalm(motionMagnitude: motionMagnitude, threshold: calmThreshold) else {
            alwaysOnNeutralSince = nil
            alwaysOnNeutralCandidateReason = nil
            return
        }

        if alwaysOnRequiresReturnFromPeak && !isBackAtOriginalNeutral {
            alwaysOnNeutralSince = nil
            alwaysOnNeutralCandidateReason = nil
            return
        }

        if alwaysOnNeutralSince == nil {
            alwaysOnNeutralSince = sampleTimestamp
        }

        let stillFor = sampleTimestamp.timeIntervalSince(alwaysOnNeutralSince ?? sampleTimestamp)
        let resetFor = sampleTimestamp.timeIntervalSince(alwaysOnResetStartedAt ?? sampleTimestamp)
        let fallbackSettle = max(1.20, recognitionSettings.alwaysOnNeutralSettleDuration * 3)
        let reason: String?
        let requiredSettle: TimeInterval
        if isBackAtOriginalNeutral {
            reason = "return_radius"
            requiredSettle = recognitionSettings.alwaysOnNeutralSettleDuration
        } else if isClearlyBackFromGesturePeak {
            reason = "peak_recovery"
            requiredSettle = recognitionSettings.alwaysOnNeutralSettleDuration
        } else if stillFor >= fallbackSettle && resetFor >= fallbackSettle && (!alwaysOnRequiresReturnFromPeak || hasMovedBackFromPeak) {
            reason = "stillness_recenter"
            requiredSettle = fallbackSettle
        } else {
            return
        }

        guard let reason else { return }

        if alwaysOnNeutralCandidateReason != reason {
            alwaysOnNeutralCandidateReason = reason
            dbgLog(String(format: "STATE always_on reset_wait -> neutral_candidate reason=%@ distance=%.4f motion=%.4f calmMotion=%.4f peak=%.4f radius=%.4f recovery=%.4f movedBack=%@ requiresReturn=%@ still=%.2fs reset=%.2fs", reason, poseDistance, motionMagnitude, calmThreshold, peakDistance, returnRadius, recoveryRadius, hasMovedBackFromPeak.description, alwaysOnRequiresReturnFromPeak.description, stillFor, resetFor))
        }

        guard let neutralSince = alwaysOnNeutralSince,
              sampleTimestamp.timeIntervalSince(neutralSince) >= requiredSettle else {
            return
        }

        beginActivationSession(with: attitude, uptime: uptime)
        isAlwaysOnWaitingForNeutral = false
        alwaysOnNeutralSince = nil
        alwaysOnResetStartedAt = nil
        alwaysOnNeutralCandidateReason = nil
        alwaysOnGesturePeakDistance = 0
        alwaysOnRequiresReturnFromPeak = false
        dbgLog(String(format: "STATE always_on reset_wait -> neutral reason=%@ distance=%.4f motion=%.4f calmMotion=%.4f peak=%.4f movedBack=%@ still=%.2fs", reason, poseDistance, motionMagnitude, calmThreshold, peakDistance, hasMovedBackFromPeak.description, stillFor))
    }

    private func alwaysOnDistanceFromNeutral(_ point: AirGesturePoint) -> Double {
        sqrt(
            (point.yaw * point.yaw)
            + (point.pitch * point.pitch)
            + (point.roll * point.roll)
            + (point.tx * point.tx * 0.05)
            + (point.ty * point.ty * 0.05)
            + (point.tz * point.tz * 0.05)
        )
    }

    private func alwaysOnReturnDistanceFromNeutral(_ point: AirGesturePoint) -> Double {
        guard alwaysOnReturnAxisMask != 0 else {
            return alwaysOnDistanceFromNeutral(point)
        }

        var distanceSquared = 0.0
        if alwaysOnReturnAxisMask & alwaysOnReturnAxisYaw != 0 {
            distanceSquared += point.yaw * point.yaw
        }
        if alwaysOnReturnAxisMask & alwaysOnReturnAxisPitch != 0 {
            distanceSquared += point.pitch * point.pitch
        }
        if alwaysOnReturnAxisMask & alwaysOnReturnAxisRoll != 0 {
            distanceSquared += point.roll * point.roll
        }
        return sqrt(distanceSquared)
    }

    private func alwaysOnReturnAxisMask(for points: [AirGesturePoint]) -> Int {
        guard let first = points.first else {
            return alwaysOnReturnAxisYaw | alwaysOnReturnAxisPitch | alwaysOnReturnAxisRoll
        }

        var minYaw = first.yaw
        var maxYaw = first.yaw
        var minPitch = first.pitch
        var maxPitch = first.pitch
        var minRoll = first.roll
        var maxRoll = first.roll

        for point in points.dropFirst() {
            minYaw = min(minYaw, point.yaw)
            maxYaw = max(maxYaw, point.yaw)
            minPitch = min(minPitch, point.pitch)
            maxPitch = max(maxPitch, point.pitch)
            minRoll = min(minRoll, point.roll)
            maxRoll = max(maxRoll, point.roll)
        }

        let yawAmplitude = maxYaw - minYaw
        let pitchAmplitude = maxPitch - minPitch
        let rollAmplitude = maxRoll - minRoll
        let dominantAmplitude = max(yawAmplitude, pitchAmplitude, rollAmplitude)
        guard dominantAmplitude > 0 else {
            return alwaysOnReturnAxisYaw | alwaysOnReturnAxisPitch | alwaysOnReturnAxisRoll
        }

        let inclusionThreshold = max(recognitionSettings.alwaysOnReturnToNeutralRadius, dominantAmplitude * 0.60)
        var mask = 0
        if yawAmplitude >= inclusionThreshold { mask |= alwaysOnReturnAxisYaw }
        if pitchAmplitude >= inclusionThreshold { mask |= alwaysOnReturnAxisPitch }
        if rollAmplitude >= inclusionThreshold { mask |= alwaysOnReturnAxisRoll }

        if mask != 0 { return mask }
        if dominantAmplitude == yawAmplitude { return alwaysOnReturnAxisYaw }
        if dominantAmplitude == pitchAmplitude { return alwaysOnReturnAxisPitch }
        return alwaysOnReturnAxisRoll
    }

    private func alwaysOnReturnAxisDescription(_ mask: Int) -> String {
        guard mask != 0 else { return "all" }

        var axes: [String] = []
        if mask & alwaysOnReturnAxisYaw != 0 { axes.append("yaw") }
        if mask & alwaysOnReturnAxisPitch != 0 { axes.append("pitch") }
        if mask & alwaysOnReturnAxisRoll != 0 { axes.append("roll") }
        return axes.joined(separator: "+")
    }

    private func persistGestures() {
        guard gestureStore.save(gestures) else {
            statusMessage = "Gesture save failed"
            errorMessage = "Could not save gestures. See \(DebugFileLog.logPath) for details."
            return
        }
        dbgLog("STATE gestures_saved count=\(gestures.count)")
    }

    private var calibrationTargetGestureName: String {
        guard let calibrationTargetGestureID,
              let gesture = gestures.first(where: { $0.id == calibrationTargetGestureID }) else {
            return "(unset)"
        }
        return gesture.name
    }

    private func seedCalibrationGestureSetIfNeeded() {
        guard !hasCalibrationGestureSet else {
            if repairEmptyCalibrationGestureSamplesIfNeeded() {
                persistGestures()
                dbgLog("STATE calibration_set_repaired reason=empty_samples")
            }
            if calibrationTargetGestureID == nil {
                calibrationTargetGestureID = gestures.first(where: { $0.name == calibrationGestureNames[0] })?.id
            }
            return
        }
        gestures = calibrationGestureSet()
        calibrationTargetGestureID = gestures.first?.id
        persistGestures()
        dbgLog("STATE calibration_set_loaded count=\(gestures.count) source=missing_calibration_set")
    }

    private var hasCalibrationGestureSet: Bool {
        let existingNames = Set(gestures.map(\.name))
        return calibrationGestureNames.allSatisfy { existingNames.contains($0) }
    }

    private func calibrationGestureSet() -> [AirGestureDefinition] {
        let trigger = GestureTrigger(type: .builtIn, builtInAction: .markEvent)
        let now = Date()
        return zip(calibrationGestureNames, [
            AirGestureAxis.yaw,
            AirGestureAxis.pitch,
            AirGestureAxis.roll,
            AirGestureAxis.yaw,
            AirGestureAxis.pitch,
            AirGestureAxis.pitch,
            AirGestureAxis.yaw
        ]).map { pair in
            calibrationGesture(name: pair.0, axis: pair.1, trigger: trigger, date: now)
        }
    }

    private func calibrationGesture(
        name: String,
        axis: AirGestureAxis,
        trigger: GestureTrigger,
        date: Date
    ) -> AirGestureDefinition {
        AirGestureDefinition(
            name: name,
            isEnabled: true,
            inputType: .discrete,
            samples: calibrationSamples(for: name),
            axis: axis,
            sensitivity: 5,
            trigger: trigger,
            createdAt: date,
            updatedAt: date
        )
    }

    private func repairEmptyCalibrationGestureSamplesIfNeeded() -> Bool {
        let defaultsByName = Dictionary(uniqueKeysWithValues: calibrationGestureSet().map { ($0.name, $0) })
        var repaired = false

        for index in gestures.indices {
            let name = gestures[index].name
            guard calibrationGestureNames.contains(name),
                  gestures[index].samples.isEmpty,
                  let defaultGesture = defaultsByName[name] else {
                continue
            }

            gestures[index].samples = defaultGesture.samples
            gestures[index].axis = defaultGesture.axis
            gestures[index].updatedAt = Date()
            repaired = true
        }

        return repaired
    }

    private func calibrationSamples(for name: String) -> [AirGestureSample] {
        switch name {
        case "CAL 01 Right":
            return [
                calibrationSample([
                    (0.00,  0.000,  0.000,  0.000),
                    (0.35, -0.180,  0.020, -0.050),
                    (0.70, -0.320,  0.030, -0.075),
                    (1.00, -0.400,  0.010, -0.090)
                ]),
                calibrationSample([
                    (0.00,  0.000,  0.000,  0.000),
                    (0.45, -0.300, -0.090, -0.050),
                    (1.00, -0.452, -0.140, -0.066)
                ])
            ]
        case "CAL 02 Down":
            return [
                calibrationSample([
                    (0.00,  0.000,  0.000,  0.000),
                    (0.45, -0.020, -0.120, -0.005),
                    (1.00, -0.045, -0.250, -0.015)
                ])
            ]
        case "CAL 03 Roll Right":
            return [
                calibrationSample([
                    (0.00,  0.000,  0.000,  0.000),
                    (0.45, -0.120,  0.024,  0.120),
                    (1.00, -0.122,  0.024,  0.241)
                ])
            ]
        case "CAL 04 Right Down":
            return [
                calibrationSample([
                    (0.00,  0.000,  0.000,  0.000),
                    (0.45, -0.250,  0.038, -0.006),
                    (1.00, -0.307, -0.155, -0.039)
                ])
            ]
        case "CAL 05 Down Right":
            return [
                calibrationSample([
                    (0.00,  0.000,  0.000,  0.000),
                    (0.40, -0.030, -0.180, -0.030),
                    (1.00, -0.396, -0.145, -0.077)
                ])
            ]
        case "CAL 06 Right Down Up":
            return [
                calibrationSample([
                    (0.00,  0.000,  0.000,  0.000),
                    (0.18, -0.300, -0.150, -0.060),
                    (0.45, -0.500, -0.060, -0.100),
                    (1.00, -0.538,  0.085, -0.111)
                ])
            ]
        case "CAL 07 Circle CW":
            return [
                calibrationSample([
                    (0.00,  0.000,  0.000,  0.000),
                    (0.25,  0.160,  0.100,  0.025),
                    (0.50, -0.050,  0.260,  0.055),
                    (0.75, -0.320,  0.120,  0.030),
                    (1.00, -0.085,  0.036,  0.030)
                ])
            ]
        default:
            return []
        }
    }

    private func calibrationSample(_ keyframes: [(TimeInterval, Double, Double, Double)]) -> AirGestureSample {
        let points = keyframes.map { timestamp, yaw, pitch, roll in
            AirGesturePoint(
                x: min(max(0.5 + yaw * 2.5, 0), 1),
                y: min(max(0.5 - pitch * 2.5, 0), 1),
                timestamp: timestamp,
                yaw: yaw,
                pitch: pitch,
                roll: roll
            )
        }
        return AirGestureSample(points: points)
    }

    private func upsertGestureDraft(
        name: String,
        inputType: AirGestureInputType,
        samples: [AirGestureSample],
        reverseTrigger: GestureTrigger?
    ) -> Bool {
        let primaryTrigger = normalizedTrigger(gestureDraftTrigger)
        let normalizedReverseTrigger = reverseTrigger.map(normalizedTrigger)
        let updatedAt = Date()

        if let editID = editingGestureID,
           let index = gestures.firstIndex(where: { $0.id == editID }) {
            let existing = gestures[index]
            gestures[index] = AirGestureDefinition(
                id: existing.id,
                name: name,
                isEnabled: existing.isEnabled,
                inputType: inputType,
                samples: samples,
                axis: gestureDraftAxis,
                sensitivity: gestureDraftSensitivity,
                trigger: primaryTrigger,
                reverseTrigger: normalizedReverseTrigger,
                createdAt: existing.createdAt,
                updatedAt: updatedAt
            )
            calibrationTargetGestureID = existing.id
            return true
        }

        let gesture = AirGestureDefinition(
            name: name,
            inputType: inputType,
            samples: samples,
            axis: gestureDraftAxis,
            sensitivity: gestureDraftSensitivity,
            trigger: primaryTrigger,
            reverseTrigger: normalizedReverseTrigger
        )
        gestures.append(gesture)
        calibrationTargetGestureID = gesture.id
        return false
    }

    private func isActivationLayerActive() -> Bool {
        guard recognitionSettings.activationLayer == .fn else {
            fnPressedSampleCount = 0
            fnReleasedSampleCount = 0
            isFnActivationPressed = false
            // Guarded: avoid invalidating @Observable observers every frame.
            if rawFnActivationState != false {
                rawFnActivationState = false
            }
            return true
        }

        let hidKeyPressed = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_Function))
        let sessionKeyPressed = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Function))
        let hidFlagPressed = CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn)
        let sessionFlagPressed = CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)

        dbgVerboseLog("EXTERNAL CGEventSource.keyState state=hidSystemState keyCode=\(CGKeyCode(kVK_Function)) return=\(hidKeyPressed)")
        dbgVerboseLog("EXTERNAL CGEventSource.keyState state=combinedSessionState keyCode=\(CGKeyCode(kVK_Function)) return=\(sessionKeyPressed)")
        dbgVerboseLog("EXTERNAL CGEventSource.flagsState state=hidSystemState containsFn=\(hidFlagPressed)")
        dbgVerboseLog("EXTERNAL CGEventSource.flagsState state=combinedSessionState containsFn=\(sessionFlagPressed)")

        let anyKeyPressed = hidKeyPressed || sessionKeyPressed
        let anyFlagPressed = hidFlagPressed || sessionFlagPressed
        let rawFnPressed = isFnActivationPressed ? (anyKeyPressed || anyFlagPressed) : (anyKeyPressed && anyFlagPressed)
        if rawFnActivationState != rawFnPressed {
            dbgLog("INPUT fn_activation raw=\(rawFnPressed) anyKey=\(anyKeyPressed) anyFlag=\(anyFlagPressed) debouncePressed=\(fnPressedSampleCount) debounceReleased=\(fnReleasedSampleCount)")
            rawFnActivationState = rawFnPressed
        }

        if rawFnPressed {
            fnPressedSampleCount = min(fnPressedSampleCount + 1, fnActivationDebounceSamples)
            fnReleasedSampleCount = 0

            if fnPressedSampleCount >= fnActivationDebounceSamples {
                if !isFnActivationPressed {
                    dbgLog("DECISION fn_activation result=pressed samples=\(fnPressedSampleCount) threshold=\(fnActivationDebounceSamples)")
                }
                isFnActivationPressed = true
            }
        } else {
            fnReleasedSampleCount = min(fnReleasedSampleCount + 1, fnActivationDebounceSamples)
            fnPressedSampleCount = 0

            if fnReleasedSampleCount >= fnActivationDebounceSamples {
                if isFnActivationPressed {
                    dbgLog("DECISION fn_activation result=released samples=\(fnReleasedSampleCount) threshold=\(fnActivationDebounceSamples)")
                }
                isFnActivationPressed = false
            }
        }

        return isFnActivationPressed
    }

    private func normalizedTrigger(_ trigger: GestureTrigger) -> GestureTrigger {
        return trigger
    }

    private func friendlyMessage(for error: MotionSensorError) -> String {
        switch error {
        case .unauthorized:
            return "Motion permission is denied or restricted. Open System Settings > Privacy & Security and allow Motion access for airpod_control."
        case .unavailable:
            return "Headphone motion is currently unavailable even though audio may be connected. Re-seat AirPods, wait a few seconds, and try Start Stream again."
        case .streamFailed(let message):
            return "Core Motion stream failed: \(message)"
        }
    }

    private func buildExportMetadata(samples: [SensorSampleModel]) -> ExportMetadata {
        let sampleRate: Double
        if samples.count > 1,
           let first = samples.first,
           let last = samples.last {
            let duration = max(last.timestamp.timeIntervalSince(first.timestamp), 0.001)
            sampleRate = Double(samples.count - 1) / duration
        } else {
            sampleRate = latestSample?.derived.updateFrequencyHz ?? 0
        }

        return ExportMetadata(
            exportedAt: Date(),
            startTimestamp: samples.first?.timestamp,
            endTimestamp: samples.last?.timestamp,
            sampleRateHz: sampleRate,
            availabilityState: availabilityState,
            sampleCount: samples.count
        )
    }
}

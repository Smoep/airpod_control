import Foundation

enum AirGestureInputType: String, Codable, CaseIterable, Identifiable, Sendable {
    case discrete = "Discrete"
    case continuous = "Continuous"

    var id: String { rawValue }
}

enum AirGestureAxis: String, Codable, CaseIterable, Identifiable, Sendable {
    case yaw = "Left / Right"
    case pitch = "Up / Down"
    case roll = "Tilt / Roll"
    case lateralX = "Slide Left / Right"
    case verticalY = "Slide Up / Down"
    case depthZ = "Push / Pull"

    var id: String { rawValue }

    var isRotational: Bool {
        switch self {
        case .yaw, .pitch, .roll: return true
        case .lateralX, .verticalY, .depthZ: return false
        }
    }

    var detailText: String {
        switch self {
        case .yaw:
            return "Uses horizontal head turning. Good for left and right movement."
        case .pitch:
            return "Uses vertical head nodding. Good for up and down movement."
        case .roll:
            return "Uses head tilt — left ear up vs right ear up. Good for rotary-style controls."
        case .lateralX:
            return "Detects sliding your head sideways without turning. Best for short impulse gestures (drift accumulates over time)."
        case .verticalY:
            return "Detects raising or lowering your head without nodding. Best for short impulse gestures."
        case .depthZ:
            return "Detects pushing your head forward or pulling it back. Best for short impulse gestures."
        }
    }

    var primaryActionTitle: String {
        switch self {
        case .yaw, .pitch, .lateralX, .verticalY, .depthZ:
            return "Primary Direction Action"
        case .roll:
            return "Clockwise / Right-Ear-Down Action"
        }
    }

    var reverseActionTitle: String {
        switch self {
        case .yaw, .pitch, .lateralX, .verticalY, .depthZ:
            return "Reverse Direction Action"
        case .roll:
            return "Counterclockwise / Left-Ear-Down Action"
        }
    }
}

enum ActivationLayer: String, Codable, CaseIterable, Identifiable, Sendable {
    case fn = "Fn Key"
    case alwaysOn = "Always On"

    var id: String { rawValue }
}

enum GestureTaskAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case copySnapshot = "Copy Snapshot"
    case exportCSV = "Export CSV"
    case exportJSON = "Export JSON"
    case startStream = "Start Stream"
    case stopStream = "Stop Stream"
    case increaseExportWindow = "Increase Export Window"
    case decreaseExportWindow = "Decrease Export Window"
    case markEvent = "Mark Event"

    var id: String { rawValue }

    static let gestureAssignableActions: [GestureTaskAction] = [.markEvent]
}

enum GestureWindowAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case leftHalf = "Left Half"
    case rightHalf = "Right Half"
    case topHalf = "Top Half"
    case bottomHalf = "Bottom Half"
    case topLeftQuarter = "Top Left Quarter"
    case topRightQuarter = "Top Right Quarter"
    case bottomLeftQuarter = "Bottom Left Quarter"
    case bottomRightQuarter = "Bottom Right Quarter"
    case center = "Center"
    case maximize = "Maximize"

    var id: String { rawValue }
}

enum GestureTriggerType: String, Codable, CaseIterable, Identifiable, Sendable {
    case builtIn = "Built-In Action"
    case openApp = "Open App"
    case windowAction = "Window Action"
    case keyboardShortcut = "Keyboard Shortcut"

    var id: String { rawValue }
}

struct GestureShortcut: Codable, Sendable {
    var key: String = ""
    var command: Bool = true
    var shift: Bool = false
    var option: Bool = false
    var control: Bool = false

    var displayString: String {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "No Shortcut" }

        switch key.lowercased() {
        case "volume_up":
            return "Volume Up"
        case "volume_down":
            return "Volume Down"
        case "brightness_up":
            return "Brightness Up"
        case "brightness_down":
            return "Brightness Down"
        default:
            break
        }

        var parts: [String] = []
        if control { parts.append("⌃") }
        if option { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if command { parts.append("⌘") }
        parts.append(key.uppercased())
        return parts.joined()
    }
}

struct GestureTrigger: Codable, Sendable {
    var type: GestureTriggerType = .builtIn
    var builtInAction: GestureTaskAction = .copySnapshot
    var appName: String = ""
    var appPath: String = ""
    var windowAction: GestureWindowAction = .leftHalf
    var shortcut: GestureShortcut = GestureShortcut()

    var displayName: String {
        switch type {
        case .builtIn:
            return builtInAction.rawValue
        case .openApp:
            if appName.isEmpty { return appPath.isEmpty ? "Open App" : "Open \(appPath)" }
            return "Open \(appName)"
        case .windowAction:
            return windowAction.rawValue
        case .keyboardShortcut:
            return shortcut.displayString
        }
    }
}

struct AirGesturePoint: Codable, Sendable {
    let x: Double
    let y: Double
    let timestamp: TimeInterval
    /// Raw head yaw relative to activation baseline (radians). Display x/y are derived
    /// projections; yaw/pitch/roll are the recognition/debug source signals.
    let yaw: Double
    let pitch: Double
    /// Head roll relative to activation baseline (radians). 0 for legacy 2D-only samples.
    let roll: Double
    /// Head translation displacement relative to activation baseline (metres). 0 for
    /// legacy 2D-only samples.
    let tx: Double
    let ty: Double
    let tz: Double

    init(
        x: Double,
        y: Double,
        timestamp: TimeInterval,
        yaw: Double = 0,
        pitch: Double = 0,
        roll: Double = 0,
        tx: Double = 0,
        ty: Double = 0,
        tz: Double = 0
    ) {
        self.x = x
        self.y = y
        self.timestamp = timestamp
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.tx = tx
        self.ty = ty
        self.tz = tz
    }

    private enum CodingKeys: String, CodingKey {
        case x, y, timestamp, yaw, pitch, roll, tx, ty, tz
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        timestamp = try c.decode(TimeInterval.self, forKey: .timestamp)
        yaw = try c.decodeIfPresent(Double.self, forKey: .yaw) ?? 0
        pitch = try c.decodeIfPresent(Double.self, forKey: .pitch) ?? 0
        roll = try c.decodeIfPresent(Double.self, forKey: .roll) ?? 0
        tx = try c.decodeIfPresent(Double.self, forKey: .tx) ?? 0
        ty = try c.decodeIfPresent(Double.self, forKey: .ty) ?? 0
        tz = try c.decodeIfPresent(Double.self, forKey: .tz) ?? 0
    }
}

struct AirGestureSample: Codable, Identifiable, Sendable {
    let id: UUID
    let points: [AirGesturePoint]
    let createdAt: Date

    init(id: UUID = UUID(), points: [AirGesturePoint], createdAt: Date = Date()) {
        self.id = id
        self.points = points
        self.createdAt = createdAt
    }
}

struct AirGestureDefinition: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var isEnabled: Bool
    var inputType: AirGestureInputType
    var samples: [AirGestureSample]
    var axis: AirGestureAxis
    var sensitivity: Double
    var trigger: GestureTrigger
    var reverseTrigger: GestureTrigger?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        inputType: AirGestureInputType,
        samples: [AirGestureSample] = [],
        axis: AirGestureAxis = .yaw,
        sensitivity: Double = 5,
        trigger: GestureTrigger,
        reverseTrigger: GestureTrigger? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.inputType = inputType
        self.samples = samples
        self.axis = axis
        self.sensitivity = sensitivity
        self.trigger = trigger
        self.reverseTrigger = reverseTrigger
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var continuousStepThreshold: Double {
        let clamped = min(max(sensitivity, 1), 10)
        return 0.12 - (clamped - 1) * (0.11 / 9)
    }
}

struct AirGestureRecognitionSettings: Codable, Equatable, Sendable {
    var activationLayer: ActivationLayer = .fn
    var movementScale: Double = 2.5
    var confidenceThreshold: Double = 0.55
    var motionThreshold: Double = 0.008
    var idleFinalizeDelay: Double = 0.28
    var alwaysOnStartThreshold: Double = 0.06
    var alwaysOnHoldDuration: Double = 0.35
    var alwaysOnReturnToNeutralRadius: Double = 0.08
    var alwaysOnNeutralSettleDuration: Double = 0.45
    var alwaysOnGestureSpeed: Double = 0.90
    var alwaysOnGestureSize: Double = 0.12
    var alwaysOnFinishDelay: Double = 0.10
    var alwaysOnCooldownDuration: Double = 0.35
    var smoothingAlpha: Double = 0.55

    private enum CodingKeys: String, CodingKey {
        case activationLayer
        case movementScale
        case confidenceThreshold
        case motionThreshold
        case idleFinalizeDelay
        case alwaysOnStartThreshold
        case alwaysOnHoldDuration
        case alwaysOnReturnToNeutralRadius
        case alwaysOnNeutralSettleDuration
        case alwaysOnGestureSpeed
        case alwaysOnGestureSize
        case alwaysOnFinishDelay
        case alwaysOnCooldownDuration
        case smoothingAlpha
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activationLayer = try container.decodeIfPresent(ActivationLayer.self, forKey: .activationLayer) ?? .fn
        movementScale = try container.decodeIfPresent(Double.self, forKey: .movementScale) ?? 2.5
        confidenceThreshold = try container.decodeIfPresent(Double.self, forKey: .confidenceThreshold) ?? 0.55
        motionThreshold = try container.decodeIfPresent(Double.self, forKey: .motionThreshold) ?? 0.008
        idleFinalizeDelay = try container.decodeIfPresent(Double.self, forKey: .idleFinalizeDelay) ?? 0.28
        alwaysOnStartThreshold = try container.decodeIfPresent(Double.self, forKey: .alwaysOnStartThreshold) ?? 0.06
        alwaysOnHoldDuration = try container.decodeIfPresent(Double.self, forKey: .alwaysOnHoldDuration) ?? 0.35
        alwaysOnReturnToNeutralRadius = try container.decodeIfPresent(Double.self, forKey: .alwaysOnReturnToNeutralRadius) ?? 0.08
        alwaysOnNeutralSettleDuration = try container.decodeIfPresent(Double.self, forKey: .alwaysOnNeutralSettleDuration) ?? 0.45
        alwaysOnGestureSpeed = try container.decodeIfPresent(Double.self, forKey: .alwaysOnGestureSpeed) ?? 0.90
        alwaysOnGestureSize = try container.decodeIfPresent(Double.self, forKey: .alwaysOnGestureSize) ?? max(0.10, alwaysOnStartThreshold)
        alwaysOnFinishDelay = try container.decodeIfPresent(Double.self, forKey: .alwaysOnFinishDelay) ?? 0.10
        alwaysOnCooldownDuration = try container.decodeIfPresent(Double.self, forKey: .alwaysOnCooldownDuration) ?? 0.35
        smoothingAlpha = try container.decodeIfPresent(Double.self, forKey: .smoothingAlpha) ?? 0.55
    }
}

struct AirGestureAppearanceSettings: Codable, Equatable, Sendable {
    var showOverlayWhenActive: Bool = true
    var overlayOpacity: Double = 0.88
    var overlayScale: Double = 1.0
    var showTrail: Bool = true

    private enum CodingKeys: String, CodingKey {
        case showOverlayWhenActive
        case overlayOpacity
        case overlayScale
        case showTrail
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showOverlayWhenActive = try container.decodeIfPresent(Bool.self, forKey: .showOverlayWhenActive) ?? true
        overlayOpacity = try container.decodeIfPresent(Double.self, forKey: .overlayOpacity) ?? 0.88
        overlayScale = try container.decodeIfPresent(Double.self, forKey: .overlayScale) ?? 1.0
        showTrail = try container.decodeIfPresent(Bool.self, forKey: .showTrail) ?? true
    }
}

import Foundation

@MainActor
final class AirGestureStore {
    static let shared = AirGestureStore()
    static let trackingEnabledKey = "airpod_control.tracking_enabled.v1"

    private let gesturesKey = "airpod_control.gesture_definitions.v3"
    private let recognitionKey = "airpod_control.gesture_recognition_settings.v1"
    private let appearanceKey = "airpod_control.gesture_appearance_settings.v1"
    private let trackingEnabledKey = AirGestureStore.trackingEnabledKey
    private let debugModeKey = DebugFileLog.debugModeKey
    private let verboseModeKey = DebugFileLog.verboseModeKey
    /// v2 stored discrete samples as 2D-only points. The matcher now operates on a 6D
    /// pose feature vector (cursor + roll + translation), so old samples can't be
    /// meaningfully compared. We migrate continuous gestures forward (axis-driven, no
    /// recordings needed) and discard discrete ones so the user starts fresh.
    private let v2GesturesKey = "airpod_control.gesture_definitions.v2"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        migrateSandboxPreferencesIfNeeded()
    }

    func load() -> [AirGestureDefinition] {
        dbgLog("ENTRY load_gestures key=\(gesturesKey)")
        if let data = persistedData(forKey: gesturesKey) {
            do {
                let gestures = try decoder.decode([AirGestureDefinition].self, from: data)
                dbgLog("DONE load_gestures key=\(gesturesKey) count=\(gestures.count)")
                return gestures
            } catch {
                dbgLog("BAIL load_gestures key=\(gesturesKey) reason=decode_failed error=\(error.localizedDescription)")
                return []
            }
        }

        // First launch on the new schema: migrate continuous-only gestures from v2 and
        // drop the v2 key so this doesn't run again.
        if let v2Data = persistedData(forKey: v2GesturesKey) {
            UserDefaults.standard.removeObject(forKey: v2GesturesKey)
            synchronizeDefaults()
            do {
                let decoded = try decoder.decode([AirGestureDefinition].self, from: v2Data)
                let migration = migrateLegacyContinuousPresetShortcuts(in: decoded)
                let migrated = migration.gestures.filter { $0.inputType == .continuous }
                save(migrated)
                dbgLog("DONE load_gestures key=\(v2GesturesKey) migrated_count=\(migrated.count)")
                return migrated
            } catch {
                dbgLog("BAIL load_gestures key=\(v2GesturesKey) reason=migration_decode_failed error=\(error.localizedDescription)")
                save([])
                return []
            }
        }

        dbgLog("DONE load_gestures key=\(gesturesKey) count=0 source=default")
        return []
    }

    @discardableResult
    func save(_ gestures: [AirGestureDefinition]) -> Bool {
        dbgLog("ENTRY save_gestures key=\(gesturesKey) count=\(gestures.count)")
        let data: Data
        do {
            data = try encoder.encode(gestures)
        } catch {
            assertionFailure("Failed to encode gestures: \(error.localizedDescription)")
            dbgLog("BAIL save_gestures key=\(gesturesKey) reason=encode_failed error=\(error.localizedDescription)")
            return false
        }

        UserDefaults.standard.set(data, forKey: gesturesKey)
        synchronizeDefaults()
        dbgLog("DONE save_gestures key=\(gesturesKey) bytes=\(data.count)")
        return true
    }

    func loadRecognitionSettings() -> AirGestureRecognitionSettings {
        dbgLog("ENTRY load_recognition_settings key=\(recognitionKey)")
        guard let data = persistedData(forKey: recognitionKey) else {
            dbgLog("DONE load_recognition_settings key=\(recognitionKey) source=default")
            return AirGestureRecognitionSettings()
        }

        do {
            let settings = try decoder.decode(AirGestureRecognitionSettings.self, from: data)
            dbgLog("DONE load_recognition_settings key=\(recognitionKey) bytes=\(data.count)")
            return settings
        } catch {
            dbgLog("BAIL load_recognition_settings key=\(recognitionKey) reason=decode_failed error=\(error.localizedDescription)")
            return AirGestureRecognitionSettings()
        }
    }

    @discardableResult
    func saveRecognitionSettings(_ settings: AirGestureRecognitionSettings) -> Bool {
        dbgLog("ENTRY save_recognition_settings key=\(recognitionKey)")
        let data: Data
        do {
            data = try encoder.encode(settings)
        } catch {
            assertionFailure("Failed to encode recognition settings: \(error.localizedDescription)")
            dbgLog("BAIL save_recognition_settings key=\(recognitionKey) reason=encode_failed error=\(error.localizedDescription)")
            return false
        }

        UserDefaults.standard.set(data, forKey: recognitionKey)
        synchronizeDefaults()
        dbgLog("DONE save_recognition_settings key=\(recognitionKey) bytes=\(data.count)")
        return true
    }

    func loadAppearanceSettings() -> AirGestureAppearanceSettings {
        dbgLog("ENTRY load_appearance_settings key=\(appearanceKey)")
        guard let data = persistedData(forKey: appearanceKey) else {
            dbgLog("DONE load_appearance_settings key=\(appearanceKey) source=default")
            return AirGestureAppearanceSettings()
        }

        do {
            let settings = try decoder.decode(AirGestureAppearanceSettings.self, from: data)
            dbgLog("DONE load_appearance_settings key=\(appearanceKey) bytes=\(data.count)")
            return settings
        } catch {
            dbgLog("BAIL load_appearance_settings key=\(appearanceKey) reason=decode_failed error=\(error.localizedDescription)")
            return AirGestureAppearanceSettings()
        }
    }

    @discardableResult
    func saveAppearanceSettings(_ settings: AirGestureAppearanceSettings) -> Bool {
        dbgLog("ENTRY save_appearance_settings key=\(appearanceKey)")
        let data: Data
        do {
            data = try encoder.encode(settings)
        } catch {
            assertionFailure("Failed to encode appearance settings: \(error.localizedDescription)")
            dbgLog("BAIL save_appearance_settings key=\(appearanceKey) reason=encode_failed error=\(error.localizedDescription)")
            return false
        }

        UserDefaults.standard.set(data, forKey: appearanceKey)
        synchronizeDefaults()
        dbgLog("DONE save_appearance_settings key=\(appearanceKey) bytes=\(data.count)")
        return true
    }

    func loadTrackingEnabled() -> Bool {
        guard let persistedValue = persistedObject(forKey: trackingEnabledKey) else {
            dbgLog("DONE load_tracking key=\(trackingEnabledKey) enabled=true source=default")
            return true
        }

        let enabled: Bool
        if let value = persistedValue as? Bool {
            enabled = value
        } else if let value = persistedValue as? NSNumber {
            enabled = value.boolValue
        } else {
            enabled = UserDefaults.standard.bool(forKey: trackingEnabledKey)
        }
        dbgLog("DONE load_tracking key=\(trackingEnabledKey) enabled=\(enabled)")
        return enabled
    }

    @discardableResult
    func saveTrackingEnabled(_ enabled: Bool) -> Bool {
        UserDefaults.standard.set(enabled, forKey: trackingEnabledKey)
        synchronizeDefaults()
        dbgLog("DONE save_tracking key=\(trackingEnabledKey) enabled=\(enabled)")
        return true
    }

    func loadDebugMode() -> Bool {
        let enabled = DebugFileLog.persistentBool(forKey: debugModeKey)
        dbgLog("DONE load_debug_mode key=\(debugModeKey) enabled=\(enabled)")
        return enabled
    }

    func loadVerboseDebugMode() -> Bool {
        let enabled = DebugFileLog.persistentBool(forKey: verboseModeKey)
        dbgLog("DONE load_verbose_debug_mode key=\(verboseModeKey) enabled=\(enabled)")
        return enabled
    }

    private func migrateSandboxPreferencesIfNeeded() {
        let defaults = UserDefaults.standard
        let keys = [gesturesKey, recognitionKey, appearanceKey, trackingEnabledKey, debugModeKey, verboseModeKey]
        guard shouldReadSandboxPreferences(for: keys, defaults: defaults) else { return }

        let sandboxURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.jos.airpod-control/Data/Library/Preferences/com.jos.airpod-control.plist")

        guard let legacyValues = propertyListValues(at: sandboxURL) else {
            return
        }

        var didMigrate = false
        for key in keys {
            guard shouldMigrateValue(forKey: key, defaults: defaults, legacyValues: legacyValues) else { continue }
            defaults.set(legacyValues[key], forKey: key)
            didMigrate = true
            dbgLog("DONE migrate_sandbox_preference key=\(key)")
        }
        if didMigrate {
            synchronizeDefaults()
        }
    }

    private func shouldReadSandboxPreferences(for keys: [String], defaults: UserDefaults) -> Bool {
        keys.contains { key in
            guard let currentValue = defaults.object(forKey: key) else { return true }
            if let currentData = currentValue as? Data {
                return currentData.count <= 2
            }
            return false
        }
    }

    private func shouldMigrateValue(
        forKey key: String,
        defaults: UserDefaults,
        legacyValues: [String: Any]
    ) -> Bool {
        guard let legacyValue = legacyValues[key] else { return false }

        guard let currentValue = defaults.object(forKey: key) else {
            return true
        }

        if let currentData = currentValue as? Data,
           let legacyData = legacyValue as? Data {
            return currentData.count <= 2 && legacyData.count > currentData.count
        }

        return false
    }

    private func persistedObject(forKey key: String) -> Any? {
        if let value = preferencesFileValues()?[key] {
            return value
        }

        let domainName = Bundle.main.bundleIdentifier ?? "com.jos.airpod-control"
        if let value = UserDefaults.standard.persistentDomain(forName: domainName)?[key] {
            return value
        }

        return UserDefaults.standard.object(forKey: key)
    }

    private func persistedData(forKey key: String) -> Data? {
        if let value = persistedObject(forKey: key) as? Data {
            return value
        }
        if let value = persistedObject(forKey: key) as? NSData {
            return value as Data
        }
        return UserDefaults.standard.data(forKey: key)
    }

    private func preferencesFileValues() -> [String: Any]? {
        guard !Self.isRunningUnitTests else { return nil }

        let domainName = Bundle.main.bundleIdentifier ?? "com.jos.airpod-control"
        let preferencesURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(domainName).plist")
        return propertyListValues(at: preferencesURL)
    }

    private func propertyListValues(at url: URL, maximumSize: UInt64 = 1_000_000) -> [String: Any]? {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { return nil }
            guard let fileSize = values.fileSize, fileSize <= maximumSize else { return nil }

            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            return try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        } catch {
            dbgLog("BAIL read_preferences_file path=\(url.path) error=\(error.localizedDescription)")
            return nil
        }
    }

    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private func synchronizeDefaults() {
        UserDefaults.standard.synchronize()
    }

    private func migrateLegacyContinuousPresetShortcuts(in gestures: [AirGestureDefinition]) -> (gestures: [AirGestureDefinition], didChange: Bool) {
        var didChange = false

        let migrated = gestures.map { gesture in
            guard gesture.inputType == .continuous else { return gesture }

            if isLegacyVolumePreset(gesture) {
                var updated = gesture
                updated.trigger.shortcut = mediaShortcut(key: "volume_up")
                updated.reverseTrigger?.shortcut = mediaShortcut(key: "volume_down")
                didChange = true
                return updated
            }

            if isLegacyBrightnessPreset(gesture) {
                var updated = gesture
                updated.trigger.shortcut = mediaShortcut(key: "brightness_up")
                updated.reverseTrigger?.shortcut = mediaShortcut(key: "brightness_down")
                didChange = true
                return updated
            }

            return gesture
        }

        return (migrated, didChange)
    }

    private func isLegacyVolumePreset(_ gesture: AirGestureDefinition) -> Bool {
        gesture.trigger.type == .keyboardShortcut
            && gesture.reverseTrigger?.type == .keyboardShortcut
            && shortcutMatches(gesture.trigger.shortcut, legacyShortcut(key: "f12"))
            && shortcutMatches(gesture.reverseTrigger?.shortcut, legacyShortcut(key: "f11"))
    }

    private func isLegacyBrightnessPreset(_ gesture: AirGestureDefinition) -> Bool {
        gesture.trigger.type == .keyboardShortcut
            && gesture.reverseTrigger?.type == .keyboardShortcut
            && shortcutMatches(gesture.trigger.shortcut, legacyShortcut(key: "f2"))
            && shortcutMatches(gesture.reverseTrigger?.shortcut, legacyShortcut(key: "f1"))
    }

    private func legacyShortcut(key: String) -> GestureShortcut {
        GestureShortcut(key: key, command: true, shift: false, option: false, control: false)
    }

    private func mediaShortcut(key: String) -> GestureShortcut {
        GestureShortcut(key: key, command: false, shift: false, option: false, control: false)
    }

    private func shortcutMatches(_ lhs: GestureShortcut?, _ rhs: GestureShortcut) -> Bool {
        guard let lhs else { return false }

        return lhs.key == rhs.key
            && lhs.command == rhs.command
            && lhs.shift == rhs.shift
            && lhs.option == rhs.option
            && lhs.control == rhs.control
    }
}
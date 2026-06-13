import Foundation
import os

nonisolated func dbgLog(_ msg: @autoclosure () -> String) {
    DebugFileLog.log(msg())
}

nonisolated func dbgVerboseLog(_ msg: @autoclosure () -> String) {
    DebugFileLog.verboseLog(msg())
}

enum DebugFileLog {
    nonisolated static let appName = "airpod_control"
    nonisolated static let logPath = "/tmp/\(appName).log"
    nonisolated static let debugModeKey = "airpod_control.debugMode"
    nonisolated static let verboseModeKey = "airpod_control.verboseDebugMode"

    nonisolated private static let enabledLock = OSAllocatedUnfairLock(initialState: false)
    nonisolated private static let verboseLock = OSAllocatedUnfairLock(initialState: false)
    nonisolated private static let writeQueue = DispatchQueue(label: "com.jos.airpod-control.debug-file-log")

    nonisolated static var isEnabled: Bool {
        enabledLock.withLock { $0 }
    }

    nonisolated static var isVerboseEnabled: Bool {
        verboseLock.withLock { $0 }
    }

    nonisolated static func configureOnLaunch() {
        let enabled = persistentBool(forKey: debugModeKey)
        let verboseEnabled = persistentBool(forKey: verboseModeKey)
        enabledLock.withLock { $0 = enabled }
        verboseLock.withLock { $0 = verboseEnabled }

        Task { @MainActor in
            DebugHUDWindowController.shared.setVisible(enabled)
        }

        guard enabled else { return }
        truncate(reason: "launch")
    }

    nonisolated static func persistentBool(forKey key: String) -> Bool {
        let domainName = Bundle.main.bundleIdentifier ?? "com.jos.airpod-control"
        if let value = boolFromPreferencesFile(forKey: key, domainName: domainName) {
            return value
        }
        if let value = UserDefaults.standard.persistentDomain(forName: domainName)?[key] as? Bool {
            return value
        }
        if let value = UserDefaults.standard.persistentDomain(forName: domainName)?[key] as? NSNumber {
            return value.boolValue
        }
        return false
    }

    nonisolated static func setEnabled(_ enabled: Bool, reason: String) {
        let wasEnabled = isEnabled

        if wasEnabled && !enabled {
            log("debug_logging disabled reason=\(reason)")
        }

        UserDefaults.standard.set(enabled, forKey: debugModeKey)
        UserDefaults.standard.synchronize()
        enabledLock.withLock { $0 = enabled }

        Task { @MainActor in
            DebugHUDWindowController.shared.setVisible(enabled)
        }

        guard enabled else { return }

        if !wasEnabled {
            truncate(reason: reason)
        }
        log("debug_logging enabled reason=\(reason) path=\(logPath)")
    }

    nonisolated static func setVerboseEnabled(_ enabled: Bool, reason: String) {
        UserDefaults.standard.set(enabled, forKey: verboseModeKey)
        UserDefaults.standard.synchronize()
        verboseLock.withLock { $0 = enabled }

        guard isEnabled else { return }
        log("debug_logging verbose=\(enabled) reason=\(reason)")
    }

    nonisolated static func clearLog(reason: String) {
        truncate(reason: reason)

        guard isEnabled else { return }
        log("debug_log cleared reason=\(reason) path=\(logPath)")
    }

    nonisolated static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }

        let line = "[\(timestampString())] \(message())"
        append(line: line)

        Task { @MainActor in
            DebugHUDStore.shared.append(line)
        }
    }

    nonisolated static func verboseLog(_ message: @autoclosure () -> String) {
        guard isVerboseEnabled else { return }
        log(message())
    }

    nonisolated private static func truncate(reason: String) {
        writeQueue.async {
            let url = URL(fileURLWithPath: logPath)
            try? Data().write(to: url, options: .atomic)
        }

        Task { @MainActor in
            DebugHUDStore.shared.reset()
        }
    }

    nonisolated private static func append(line: String) {
        writeQueue.async {
            let url = URL(fileURLWithPath: logPath)
            let data = Data((line + "\n").utf8)

            if !FileManager.default.fileExists(atPath: logPath) {
                FileManager.default.createFile(atPath: logPath, contents: nil)
            }

            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    nonisolated private static func boolFromPreferencesFile(forKey key: String, domainName: String) -> Bool? {
        let preferencesURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(domainName).plist")
        guard let values = NSDictionary(contentsOf: preferencesURL) as? [String: Any] else {
            return nil
        }

        if let value = values[key] as? Bool {
            return value
        }
        if let value = values[key] as? NSNumber {
            return value.boolValue
        }
        return nil
    }

    nonisolated private static func timestampString() -> String {
        let components = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: Date())
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = components.second ?? 0
        let millisecond = (components.nanosecond ?? 0) / 1_000_000
        return String(format: "%02d:%02d:%02d.%03d", hour, minute, second, millisecond)
    }
}

enum GestureReplayLogEncoder {
    struct Score: Codable, Equatable {
        let name: String
        let score: Double
    }

    struct Point: Codable, Equatable {
        let t: Double
        let x: Double
        let y: Double
        let yaw: Double
        let pitch: Double
        let roll: Double
        let tx: Double
        let ty: Double
        let tz: Double
    }

    struct Record: Codable, Equatable {
        let schema: Int
        let intended: String
        let sourceCount: Int
        let duration: Double
        let threshold: Double
        let marginThreshold: Double
        let scores: [Score]
        let points: [Point]
    }

    static func encode(
        intended: String,
        path: [AirGesturePoint],
        scores: [Score],
        threshold: Double,
        marginThreshold: Double,
        maximumPoints: Int = 64
    ) -> String? {
        let record = Record(
            schema: 1,
            intended: intended,
            sourceCount: path.count,
            duration: rounded((path.last?.timestamp ?? 0) - (path.first?.timestamp ?? 0)),
            threshold: rounded(threshold),
            marginThreshold: rounded(marginThreshold),
            scores: scores.map { Score(name: $0.name, score: rounded($0.score, places: 1_000)) },
            points: compactPoints(from: path, maximumCount: maximumPoints)
        )

        guard let data = try? JSONEncoder().encode(record) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func compactPoints(from path: [AirGesturePoint], maximumCount: Int) -> [Point] {
        guard maximumCount > 0, let first = path.first else { return [] }
        guard path.count > maximumCount else {
            return path.map { replayPoint(from: $0, firstTimestamp: first.timestamp) }
        }
        guard maximumCount > 1 else {
            return [replayPoint(from: first, firstTimestamp: first.timestamp)]
        }

        let lastIndex = path.count - 1
        return (0..<maximumCount).map { index in
            let rawIndex = Double(index) * Double(lastIndex) / Double(maximumCount - 1)
            return replayPoint(from: path[Int(rawIndex.rounded())], firstTimestamp: first.timestamp)
        }
    }

    private static func replayPoint(from point: AirGesturePoint, firstTimestamp: TimeInterval) -> Point {
        Point(
            t: rounded(point.timestamp - firstTimestamp),
            x: rounded(point.x),
            y: rounded(point.y),
            yaw: rounded(point.yaw),
            pitch: rounded(point.pitch),
            roll: rounded(point.roll),
            tx: rounded(point.tx),
            ty: rounded(point.ty),
            tz: rounded(point.tz)
        )
    }

    private static func rounded(_ value: Double, places: Double = 100_000) -> Double {
        guard value.isFinite else { return 0 }
        return (value * places).rounded() / places
    }
}
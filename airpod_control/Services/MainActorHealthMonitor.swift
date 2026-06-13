import Foundation
import os

enum MainActorHealthMonitor {
    private struct MonitorState: @unchecked Sendable {
        var isStarted = false
        var lastHeartbeat = Date.distantPast
        var lastStallLog = Date.distantPast
        var heartbeatTask: Task<Void, Never>?
        var watchdogTimer: DispatchSourceTimer?
    }

    nonisolated private static let stateLock = OSAllocatedUnfairLock(initialState: MonitorState())
    nonisolated private static let watchdogQueue = DispatchQueue(label: "com.jos.airpod-control.main-actor-watchdog")
    nonisolated private static let heartbeatInterval: TimeInterval = 1.0
    nonisolated private static let stallThreshold: TimeInterval = 5.0
    nonisolated private static let stallLogInterval: TimeInterval = 10.0

    nonisolated static func start() {
        let shouldStart = stateLock.withLock { state in
            guard !state.isStarted else { return false }
            state.isStarted = true
            state.lastHeartbeat = Date()
            return true
        }
        guard shouldStart else { return }

        let heartbeatTask = Task { @MainActor in
            while !Task.isCancelled {
                recordHeartbeat()
                try? await Task.sleep(for: .seconds(1))
            }
        }

        let watchdogTimer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        watchdogTimer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(2))
        watchdogTimer.setEventHandler {
            reportStallIfNeeded()
        }

        stateLock.withLock { state in
            state.heartbeatTask = heartbeatTask
            state.watchdogTimer = watchdogTimer
        }
        watchdogTimer.resume()
        dbgLog(String(format: "STATE main_actor_watchdog started threshold=%.1fs", stallThreshold))
    }

    nonisolated static func stop() {
        let handles = stateLock.withLock { state -> (Task<Void, Never>?, DispatchSourceTimer?) in
            guard state.isStarted else { return (nil, nil) }
            state.isStarted = false
            let handles = (state.heartbeatTask, state.watchdogTimer)
            state.heartbeatTask = nil
            state.watchdogTimer = nil
            return handles
        }

        handles.0?.cancel()
        handles.1?.cancel()
    }

    nonisolated private static func recordHeartbeat() {
        stateLock.withLock { state in
            state.lastHeartbeat = Date()
        }
    }

    nonisolated private static func reportStallIfNeeded() {
        let now = Date()
        let staleFor = stateLock.withLock { state -> TimeInterval? in
            let staleFor = now.timeIntervalSince(state.lastHeartbeat)
            guard staleFor >= stallThreshold else { return nil }
            guard now.timeIntervalSince(state.lastStallLog) >= stallLogInterval else { return nil }
            state.lastStallLog = now
            return staleFor
        }

        guard let staleFor else { return }
        dbgLog(String(format: "WARN main_actor_stall stale=%.1fs threshold=%.1fs", staleFor, stallThreshold))
    }
}
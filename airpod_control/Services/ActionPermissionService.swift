import ApplicationServices
import Foundation

enum ActionPermissionService {
    enum KeyboardShortcutPermissionIssue: Sendable {
        case accessibility
        case postEvents
    }

    struct PermissionSnapshot: Equatable, Sendable {
        let accessibilityGranted: Bool
        let postEventsGranted: Bool
        let inputMonitoringGranted: Bool
    }

    static func currentSnapshot() -> PermissionSnapshot {
        dbgLog("ENTRY permission_snapshot")
        let snapshot = PermissionSnapshot(
            accessibilityGranted: ensureAccessibilityPermission(prompt: false),
            postEventsGranted: ensurePostEventAccess(prompt: false),
            inputMonitoringGranted: ensureInputMonitoringPermission(prompt: false)
        )
        dbgLog("DONE permission_snapshot accessibility=\(snapshot.accessibilityGranted) post_events=\(snapshot.postEventsGranted) input_monitoring=\(snapshot.inputMonitoringGranted)")
        return snapshot
    }

    static func ensureAccessibilityPermission(prompt: Bool = true) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        dbgLog("EXTERNAL AXIsProcessTrustedWithOptions prompt=\(prompt) return=\(granted)")
        return granted
    }

    static func ensurePostEventAccess(prompt: Bool = true) -> Bool {
        if prompt {
            let granted = CGRequestPostEventAccess()
            dbgLog("EXTERNAL CGRequestPostEventAccess prompt=true return=\(granted)")
            return granted
        }

        let granted = CGPreflightPostEventAccess()
        dbgLog("EXTERNAL CGPreflightPostEventAccess prompt=false return=\(granted)")
        return granted
    }

    static func ensureInputMonitoringPermission(prompt: Bool = true) -> Bool {
        if prompt {
            let granted = CGRequestListenEventAccess()
            dbgLog("EXTERNAL CGRequestListenEventAccess prompt=true return=\(granted)")
            return granted
        }

        let granted = CGPreflightListenEventAccess()
        dbgLog("EXTERNAL CGPreflightListenEventAccess prompt=false return=\(granted)")
        return granted
    }

    static func keyboardShortcutPermissionIssue(prompt: Bool = true) -> KeyboardShortcutPermissionIssue? {
        dbgLog("ENTRY keyboard_shortcut_permission prompt=\(prompt)")
        guard ensureAccessibilityPermission(prompt: prompt) else {
            dbgLog("BAIL keyboard_shortcut_permission reason=accessibility_missing")
            return .accessibility
        }

        guard ensurePostEventAccess(prompt: prompt) else {
            dbgLog("BAIL keyboard_shortcut_permission reason=post_events_missing")
            return .postEvents
        }

        dbgLog("DONE keyboard_shortcut_permission result=granted")
        return nil
    }

    static func accessibilityErrorMessage(for actionDescription: String) -> String {
        "AirPods Control needs Accessibility permission to \(actionDescription). Open System Settings > Privacy & Security > Accessibility, allow AirPods Control, then try again."
    }

    static func keyboardShortcutErrorMessage(for issue: KeyboardShortcutPermissionIssue) -> String {
        switch issue {
        case .accessibility:
            return accessibilityErrorMessage(for: "send keyboard shortcuts")
        case .postEvents:
            return "AirPods Control can recognize the gesture, but macOS is blocking posted keyboard events. Re-open System Settings > Privacy & Security > Accessibility, re-enable AirPods Control, and if you recently rebuilt the app remove the old entry and add it again before relaunching."
        }
    }
}

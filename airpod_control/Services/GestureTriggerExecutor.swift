import Foundation
import OSLog

@MainActor
enum GestureTriggerExecutor {
    static func execute(_ trigger: GestureTrigger, using store: LiveSensorStore) {
        store.errorMessage = nil
        GestureDiagnostics.logger.debug("action_execute type=\(trigger.type.rawValue, privacy: .public) label=\(trigger.displayName, privacy: .public)")
        dbgLog("ENTRY action_execute type=\(trigger.type.rawValue) label=\(trigger.displayName)")

        switch trigger.type {
        case .builtIn:
            executeBuiltIn(trigger.builtInAction, using: store)
            dbgLog("DONE action_execute type=builtIn label=\(trigger.displayName)")
        case .openApp:
            if GestureAppLauncher.launch(name: trigger.appName, path: trigger.appPath) {
                store.statusMessage = "Trigger: \(trigger.displayName)"
                store.lastActionStatus = "Launched: \(trigger.displayName)"
                GestureDiagnostics.logger.debug("action_success type=open_app label=\(trigger.displayName, privacy: .public)")
                dbgLog("DONE action_execute type=open_app result=success label=\(trigger.displayName)")
            } else {
                store.statusMessage = "App launch failed"
                store.errorMessage = "Could not launch \(trigger.displayName). Check the selected app path or name."
                store.lastActionStatus = "App launch failed: \(trigger.displayName)"
                GestureDiagnostics.logger.error("action_failure type=open_app label=\(trigger.displayName, privacy: .public)")
                dbgLog("BAIL action_execute type=open_app reason=launch_failed label=\(trigger.displayName)")
            }
        case .windowAction:
            guard ActionPermissionService.ensureAccessibilityPermission(prompt: true) else {
                store.statusMessage = "Accessibility permission required"
                store.errorMessage = ActionPermissionService.accessibilityErrorMessage(for: "control other app windows")
                GestureDiagnostics.logger.error("action_permission_missing type=window_action")
                dbgLog("BAIL action_execute type=window_action reason=accessibility_missing")
                return
            }

            if GestureWindowManager.execute(trigger.windowAction) {
                store.statusMessage = "Trigger: \(trigger.displayName)"
                GestureDiagnostics.logger.debug("action_success type=window_action label=\(trigger.displayName, privacy: .public)")
                dbgLog("DONE action_execute type=window_action result=success label=\(trigger.displayName)")
            } else {
                store.statusMessage = "Window action failed"
                store.errorMessage = "Could not apply \(trigger.displayName). Make sure another app window is focused and accessible."
                GestureDiagnostics.logger.error("action_failure type=window_action label=\(trigger.displayName, privacy: .public)")
                dbgLog("BAIL action_execute type=window_action reason=execute_failed label=\(trigger.displayName)")
            }
        case .keyboardShortcut:
            if GestureShortcutExecutor.canExecuteWithoutKeyboardPermissions(trigger.shortcut) {
                dbgLog("DECISION action_permission result=skip_preflight reason=shortcut_safe_without_keyboard_permissions label=\(trigger.displayName)")
                executeKeyboardShortcut(trigger, using: store)
                return
            }

            let permissionSnapshot = ActionPermissionService.currentSnapshot()
            GestureDiagnostics.logger.debug(
                "action_permission_snapshot type=keyboard_shortcut accessibility=\(permissionSnapshot.accessibilityGranted, privacy: .public) post_events=\(permissionSnapshot.postEventsGranted, privacy: .public) input_monitoring=\(permissionSnapshot.inputMonitoringGranted, privacy: .public)"
            )

            if let permissionIssue = ActionPermissionService.keyboardShortcutPermissionIssue(prompt: true) {
                store.statusMessage = permissionIssue == .accessibility ? "Accessibility permission required" : "Keyboard event permission required"
                store.errorMessage = ActionPermissionService.keyboardShortcutErrorMessage(for: permissionIssue)
                GestureDiagnostics.logger.error(
                    "action_permission_missing type=keyboard_shortcut accessibility=\(permissionSnapshot.accessibilityGranted, privacy: .public) post_events=\(permissionSnapshot.postEventsGranted, privacy: .public) input_monitoring=\(permissionSnapshot.inputMonitoringGranted, privacy: .public)"
                )
                dbgLog("BAIL action_execute type=keyboard_shortcut reason=permission_missing issue=\(permissionIssue) accessibility=\(permissionSnapshot.accessibilityGranted) post_events=\(permissionSnapshot.postEventsGranted) input_monitoring=\(permissionSnapshot.inputMonitoringGranted)")
                return
            }

            executeKeyboardShortcut(trigger, using: store)
        }
    }

    private static func executeKeyboardShortcut(_ trigger: GestureTrigger, using store: LiveSensorStore) {
        if GestureShortcutExecutor.execute(trigger.shortcut) {
            store.statusMessage = "Trigger: \(trigger.displayName)"
            store.lastActionStatus = "Sent shortcut: \(trigger.displayName)"
            GestureDiagnostics.logger.debug("action_success type=keyboard_shortcut label=\(trigger.displayName, privacy: .public)")
            dbgLog("DONE action_execute type=keyboard_shortcut result=success label=\(trigger.displayName)")
        } else {
            store.statusMessage = "Shortcut failed"
            store.errorMessage = "Could not send \(trigger.displayName). Check the recorded shortcut and macOS permissions."
            store.lastActionStatus = "Shortcut failed: \(trigger.displayName)"
            GestureDiagnostics.logger.error("action_failure type=keyboard_shortcut label=\(trigger.displayName, privacy: .public)")
            dbgLog("BAIL action_execute type=keyboard_shortcut reason=execute_failed label=\(trigger.displayName)")
        }
    }

    private static func executeBuiltIn(_ action: GestureTaskAction, using store: LiveSensorStore) {
        dbgLog("ENTRY built_in_action action=\(action.rawValue)")
        switch action {
        case .copySnapshot:
            store.copyCurrentSnapshot()
        case .exportCSV:
            store.exportCSV()
        case .exportJSON:
            store.exportJSON()
        case .startStream:
            store.startStreaming()
        case .stopStream:
            store.stopStreaming()
        case .increaseExportWindow:
            store.exportDurationSeconds = min(store.exportDurationSeconds + 5, 180)
            store.statusMessage = "Duration \(Int(store.exportDurationSeconds))s"
        case .decreaseExportWindow:
            store.exportDurationSeconds = max(store.exportDurationSeconds - 5, 5)
            store.statusMessage = "Duration \(Int(store.exportDurationSeconds))s"
        case .markEvent:
            store.statusMessage = "Event marked at \(Date().formatted(date: .omitted, time: .standard))"
        }
        dbgLog("DONE built_in_action action=\(action.rawValue)")
    }
}

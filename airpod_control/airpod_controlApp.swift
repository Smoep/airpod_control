//
//  airpod_controlApp.swift
//  airpod_control
//
//  Created by Jos on 25/4/26.
//

import AppKit
import SwiftUI

final class AirpodControlAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        dbgLog("LIFECYCLE shutdown notification=applicationWillTerminate")
        MainActorHealthMonitor.stop()
    }
}

@main
struct airpod_controlApp: App {
    @NSApplicationDelegateAdaptor(AirpodControlAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: LiveSensorStore

    init() {
        DebugFileLog.configureOnLaunch()
        MainActorHealthMonitor.start()
        dbgLog("LIFECYCLE launch revision=\(AppRevision.current) log=\(DebugFileLog.logPath)")
        let store = LiveSensorStore()
        _store = State(initialValue: store)
        if RuntimeEnvironment.shouldUsePhysicalMotionHardware {
            Task { @MainActor in
                HeadActivationOverlayWindowController.shared.bind(to: store)
                if store.isGestureDetectionEnabled {
                    store.startStreaming()
                }
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            AirpodControlMenuBarView(store: store)
        } label: {
            AirPodsControlMenuBarIcon(
                isTrackingEnabled: store.isGestureDetectionEnabled,
                isReceivingMotion: store.availabilityState.connectionState == .connected
            )
        }

        WindowGroup("Settings", id: "settings") {
            ContentView(store: store)
                .onChange(of: scenePhase) { _, phase in
                    dbgLog("LIFECYCLE scene_phase=\(String(describing: phase))")
                }
        }
        .defaultLaunchBehavior(.suppressed)
    }
}

private struct AirPodsControlMenuBarIcon: View {
    let isTrackingEnabled: Bool
    let isReceivingMotion: Bool

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 13, weight: .medium))
        .frame(width: 19, height: 16)
        .accessibilityLabel(accessibilityLabel)
    }

    private var symbolName: String {
        if !isTrackingEnabled { return "antenna.radiowaves.left.and.right.slash" }
        if !isReceivingMotion { return "wifi.exclamationmark" }
        return "dot.radiowaves.left.and.right"
    }

    private var accessibilityLabel: String {
        if !isTrackingEnabled { return "AirPods Control, tracking paused" }
        if !isReceivingMotion { return "AirPods Control, no motion connection" }
        return "AirPods Control, connected"
    }
}

private struct AirpodControlMenuBarView: View {
    @Bindable var store: LiveSensorStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle("Tracking", isOn: Binding(
            get: { store.isGestureDetectionEnabled },
            set: { store.setTrackingEnabled($0) }
        ))

        Divider()

        Button("Settings") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("Quit") {
            NSApp.terminate(nil)
        }
    }
}

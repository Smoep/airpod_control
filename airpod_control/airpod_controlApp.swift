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
        Task { @MainActor in
            if store.isGestureDetectionEnabled {
                store.startStreaming()
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            AirpodControlMenuBarView(store: store)
        } label: {
            Label(
                "AirPods Control",
                systemImage: store.isGestureDetectionEnabled ? "dot.radiowaves.left.and.right" : "pause.circle"
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

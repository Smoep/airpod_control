import AppKit
import Observation
import SwiftUI

/// Hosts the activation overlay independently from Settings so it remains centered
/// and visible on every Space, including while the settings window is closed.
@MainActor
final class HeadActivationOverlayWindowController {
    static let shared = HeadActivationOverlayWindowController()

    private let windowSize = NSSize(width: 480, height: 480)
    private weak var store: LiveSensorStore?
    private var panel: NSPanel?

    private init() {}

    func bind(to store: LiveSensorStore) {
        self.store = store
        observeVisibility()
    }

    private func observeVisibility() {
        guard let store else { return }

        let shouldShow = withObservationTracking {
            store.shouldShowHeadOverlay
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeVisibility()
            }
        }

        setVisible(shouldShow)
    }

    private func setVisible(_ visible: Bool) {
        guard visible else {
            if panel?.isVisible == true {
                dbgLog("OVERLAY hide location=screen_center")
            }
            panel?.orderOut(nil)
            return
        }

        let panel = panel ?? makePanel()
        center(panel, on: activeScreen())
        panel.orderFrontRegardless()
        dbgLog("OVERLAY show location=screen_center level=screen_saver")
    }

    private func makePanel() -> NSPanel {
        guard let store else { preconditionFailure("Overlay store must be bound before creating its panel") }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: HeadActivationOverlayWindowContent(store: store))
        self.panel = panel
        return panel
    }

    private func activeScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
    }

    private func center(_ panel: NSPanel, on screen: NSScreen?) {
        guard let screen else { return }
        let frame = screen.frame
        let origin = NSPoint(
            x: frame.midX - windowSize.width / 2,
            y: frame.midY - windowSize.height / 2
        )
        panel.setFrame(NSRect(origin: origin, size: windowSize), display: false)
    }
}

private struct HeadActivationOverlayWindowContent: View {
    @Bindable var store: LiveSensorStore

    var body: some View {
        HeadActivationOverlayView(
            opacity: store.appearanceSettings.overlayOpacity,
            scale: store.appearanceSettings.overlayScale,
            roll: store.liveHeadAttitudeRoll,
            pitch: store.liveHeadAttitudePitch,
            yaw: store.liveHeadAttitudeYaw,
            gateState: store.alwaysOnGateDisplayState,
            gateDistanceProgress: store.alwaysOnGateDistanceProgress,
            gateSpeedProgress: store.alwaysOnGateSpeedProgress,
            gateDistance: store.alwaysOnGateDistance,
            gateSpeed: store.alwaysOnGateSpeed
        )
        .frame(width: 480, height: 480)
        .allowsHitTesting(false)
        .transaction { $0.animation = nil }
    }
}

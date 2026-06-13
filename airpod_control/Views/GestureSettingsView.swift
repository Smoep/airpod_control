import Observation
import SwiftUI

struct GestureSettingsView: View {
    @Bindable var store: LiveSensorStore
    @State private var permissionSnapshot = ActionPermissionService.PermissionSnapshot(
        accessibilityGranted: false,
        postEventsGranted: false,
        inputMonitoringGranted: false
    )
    @State private var didLoadPermissionSnapshot = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings")
                    .font(.largeTitle.weight(.semibold))

                GlassCard(title: "Diagnostics") {
                    Toggle("Debug logging", isOn: $store.debugMode)
                        .toggleStyle(.switch)
                        .help("Writes detailed events to /tmp/airpod_control.log")

                    Toggle("Verbose frame logging", isOn: $store.verboseDebugMode)
                        .toggleStyle(.switch)
                        .disabled(!store.debugMode)
                        .help("Includes per-frame motion and Fn polling lines. Leave off for compact gesture analysis.")

                    HStack(spacing: 12) {
                        Text(DebugFileLog.logPath)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Button("Clear Log") {
                            store.clearDebugLog()
                        }
                    }

                    settingExplanation(
                        "Normal debug logging writes compact replay records and recognition decisions. Verbose logging adds per-frame sensor lines for low-level device debugging."
                    )
                }

                GlassCard(title: "Backups") {
                    Text("Save your trained gesture recordings and recognition settings to a JSON file. This protects the current calibration set even if app preferences are reset or replaced.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button("Export Gesture Backup...") {
                            store.exportGestureBackup()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Restore Gesture Backup...") {
                            store.restoreGestureBackup()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                GlassCard(title: "Recognition") {
                    Picker("Activation Layer", selection: $store.recognitionSettings.activationLayer) {
                        ForEach(ActivationLayer.allCases) { layer in
                            Text(layer.rawValue).tag(layer)
                        }
                    }

                    settingExplanation(
                        "Fn Key evaluates one gesture when Fn is released. Always On listens continuously and uses the timing controls below to decide when a gesture starts, fires, and resets."
                    )

                    sliderRow(
                        title: "Confidence",
                        value: $store.recognitionSettings.confidenceThreshold,
                        range: 0.30...0.95,
                        step: 0.01,
                        format: .number.precision(.fractionLength(2))
                    )

                    settingExplanation(
                        "Confidence is the overall match strictness. Higher values require a cleaner match before an action runs. Lower values make gestures easier to trigger but can increase false positives."
                    )
                }

                GlassCard(title: "Always On Recognition") {
                    settingExplanation(
                        "These controls are used only when Activation Layer is Always On. They gate candidate capture with movement distance and speed, then control finishing and reset."
                    )

                    sliderRow(
                        title: "Start Movement",
                        value: $store.recognitionSettings.alwaysOnStartThreshold,
                        range: 0.02...0.20,
                        step: 0.005,
                        format: .number.precision(.fractionLength(3))
                    )

                    settingExplanation(
                        "Start Movement is how far your head must move away from neutral before the app starts collecting a candidate gesture. Raise it if tiny posture shifts trigger detection. Lower it if intentional gestures are missed."
                    )

                    sliderRow(
                        title: "Minimum Speed",
                        value: $store.recognitionSettings.alwaysOnGestureSpeed,
                        range: 0.20...2.00,
                        step: 0.05,
                        format: .number.precision(.fractionLength(2))
                    )

                    settingExplanation(
                        "Minimum Speed is the angular velocity required before Always On starts collecting a gesture. Raise it to ignore slow posture drift; lower it if deliberate gestures are not starting."
                    )

                    sliderRow(
                        title: "Calm Motion",
                        value: $store.recognitionSettings.motionThreshold,
                        range: 0.001...0.020,
                        step: 0.001,
                        format: .number.precision(.fractionLength(3))
                    )

                    settingExplanation(
                        "Calm Motion is how still your head must be before Finish Delay starts counting and Always On can reset. Lower values are stricter; raise it if gestures take too long to score or rearm."
                    )

                    sliderRow(
                        title: "Finish Delay",
                        value: $store.recognitionSettings.alwaysOnFinishDelay,
                        range: 0.05...0.35,
                        step: 0.01,
                        format: .number.precision(.fractionLength(2))
                    )

                    settingExplanation(
                        "Finish Delay is how long movement must stay below Calm Motion before the captured gesture is scored. Lower values fire faster once the app considers your head calm."
                    )

                    sliderRow(
                        title: "Return To Neutral",
                        value: $store.recognitionSettings.alwaysOnReturnToNeutralRadius,
                        range: 0.02...0.20,
                        step: 0.005,
                        format: .number.precision(.fractionLength(3))
                    )

                    settingExplanation(
                        "Return To Neutral is how close your head must come back to the resting position before another Always On gesture can start. Raise it if reset feels too strict; lower it if gestures repeat too easily."
                    )

                    sliderRow(
                        title: "Neutral Settle",
                        value: $store.recognitionSettings.alwaysOnNeutralSettleDuration,
                        range: 0.15...1.20,
                        step: 0.05,
                        format: .number.precision(.fractionLength(2))
                    )

                    settingExplanation(
                        "Neutral Settle is how long your head must remain still near neutral before that posture becomes the next baseline. Increase it if baseline resets too eagerly."
                    )
                }

                GlassCard(title: "Overlay") {
                    Toggle("Show Overlay When Active", isOn: $store.appearanceSettings.showOverlayWhenActive)
                        .toggleStyle(.switch)

                    settingExplanation(
                        "Show Overlay When Active displays the floating head-position overlay in the top-right corner while gesture activation is on."
                    )

                    Toggle("Show Trail", isOn: $store.appearanceSettings.showTrail)
                        .toggleStyle(.switch)

                    settingExplanation(
                        "Show Trail draws the recent movement path behind the cursor so you can see how the gesture is being tracked."
                    )

                    sliderRow(
                        title: "Overlay Opacity",
                        value: $store.appearanceSettings.overlayOpacity,
                        range: 0.2...1.0,
                        step: 0.05,
                        format: .number.precision(.fractionLength(2))
                    )

                    settingExplanation(
                        "Overlay Opacity changes how transparent the overlay looks. Lower values make it less visually dominant."
                    )

                    sliderRow(
                        title: "Overlay Scale",
                        value: $store.appearanceSettings.overlayScale,
                        range: 0.6...1.8,
                        step: 0.05,
                        format: .number.precision(.fractionLength(2))
                    )

                    settingExplanation(
                        "Overlay Scale changes the size of the floating overlay UI. It only affects the display, not recognition behavior."
                    )
                }

                GlassCard(title: "Permissions") {
                    permissionRow(
                        title: "Accessibility",
                        isGranted: permissionSnapshot.accessibilityGranted,
                        detail: "Required to control other app windows and send gesture-triggered shortcuts outside airpod_control."
                    )

                    permissionRow(
                        title: "Post Keyboard Events",
                        isGranted: permissionSnapshot.postEventsGranted,
                        detail: "Required for gesture-triggered shortcuts to affect other apps. If shortcuts stopped working after a rebuild, request this again and relaunch the app."
                    )

                    permissionRow(
                        title: "Input Monitoring",
                        isGranted: permissionSnapshot.inputMonitoringGranted,
                        detail: "This build does not rely on a global event tap to send shortcuts, so missing Input Monitoring should not block shortcut posting by itself."
                    )

                    HStack(spacing: 10) {
                        Button("Request Accessibility") {
                            _ = ActionPermissionService.ensureAccessibilityPermission(prompt: true)
                            refreshPermissionSnapshot()
                        }

                        Button("Request Shortcut Access") {
                            _ = ActionPermissionService.ensurePostEventAccess(prompt: true)
                            refreshPermissionSnapshot()
                        }

                        Button("Recheck") {
                            refreshPermissionSnapshot()
                        }
                    }
                }

                GlassCard(title: "Reset") {
                    Text("Reset detection and overlay settings back to their defaults without deleting your saved gestures.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    HStack {
                        Spacer()
                        Button("Reset To Defaults", role: .destructive) {
                            store.resetGestureSettingsToDefaults()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(20)
        }
        .onChange(of: store.recognitionSettings) { _, _ in
            store.persistRecognitionSettings()
        }
        .onChange(of: store.appearanceSettings) { _, _ in
            store.persistAppearanceSettings()
        }
        .onChange(of: store.debugMode) { _, _ in
            store.persistDebugMode()
        }
        .onChange(of: store.verboseDebugMode) { _, _ in
            store.persistVerboseDebugMode()
        }
        .task {
            guard !didLoadPermissionSnapshot else { return }
            didLoadPermissionSnapshot = true
            refreshPermissionSnapshot()
        }
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: FloatingPointFormatStyle<Double>
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: 170, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(value.wrappedValue.formatted(format))
                .font(.footnote.monospacedDigit())
                .frame(width: 56, alignment: .trailing)
        }
    }

    private func settingExplanation(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func permissionRow(title: String, isGranted: Bool, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(isGranted ? Color.green : Color.orange)
                Text(title)
                    .font(.headline)
                Spacer()
                Text(isGranted ? "Allowed" : "Missing")
                    .font(.caption.weight(.semibold))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background((isGranted ? Color.green : Color.orange).opacity(0.16), in: Capsule())
                    .foregroundStyle(isGranted ? Color.green : Color.orange)
            }

            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refreshPermissionSnapshot() {
        permissionSnapshot = ActionPermissionService.currentSnapshot()
        dbgLog("PERMISSIONS settings_refresh accessibility=\(permissionSnapshot.accessibilityGranted) post_events=\(permissionSnapshot.postEventsGranted) input_monitoring=\(permissionSnapshot.inputMonitoringGranted)")
    }
}

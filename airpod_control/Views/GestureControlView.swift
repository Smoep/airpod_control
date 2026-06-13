import AppKit
import ApplicationServices
import Observation
import SwiftUI
import UniformTypeIdentifiers

private enum ContinuousPreset: String, CaseIterable, Identifiable {
    case volume = "Volume Control"
    case brightness = "Brightness"
    case switchDesktop = "Switch Desktop"
    case customShortcut = "Custom Shortcut"

    var id: String { rawValue }

    var detailText: String {
        switch self {
        case .volume:
            return "Maps the two directions to volume up and volume down."
        case .brightness:
            return "Maps the two directions to brightness up and brightness down."
        case .switchDesktop:
            return "Maps the two directions to macOS desktop switching shortcuts."
        case .customShortcut:
            return "Lets you record a separate shortcut for each direction."
        }
    }
}

struct GestureControlView: View {
    @Bindable var store: LiveSensorStore
    @State private var isShowingEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Gestures")
                            .font(.largeTitle.weight(.semibold))
                        Text("Record head gestures, assign actions, and control tracking.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Tracking", isOn: Binding(
                        get: { store.isGestureDetectionEnabled },
                        set: { store.setTrackingEnabled($0) }
                    ))
                        .toggleStyle(.switch)
                        .help("When Tracking is off, motion input and gesture actions are paused.")
                }

                HStack(spacing: 18) {
                    statusPill(
                        label: "Tracking",
                        value: store.isGestureDetectionEnabled ? "On" : "Off",
                        accent: store.isGestureDetectionEnabled ? .green : .orange
                    )
                    statusPill(
                        label: "Activation",
                        value: store.isActivationActive ? "Active" : "Idle",
                        accent: store.isActivationActive ? .green : .secondary
                    )
                    statusPill(
                        label: "Last Match",
                        value: store.lastRecognizedGestureName,
                        accent: store.lastRecognizedGestureExecuted ? .green : .primary
                    )
                    statusPill(
                        label: "Score",
                        value: "\(store.lastRecognizedGestureScore.formatted(.number.precision(.fractionLength(2)))) / \(store.recognitionSettings.confidenceThreshold.formatted(.number.precision(.fractionLength(2))))",
                        accent: store.lastRecognizedGestureExecuted
                            ? .green
                            : (store.lastRecognizedGestureScore > 0 ? .orange : .secondary)
                    )
                    statusPill(
                        label: "Last Action",
                        value: store.lastActionStatus,
                        accent: store.lastActionStatus.lowercased().contains("fail")
                            ? .red
                            : (store.lastActionStatus.lowercased().contains("below threshold")
                                ? .orange
                                : (store.lastActionStatus == "-" ? .secondary : .green))
                    )
                    Spacer()
                    Picker("Testing Target", selection: $store.calibrationTargetGestureID) {
                        Text("Unset").tag(UUID?.none)
                        ForEach(store.gestures.filter { $0.inputType == .discrete }) { gesture in
                            Text(gesture.name).tag(Optional(gesture.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 240)
                }

                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.primary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                HStack {
                    Text("Configured Gestures")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Button {
                        store.resetToCalibrationGestureSet()
                    } label: {
                        Label("Reset Calibration Set", systemImage: "target")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        store.clearGestureDraft()
                        isShowingEditor = true
                    } label: {
                        Label("Add Gesture", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if store.gestures.isEmpty {
                    GlassCard(title: "No Gestures Yet") {
                        Text("Use Add Gesture to create one, then test it while activation is active.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(store.gestures) { gesture in
                            gestureRow(gesture)
                        }
                    }
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $isShowingEditor, onDismiss: {
            store.cancelGestureRecording()
        }) {
            GestureEditorSheet(store: store)
                .frame(minWidth: 1080, minHeight: 720)
        }
    }

    private func gestureRow(_ gesture: AirGestureDefinition) -> some View {
        HStack(spacing: 12) {
            GestureThumbnailView(sample: gesture.samples.first, inputType: gesture.inputType, axis: gesture.axis)
                .frame(width: 96, height: 96)

            VStack(alignment: .leading, spacing: 4) {
                Text(gesture.name)
                    .font(.headline)
                Text(summary(for: gesture))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { gesture.isEnabled },
                set: { store.toggleGesture(gesture.id, isEnabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)

            Button(role: .destructive) {
                store.deleteGesture(gesture.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red.opacity(0.85))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(gesture.isEnabled ? 0.05 : 0.025))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.beginEditingGesture(gesture.id)
            isShowingEditor = true
        }
        .opacity(gesture.isEnabled ? 1.0 : 0.55)
    }

    private func summary(for gesture: AirGestureDefinition) -> String {
        if gesture.inputType == .continuous {
            let reverse = gesture.reverseTrigger?.displayName ?? gesture.trigger.displayName
            return "Continuous · \(gesture.axis.rawValue) · \(gesture.trigger.displayName) / \(reverse)"
        }
        return "Discrete · \(gesture.samples.count) recording(s) · \(gesture.trigger.displayName)"
    }

    private func statusPill(label: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote.weight(.medium))
                .foregroundStyle(accent)
        }
    }
}

private struct GestureEditorSheet: View {
    @Bindable var store: LiveSensorStore
    @Environment(\.dismiss) private var dismiss
    @State private var continuousPreset: ContinuousPreset = .customShortcut
    @State private var skipNextContinuousPresetApply = false

    private var isEditing: Bool { store.editingGestureID != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "Edit Gesture" : "New Gesture")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)

            Divider()

            HStack(alignment: .top, spacing: 16) {
                GestureEditorMovementPanel(store: store)

                GlassCard(title: "Configuration") {
                    Form {
                        TextField("Gesture name", text: $store.gestureDraftName)

                        Picker("Input Type", selection: $store.gestureDraftInputType) {
                            ForEach(AirGestureInputType.allCases) { inputType in
                                Text(inputType.rawValue).tag(inputType)
                            }
                        }

                        if store.gestureDraftInputType == .continuous {
                            Picker("Movement", selection: $store.gestureDraftAxis) {
                                ForEach(AirGestureAxis.allCases) { axis in
                                    Text(axis.rawValue).tag(axis)
                                }
                            }

                            Text(store.gestureDraftAxis.detailText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            Picker("Action Style", selection: $continuousPreset) {
                                ForEach(ContinuousPreset.allCases) { preset in
                                    Text(preset.rawValue).tag(preset)
                                }
                            }

                            Text(continuousPreset.detailText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            HStack {
                                Text("Sensitivity")
                                Slider(value: $store.gestureDraftSensitivity, in: 1...10, step: 1)
                                Text("\(Int(store.gestureDraftSensitivity))")
                                    .monospacedDigit()
                                    .frame(width: 24)
                            }

                            Text("Higher sensitivity triggers repeated actions more easily. Lower sensitivity needs larger movement before another step fires.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            if continuousPreset == .customShortcut {
                                ShortcutEditorSection(
                                    title: store.gestureDraftAxis.primaryActionTitle,
                                    shortcut: Binding(
                                        get: { store.gestureDraftTrigger.shortcut },
                                        set: {
                                            store.gestureDraftTrigger.type = .keyboardShortcut
                                            store.gestureDraftTrigger.shortcut = $0
                                        }
                                    )
                                )

                                ShortcutEditorSection(
                                    title: store.gestureDraftAxis.reverseActionTitle,
                                    shortcut: Binding(
                                        get: { store.gestureDraftReverseTrigger.shortcut },
                                        set: {
                                            store.gestureDraftReverseTrigger.type = .keyboardShortcut
                                            store.gestureDraftReverseTrigger.shortcut = $0
                                        }
                                    )
                                )
                            } else {
                                LabeledContent(store.gestureDraftAxis.primaryActionTitle, value: store.gestureDraftTrigger.displayName)
                                LabeledContent(store.gestureDraftAxis.reverseActionTitle, value: store.gestureDraftReverseTrigger.displayName)
                            }
                        } else {
                            TriggerEditorView(title: "Action", trigger: $store.gestureDraftTrigger)
                        }
                    }

                    if store.gestureDraftInputType == .discrete {
                        Divider()
                            .padding(.vertical, 8)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recordings")
                                .font(.headline)

                            if store.gestureDraftSamples.isEmpty {
                                Text("No recordings yet. Add at least one sample before saving.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                ScrollView(.horizontal) {
                                    HStack(spacing: 10) {
                                        ForEach(Array(store.gestureDraftSamples.enumerated()), id: \.element.id) { index, sample in
                                            VStack(alignment: .leading, spacing: 6) {
                                                GestureThumbnailView(sample: sample, inputType: .discrete, axis: .yaw)
                                                    .frame(width: 112, height: 86)
                                                HStack(spacing: 6) {
                                                    Text("Sample \(index + 1)")
                                                        .font(.caption2.weight(.medium))
                                                    Text(sampleDuration(sample))
                                                        .font(.caption2.monospacedDigit())
                                                        .foregroundStyle(.secondary)
                                                    Spacer(minLength: 0)
                                                    Button(role: .destructive) {
                                                        store.removeDraftSample(sample.id)
                                                    } label: {
                                                        Image(systemName: "trash")
                                                    }
                                                    .buttonStyle(.borderless)
                                                    .foregroundStyle(.red.opacity(0.85))
                                                }
                                            }
                                            .padding(8)
                                            .frame(width: 130)
                                            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                                .frame(height: 138)
                            }

                            if store.isRecordingGestureArmed || store.isRecordingGestureActive {
                                HStack {
                                    Button("Stop & Add Recording") {
                                        store.stopGestureRecordingAndSave()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.red)

                                    Button("Cancel Recording") {
                                        store.cancelGestureRecording()
                                    }
                                    .buttonStyle(.bordered)
                                }
                            } else {
                                Button("Record Sample") {
                                    store.armGestureRecording()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    } else {
                        Divider()
                            .padding(.vertical, 8)
                    }

                    Divider()
                        .padding(.top, 8)
                        .padding(.bottom, 8)

                    HStack(spacing: 10) {
                        Spacer()
                        Button("Cancel") {
                            cancelAndDismiss()
                        }
                        .keyboardShortcut(.escape, modifiers: [])

                        Button(isEditing ? "Update Gesture" : "Save Gesture") {
                            persistDraftAndDismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaveDisabled)
                    }
                }
                .frame(minWidth: 520)
            }
            .padding(16)
        }
        .onAppear {
            if store.gestureDraftInputType == .continuous {
                syncContinuousPresetFromDraft()
            }
        }
        .onChange(of: store.gestureDraftInputType) { _, newValue in
            if newValue == .continuous {
                ensureContinuousShortcutDrafts()
                syncContinuousPresetFromDraft()
            }
        }
        .onChange(of: continuousPreset) { _, newValue in
            if skipNextContinuousPresetApply {
                skipNextContinuousPresetApply = false
                return
            }
            applyContinuousPreset(newValue)
        }
    }

    private var isSaveDisabled: Bool {
        store.gestureDraftInputType == .discrete && store.gestureDraftSamples.isEmpty
    }

    private func cancelAndDismiss() {
        store.cancelGestureRecording()
        store.clearGestureDraft()
        dismiss()
    }

    private func persistDraftAndDismiss() {
        if store.gestureDraftInputType == .continuous {
            store.saveContinuousGestureDraft()
        } else {
            store.saveDiscreteGestureDraft()
        }

        if store.errorMessage == nil {
            store.clearGestureDraft()
            dismiss()
        }
    }

    private func sampleDuration(_ sample: AirGestureSample) -> String {
        guard let firstPoint = sample.points.first, let lastPoint = sample.points.last else {
            return "0.00s"
        }
        return String(format: "%.2fs", max(0, lastPoint.timestamp - firstPoint.timestamp))
    }

    private func ensureContinuousShortcutDrafts() {
        if store.gestureDraftTrigger.type != .keyboardShortcut {
            store.gestureDraftTrigger = keyboardTrigger(key: "")
        }
        if store.gestureDraftReverseTrigger.type != .keyboardShortcut {
            store.gestureDraftReverseTrigger = keyboardTrigger(key: "")
        }
    }

    private func syncContinuousPresetFromDraft() {
        let nextPreset: ContinuousPreset

        if matchesPreset(.volume) {
            nextPreset = .volume
        } else if matchesPreset(.brightness) {
            nextPreset = .brightness
        } else if matchesPreset(.switchDesktop) {
            nextPreset = .switchDesktop
        } else {
            nextPreset = .customShortcut
        }

        if nextPreset != continuousPreset {
            skipNextContinuousPresetApply = true
            continuousPreset = nextPreset
        }

        if nextPreset == .customShortcut {
            ensureContinuousShortcutDrafts()
        }
    }

    private func applyContinuousPreset(_ preset: ContinuousPreset) {
        switch preset {
        case .volume:
            store.gestureDraftTrigger = mediaKeyTrigger(key: "volume_up")
            store.gestureDraftReverseTrigger = mediaKeyTrigger(key: "volume_down")
        case .brightness:
            store.gestureDraftTrigger = mediaKeyTrigger(key: "brightness_up")
            store.gestureDraftReverseTrigger = mediaKeyTrigger(key: "brightness_down")
        case .switchDesktop:
            store.gestureDraftTrigger = keyboardTrigger(key: "right", command: false, control: true)
            store.gestureDraftReverseTrigger = keyboardTrigger(key: "left", command: false, control: true)
        case .customShortcut:
            ensureContinuousShortcutDrafts()
        }
    }

    private func matchesPreset(_ preset: ContinuousPreset) -> Bool {
        switch preset {
        case .volume:
            return (
                shortcutMatches(store.gestureDraftTrigger.shortcut, mediaKeyTrigger(key: "volume_up").shortcut)
                    && shortcutMatches(store.gestureDraftReverseTrigger.shortcut, mediaKeyTrigger(key: "volume_down").shortcut)
            ) || (
                shortcutMatches(store.gestureDraftTrigger.shortcut, keyboardTrigger(key: "f12").shortcut)
                    && shortcutMatches(store.gestureDraftReverseTrigger.shortcut, keyboardTrigger(key: "f11").shortcut)
            )
        case .brightness:
            return (
                shortcutMatches(store.gestureDraftTrigger.shortcut, mediaKeyTrigger(key: "brightness_up").shortcut)
                    && shortcutMatches(store.gestureDraftReverseTrigger.shortcut, mediaKeyTrigger(key: "brightness_down").shortcut)
            ) || (
                shortcutMatches(store.gestureDraftTrigger.shortcut, keyboardTrigger(key: "f2").shortcut)
                    && shortcutMatches(store.gestureDraftReverseTrigger.shortcut, keyboardTrigger(key: "f1").shortcut)
            )
        case .switchDesktop:
            return shortcutMatches(store.gestureDraftTrigger.shortcut, keyboardTrigger(key: "right", command: false, control: true).shortcut)
                && shortcutMatches(store.gestureDraftReverseTrigger.shortcut, keyboardTrigger(key: "left", command: false, control: true).shortcut)
        case .customShortcut:
            return false
        }
    }

    private func shortcutMatches(_ lhs: GestureShortcut, _ rhs: GestureShortcut) -> Bool {
        lhs.key == rhs.key
            && lhs.command == rhs.command
            && lhs.shift == rhs.shift
            && lhs.option == rhs.option
            && lhs.control == rhs.control
    }

    private func keyboardTrigger(
        key: String,
        command: Bool = true,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false
    ) -> GestureTrigger {
        GestureTrigger(
            type: .keyboardShortcut,
            shortcut: GestureShortcut(
                key: key,
                command: command,
                shift: shift,
                option: option,
                control: control
            )
        )
    }

    private func mediaKeyTrigger(key: String) -> GestureTrigger {
        keyboardTrigger(key: key, command: false, shift: false, option: false, control: false)
    }
}

private struct TriggerEditorView: View {
    let title: String
    @Binding var trigger: GestureTrigger

    var body: some View {
        Section(title) {
            Picker("Type", selection: $trigger.type) {
                Text(GestureTriggerType.builtIn.rawValue).tag(GestureTriggerType.builtIn)
                Text(GestureTriggerType.openApp.rawValue).tag(GestureTriggerType.openApp)
                Text(GestureTriggerType.windowAction.rawValue).tag(GestureTriggerType.windowAction)
                Text(GestureTriggerType.keyboardShortcut.rawValue).tag(GestureTriggerType.keyboardShortcut)
            }

            switch trigger.type {
            case .builtIn:
                Picker("Built-In Action", selection: $trigger.builtInAction) {
                    ForEach(availableBuiltInActions) { action in
                        Text(action.rawValue).tag(action)
                    }
                }
            case .openApp:
                HStack {
                    TextField("Application", text: $trigger.appName)
                    Button("Choose...") {
                        chooseApplication()
                    }
                }
                if !trigger.appPath.isEmpty {
                    Text(trigger.appPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .windowAction:
                Picker("Window Action", selection: $trigger.windowAction) {
                    ForEach(GestureWindowAction.allCases) { action in
                        Text(action.rawValue).tag(action)
                    }
                }
            case .keyboardShortcut:
                ShortcutEditorSection(title: "Shortcut", shortcut: $trigger.shortcut)
            }
        }
    }

    private var availableBuiltInActions: [GestureTaskAction] {
        var actions = GestureTaskAction.gestureAssignableActions
        if !actions.contains(trigger.builtInAction) {
            actions.append(trigger.builtInAction)
        }
        return actions
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose Application"
        panel.prompt = "Select"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        if panel.runModal() == .OK, let url = panel.url {
            trigger.appPath = url.path
            trigger.appName = url.deletingPathExtension().lastPathComponent
        }
    }
}

private struct ShortcutEditorSection: View {
    let title: String
    @Binding var shortcut: GestureShortcut

    @State private var shortcutMonitor: Any?
    @State private var isRecordingShortcut = false

    var body: some View {
        Section(title) {
            HStack {
                TextField("Shortcut", text: $shortcut.key)
                Button(isRecordingShortcut ? "Press Key..." : "Record") {
                    startShortcutRecording()
                }
                .disabled(isRecordingShortcut)
            }
            Toggle("Command", isOn: $shortcut.command)
                .toggleStyle(.switch)
            Toggle("Shift", isOn: $shortcut.shift)
                .toggleStyle(.switch)
            Toggle("Option", isOn: $shortcut.option)
                .toggleStyle(.switch)
            Toggle("Control", isOn: $shortcut.control)
                .toggleStyle(.switch)
        }
        .onDisappear {
            stopShortcutRecording()
        }
    }

    private func startShortcutRecording() {
        stopShortcutRecording()
        isRecordingShortcut = true

        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            shortcut.key = keyName(for: event)
            shortcut.command = event.modifierFlags.contains(.command)
            shortcut.shift = event.modifierFlags.contains(.shift)
            shortcut.option = event.modifierFlags.contains(.option)
            shortcut.control = event.modifierFlags.contains(.control)
            stopShortcutRecording()
            return nil
        }
    }

    private func stopShortcutRecording() {
        if let shortcutMonitor {
            NSEvent.removeMonitor(shortcutMonitor)
            self.shortcutMonitor = nil
        }
        isRecordingShortcut = false
    }

    private func keyName(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case 36: return "return"
        case 48: return "tab"
        case 49: return "space"
        case 51: return "delete"
        case 53: return "escape"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default:
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if chars == " " { return "space" }
            return chars
        }
    }
}

private struct GestureEditorMovementPanel: View {
    let store: LiveSensorStore

    var body: some View {
        GlassCard(title: "Movement") {
            HeadMovementCanvas(
                path: store.recordingPreviewPath,
                cursor: store.liveHeadPoint,
                roll: store.liveHeadAttitudeRoll,
                pitch: store.liveHeadAttitudePitch,
                yaw: store.liveHeadAttitudeYaw,
                tx: store.liveHeadTranslationSnapshotX,
                ty: store.liveHeadTranslationSnapshotY,
                tz: store.liveHeadTranslationSnapshotZ,
                isRecording: store.isRecordingGestureActive
            )
            .frame(minHeight: 380)

            HStack {
                if store.isRecordingGestureActive {
                    Label("Recording...", systemImage: "record.circle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                } else if store.isRecordingGestureArmed {
                    Label("Armed - move now", systemImage: "record.circle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                } else {
                    Text("Live head position preview")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.gestureDraftInputType == .discrete && store.gestureRecordingPointCount > 0 {
                    Text("\(store.gestureRecordingPointCount) pts")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 500)
    }
}

private struct HeadMovementCanvas: View {
    let path: [AirGesturePoint]
    let cursor: AirGesturePoint
    let roll: Double
    let pitch: Double
    let yaw: Double
    let tx: Double
    let ty: Double
    let tz: Double
    let isRecording: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.12, green: 0.16, blue: 0.24),
                                Color(red: 0.06, green: 0.10, blue: 0.18)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)

                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 14) {
                        // Live head globe — shows yaw/pitch/roll the matcher is capturing.
                        VStack(spacing: 4) {
                            HeadGlobeView(
                                radius: 70,
                                roll: roll,
                                pitch: pitch,
                                yaw: yaw
                            )
                            .frame(width: 180, height: 180)
                            Text("Head Pose")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }

                        // Independent live time-series for each rotational axis.
                        // The matcher treats roll, yaw and pitch as INDEPENDENT
                        // signals (signed-peak comparison per axis), so showing
                        // one combined "X / Y dot" was misleading — it implied
                        // the system tracks a single 2D position when in fact it
                        // tracks three separate 1D rotations. Three stacked
                        // traces make that explicit and let the user verify each
                        // axis is being captured cleanly.
                        VStack(spacing: 6) {
                            AxisTrace(label: "Roll",  value: roll,  range: 0.7, color: .orange)
                            AxisTrace(label: "Pitch", value: pitch, range: 0.7, color: .yellow)
                            AxisTrace(label: "Yaw",   value: yaw,   range: 1.2, color: .cyan)
                        }
                        .frame(width: 200, height: 180)
                    }
                }
                .padding(14)

                if isRecording {
                    VStack {
                        HStack {
                            Spacer()
                            Label("REC", systemImage: "record.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.black.opacity(0.5), in: Capsule())
                                .padding(8)
                        }
                        Spacer()
                    }
                }
            }
        }
    }
}

/// Rolling time-series strip for a single rotational axis. Maintains its own
/// short history of the latest values so each axis (roll / pitch / yaw) is
/// rendered as an independent trace — this matches how the matcher actually
/// treats the axes (independently). The horizontal centre line is zero; the
/// trace fills in from the right and scrolls left over a fixed window.
private struct AxisTrace: View {
    let label: String
    let value: Double
    let range: Double
    let color: Color

    @State private var history: [Double] = Array(repeating: 0, count: 120)

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.35))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                GeometryReader { proxy in
                    let w = proxy.size.width
                    let h = proxy.size.height
                    let mid = h / 2
                    // Zero baseline.
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: mid))
                        p.addLine(to: CGPoint(x: w, y: mid))
                    }
                    .stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))

                    // Trace.
                    Path { p in
                        guard history.count >= 2 else { return }
                        let dx = w / Double(history.count - 1)
                        for (i, v) in history.enumerated() {
                            let clamped = max(-range, min(range, v))
                            let y = mid - (clamped / range) * (mid - 2)
                            let x = Double(i) * dx
                            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                            else      { p.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
                .padding(2)
            }
            Text(String(format: "%+.2f", value))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(color)
                .frame(width: 50, alignment: .trailing)
        }
        .onChange(of: value) { _, newValue in
            history.removeFirst()
            history.append(newValue)
        }
    }
}

/// Small horizontal bar that maps a value in [-range, +range] to a centred fill.
/// Designed for live attitude/translation feedback in the recording panel.
private struct AxisGauge: View {
    let label: String
    let value: Double
    let range: Double
    let unit: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            GeometryReader { proxy in
                let width = proxy.size.width
                let mid = width / 2
                let clamped = max(-range, min(range, value))
                let fillWidth = abs(clamped) / range * mid
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                    Rectangle()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 1)
                        .position(x: mid, y: proxy.size.height / 2)
                    Capsule()
                        .fill(color.opacity(0.8))
                        .frame(width: fillWidth, height: proxy.size.height)
                        .offset(x: clamped >= 0 ? mid : mid - fillWidth)
                }
            }
            .frame(height: 8)
            Text(formatted)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
    }

    private var formatted: String {
        if unit == "m" {
            return String(format: "%+.2f %@", value, unit)
        }
        return String(format: "%+.2f %@", value, unit)
    }
}

private struct GestureThumbnailView: View {
    let sample: AirGestureSample?
    let inputType: AirGestureInputType
    let axis: AirGestureAxis

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.07))

                if inputType == .continuous {
                    VStack(spacing: 6) {
                        Image(systemName: iconName)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(axis.rawValue)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(8)
                } else if let sample, sample.points.count > 1 {
                    let inset: CGFloat = 8
                    let pathWidth = proxy.size.width * 0.56
                    let pathRect = CGRect(
                        x: inset,
                        y: inset,
                        width: max(24, pathWidth - inset),
                        height: max(24, proxy.size.height - inset * 2)
                    )
                    let traceX = min(proxy.size.width - 26, pathRect.maxX + 8)
                    let traceWidth = max(18, proxy.size.width - traceX - inset)
                    let traceHeight = max(8, (proxy.size.height - inset * 2 - 8) / 3)
                    let traceRects = [
                        CGRect(x: traceX, y: inset, width: traceWidth, height: traceHeight),
                        CGRect(x: traceX, y: inset + traceHeight + 4, width: traceWidth, height: traceHeight),
                        CGRect(x: traceX, y: inset + (traceHeight + 4) * 2, width: traceWidth, height: traceHeight)
                    ]

                    projectedPath(points: sample.points, in: pathRect)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                    ForEach(Array(traceRects.enumerated()), id: \.offset) { index, rect in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.black.opacity(0.18))
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)

                        axisTracePath(values: axisValues(for: sample, index: index), in: rect)
                            .stroke(axisColor(index: index), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                    }
                } else {
                    Image(systemName: "scribble")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func projectedPath(points: [AirGesturePoint], in rect: CGRect) -> Path {
        Path { path in
            for (index, point) in points.enumerated() {
                let mapped = CGPoint(
                    x: rect.minX + point.x * rect.width,
                    y: rect.minY + (1 - point.y) * rect.height
                )
                if index == 0 {
                    path.move(to: mapped)
                } else {
                    path.addLine(to: mapped)
                }
            }
        }
    }

    private func axisTracePath(values: [Double], in rect: CGRect) -> Path {
        Path { path in
            guard values.count >= 2 else { return }
            let stats = traceStats(values)
            let range = max(0.04, stats.amplitude / 2)
            let center = (stats.min + stats.max) / 2
            for (index, value) in values.enumerated() {
                let progress = Double(index) / Double(values.count - 1)
                let normalized = max(-1, min(1, (value - center) / range))
                let point = CGPoint(
                    x: rect.minX + CGFloat(progress) * rect.width,
                    y: rect.midY - CGFloat(normalized) * rect.height * 0.42
                )
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
        }
    }

    private func traceStats(_ values: [Double]) -> (min: Double, max: Double, amplitude: Double) {
        guard let firstValue = values.first else { return (0, 0, 0) }
        var minimumValue = firstValue
        var maximumValue = firstValue
        for value in values {
            minimumValue = min(minimumValue, value)
            maximumValue = max(maximumValue, value)
        }
        return (minimumValue, maximumValue, maximumValue - minimumValue)
    }

    private func axisValues(for sample: AirGestureSample, index: Int) -> [Double] {
        switch index {
        case 0:
            return sample.points.map(\.yaw)
        case 1:
            return sample.points.map(\.pitch)
        default:
            return sample.points.map(\.roll)
        }
    }

    private func axisColor(index: Int) -> Color {
        switch index {
        case 0:
            return .cyan
        case 1:
            return .yellow
        default:
            return .orange
        }
    }

    private var iconName: String {
        switch axis {
        case .yaw:
            return "arrow.left.and.right.circle.fill"
        case .pitch:
            return "arrow.up.and.down.circle.fill"
        case .roll:
            return "arrow.trianglehead.2.clockwise.rotate.90.circle.fill"
        case .lateralX:
            return "arrow.left.and.right.square.fill"
        case .verticalY:
            return "arrow.up.and.down.square.fill"
        case .depthZ:
            return "arrow.forward.square.fill"
        }
    }
}

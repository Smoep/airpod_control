import Observation
import SwiftUI

struct OverviewView: View {
    @Bindable var store: LiveSensorStore
    @State private var isSampleInspectorPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Diagnostics")
                            .font(.largeTitle.weight(.semibold))
                        Text("Live AirPods motion status and troubleshooting tools.")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Picker("Sampling", selection: $store.samplingMode) {
                        ForEach(SamplingMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }

                statusRow

                GlassCard(title: "Motion Input") {
                    HStack(spacing: 12) {
                        Button(store.isGestureDetectionEnabled ? "Reconnect Motion Input" : "Turn On Tracking") {
                            if store.isGestureDetectionEnabled {
                                store.reconnectMotionInput()
                            } else {
                                store.setTrackingEnabled(true)
                            }
                        }
                            .buttonStyle(.borderedProminent)
                        Button("Copy Current Sample") { store.copyCurrentSnapshot() }
                            .buttonStyle(.bordered)
                        Button("Inspect Sample") { isSampleInspectorPresented = true }
                            .buttonStyle(.bordered)
                    }

                    Text("Motion input follows Tracking automatically. Reconnect is only for troubleshooting stale or missing AirPods motion data.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text(store.streamDiagnostics)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                GlassCard(title: "Export") {
                    HStack(spacing: 12) {
                        Text("Duration")
                            .font(.subheadline)
                        Slider(value: $store.exportDurationSeconds, in: 5...120, step: 5)
                        Text("\(Int(store.exportDurationSeconds))s")
                            .font(.subheadline.monospacedDigit())
                            .frame(width: 48)
                    }

                    HStack(spacing: 12) {
                        Button("Export CSV") { store.exportCSV() }
                            .buttonStyle(.bordered)
                        Button("Export JSON") { store.exportJSON() }
                            .buttonStyle(.bordered)
                    }
                }

                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.primary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                Text(store.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .sheet(isPresented: $isSampleInspectorPresented) {
            if let sample = store.latestSample {
                RawMotionSampleInspector(sample: sample)
            } else {
                Text("No sample available")
                    .frame(width: 360, height: 180)
            }
        }
    }

    private var statusRow: some View {
        let availability = store.availabilityState
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                StatusPill(
                    label: "Connection",
                    value: availability.connectionState.rawValue.capitalized,
                    tint: availability.connectionState == .connected ? .green : .orange
                )
                StatusPill(
                    label: "Authorization",
                    value: availability.authorizationState.rawValue.capitalized,
                    tint: availability.authorizationState == .authorized ? .green : .yellow
                )
                StatusPill(
                    label: "Sensor Reported",
                    value: availability.isHeadphoneMotionAvailable ? "Available" : "Unavailable",
                    tint: availability.isHeadphoneMotionAvailable ? .green : .red
                )
                StatusPill(
                    label: "Streaming",
                    value: store.streamState.label,
                    tint: streamTint
                )
            }
        }
    }

    private var streamTint: Color {
        switch store.streamState {
        case .active:
            return .green
        case .starting:
            return .yellow
        case .waiting:
            return .orange
        case .stopped:
            return .gray
        case .error:
            return .red
        }
    }
}

private struct RawMotionSampleInspector: View {
    let sample: SensorSampleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Current Sample")
                .font(.title2.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                row("Last update", sample.timestamp.formatted(date: .numeric, time: .standard))
                row("Roll", sample.attitude.roll)
                row("Pitch", sample.attitude.pitch)
                row("Yaw", sample.attitude.yaw)
                row("Rotation X", sample.rotationRate.x)
                row("Rotation Y", sample.rotationRate.y)
                row("Rotation Z", sample.rotationRate.z)
                row("Gravity X", sample.gravity.x)
                row("Gravity Y", sample.gravity.y)
                row("Gravity Z", sample.gravity.z)
                row("Acceleration X", sample.userAcceleration.x)
                row("Acceleration Y", sample.userAcceleration.y)
                row("Acceleration Z", sample.userAcceleration.z)
                row("Movement magnitude", sample.derived.movementMagnitude)
                row("Update frequency", sample.derived.updateFrequencyHz, suffix: "Hz")
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func row(_ label: String, _ value: Double, suffix: String = "") -> some View {
        row(label, "\(value.formatted(.number.precision(.fractionLength(4)))) \(suffix)")
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
        }
    }
}

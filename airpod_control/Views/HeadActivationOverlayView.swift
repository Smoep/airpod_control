import SwiftUI

struct HeadActivationOverlayView: View {
    let opacity: Double
    let scale: Double
    /// Head attitude relative to the activation baseline (radians). Drives the globe.
    let roll: Double
    let pitch: Double
    let yaw: Double
    let gateState: AlwaysOnGateDisplayState
    let gateDistanceProgress: Double
    let gateSpeedProgress: Double
    let gateDistance: Double
    let gateSpeed: Double

    private var size: CGFloat { 240 * scale }
    private var radius: CGFloat { size * 0.36 }
    private var showsGateStatus: Bool { gateState != .inactive }
    private var gateColor: Color {
        switch gateState {
        case .inactive: return .white
        case .waiting: return .cyan
        case .slow: return .orange
        case .capturing: return .green
        case .resetting: return .yellow
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(max(0.15, opacity * 0.45)))
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(gateColor.opacity(showsGateStatus ? 0.55 : 0.25), lineWidth: showsGateStatus ? 1.5 : 1)
                )

            HeadGlobeView(
                radius: radius,
                roll: roll,
                pitch: pitch,
                yaw: yaw
            )
            .frame(width: size, height: size)

            if showsGateStatus {
                VStack {
                    Spacer()
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(gateColor)
                                .frame(width: 7, height: 7)
                            Text(gateState.rawValue)
                                .font(.caption2.weight(.semibold))
                            Spacer()
                            Text(String(format: "%.2f rad/s", gateSpeed))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        GateProgressRow(label: "Move", progress: gateDistanceProgress, color: gateColor)
                        GateProgressRow(label: "Speed", progress: gateSpeedProgress, color: gateColor)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .foregroundStyle(.white)
                    .frame(width: max(160, size - 28))
                }
                .frame(width: size, height: size)
                .padding(.bottom, 12)
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

private struct GateProgressRow: View {
    let label: String
    let progress: Double
    let color: Color

    private var clampedProgress: Double { min(max(progress, 0), 1) }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.16))
                    Capsule()
                        .fill(color.opacity(0.85))
                        .frame(width: proxy.size.width * clampedProgress)
                }
            }
            .frame(height: 5)

            Text("\(Int((clampedProgress * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

/// 3D wireframe head globe driven by relative head attitude. The two dots represent
/// where the left and right AirPods (ears) are in space. Although CoreMotion fuses
/// both pods into a single head pose, projecting two fixed offsets through that
/// rotation gives a faithful visualisation of how the user's head is oriented.
struct HeadGlobeView: View {
    let radius: CGFloat
    let roll: Double   // radians
    let pitch: Double  // radians
    let yaw: Double    // radians

    var body: some View {
        Canvas { context, canvasSize in
            let centre = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let r = Double(radius)

            // Build a Z-Y-X (yaw, pitch, roll) rotation matrix once per draw.
            let rot = RotationMatrix(yaw: yaw, pitch: pitch, roll: roll)

            // --- Latitude / longitude wireframe ---
            let latLines = 5
            let lonLines = 6
            let segments = 36

            for i in 1..<latLines {
                let phi = (Double(i) / Double(latLines)) * .pi - .pi / 2
                var path = Path()
                for s in 0...segments {
                    let theta = (Double(s) / Double(segments)) * 2 * .pi
                    let p = SIMD3<Double>(
                        r * cos(phi) * cos(theta),
                        r * sin(phi),
                        r * cos(phi) * sin(theta)
                    )
                    let rotated = rot.apply(p)
                    let projected = project(rotated, centre: centre, focal: r * 4)
                    if s == 0 { path.move(to: projected) } else { path.addLine(to: projected) }
                }
                let alpha = 0.18 + 0.10 * (1 - abs(phi) / (.pi / 2))
                context.stroke(path, with: .color(Color.white.opacity(alpha)), lineWidth: 1)
            }

            for j in 0..<lonLines {
                let lon = (Double(j) / Double(lonLines)) * .pi
                var path = Path()
                for s in 0...segments {
                    let phi = (Double(s) / Double(segments)) * 2 * .pi - .pi
                    let p = SIMD3<Double>(
                        r * cos(phi) * cos(lon),
                        r * sin(phi),
                        r * cos(phi) * sin(lon)
                    )
                    let rotated = rot.apply(p)
                    let projected = project(rotated, centre: centre, focal: r * 4)
                    if s == 0 { path.move(to: projected) } else { path.addLine(to: projected) }
                }
                context.stroke(path, with: .color(Color.white.opacity(0.18)), lineWidth: 1)
            }

            // Equatorial circle, slightly emphasised.
            var equator = Path()
            for s in 0...segments {
                let theta = (Double(s) / Double(segments)) * 2 * .pi
                let p = SIMD3<Double>(r * cos(theta), 0, r * sin(theta))
                let rotated = rot.apply(p)
                let projected = project(rotated, centre: centre, focal: r * 4)
                if s == 0 { equator.move(to: projected) } else { equator.addLine(to: projected) }
            }
            context.stroke(equator, with: .color(Color.cyan.opacity(0.55)), lineWidth: 1.2)

            // --- Front-of-head marker (so the globe orientation is unambiguous) ---
            let nose = rot.apply(SIMD3<Double>(0, 0, r))
            let nosePoint = project(nose, centre: centre, focal: r * 4)
            let noseDepth = nose.z // +ve = toward viewer, after rotation
            let noseAlpha = 0.45 + 0.55 * normalisedDepth(noseDepth, r: r)
            let noseRect = CGRect(
                x: nosePoint.x - 4, y: nosePoint.y - 4, width: 8, height: 8
            )
            context.fill(Path(ellipseIn: noseRect), with: .color(Color.orange.opacity(noseAlpha)))

            // --- Left and right ear dots ---
            // Ear vector in head-local space: ±X axis. Right ear = +X (matches CoreMotion
            // convention where +X points out the right side of the head).
            let leftEarLocal = SIMD3<Double>(-r, 0, 0)
            let rightEarLocal = SIMD3<Double>(r, 0, 0)

            let leftEar = rot.apply(leftEarLocal)
            let rightEar = rot.apply(rightEarLocal)

            drawEar(in: context, world: leftEar, r: r, centre: centre, colour: .green, label: "L")
            drawEar(in: context, world: rightEar, r: r, centre: centre, colour: .red,  label: "R")
        }
    }

    private func drawEar(
        in context: GraphicsContext,
        world: SIMD3<Double>,
        r: Double,
        centre: CGPoint,
        colour: Color,
        label: String
    ) {
        let projected = project(world, centre: centre, focal: r * 4)
        let depth = world.z
        let depthN = normalisedDepth(depth, r: r)            // 0 (back) … 1 (front)
        let radius = 5.0 + 5.0 * depthN                       // bigger when in front
        let alpha = 0.35 + 0.65 * depthN
        let rect = CGRect(
            x: projected.x - radius / 2,
            y: projected.y - radius / 2,
            width: radius,
            height: radius
        )
        context.fill(Path(ellipseIn: rect), with: .color(colour.opacity(alpha)))
        context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(alpha)), lineWidth: 1)

        // Label only when the ear is on the visible (front) hemisphere.
        if depth > -r * 0.2 {
            let text = Text(label).font(.caption2.weight(.semibold)).foregroundColor(.white.opacity(alpha))
            context.draw(text, at: CGPoint(x: projected.x, y: projected.y - 12))
        }
    }

    private func normalisedDepth(_ z: Double, r: Double) -> Double {
        // Map -r…+r → 0…1 so we can use it for size/alpha falloff.
        max(0, min(1, (z + r) / (2 * r)))
    }

    private func project(_ p: SIMD3<Double>, centre: CGPoint, focal: Double) -> CGPoint {
        // Simple perspective: push points back along Z, divide by focal+z. Y is flipped
        // because screen-space Y grows downward.
        let zEye = focal - p.z   // viewer is at +focal looking toward origin
        let scale = focal / max(zEye, focal * 0.25)
        return CGPoint(
            x: centre.x + CGFloat(p.x * scale),
            y: centre.y - CGFloat(p.y * scale)
        )
    }
}

/// Z (yaw) · Y (pitch) · X (roll) intrinsic rotation. Sign conventions match how
/// CoreMotion delivers attitude: yaw rotates about Y (vertical), pitch about X
/// (lateral), roll about Z (forward). For our local-space head model we treat:
///   • +X right ear, +Y up, +Z forward (toward face).
private struct RotationMatrix {
    let m00: Double, m01: Double, m02: Double
    let m10: Double, m11: Double, m12: Double
    let m20: Double, m21: Double, m22: Double

    init(yaw: Double, pitch: Double, roll: Double) {
        let cy = cos(yaw),   sy = sin(yaw)
        let cp = cos(pitch), sp = sin(pitch)
        let cr = cos(roll),  sr = sin(roll)

        // R = Ry(yaw) · Rx(pitch) · Rz(roll)
        m00 = cy * cr + sy * sp * sr
        m01 = -cy * sr + sy * sp * cr
        m02 = sy * cp
        m10 = cp * sr
        m11 = cp * cr
        m12 = -sp
        m20 = -sy * cr + cy * sp * sr
        m21 = sy * sr + cy * sp * cr
        m22 = cy * cp
    }

    func apply(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3<Double>(
            m00 * v.x + m01 * v.y + m02 * v.z,
            m10 * v.x + m11 * v.y + m12 * v.z,
            m20 * v.x + m21 * v.y + m22 * v.z
        )
    }
}

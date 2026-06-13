import Foundation

/// Per-axis discrete-gesture matcher. Natural gestures are allowed to move on
/// multiple axes at once; the matcher compares the full yaw/pitch/roll signature
/// when recorded samples contain those raw channels, and falls back to the older
/// projected x/y/roll signature for legacy samples.
///
/// For each axis we compute three sub-scores:
///
///   1. Per-segment direction agreement (with a deadband proportional to the
///      axis's own amplitude). This catches "down then up" vs "up the whole
///      way" — they have completely different per-segment sign sequences on
///      that axis even when the endpoints look similar.
///
///   2. End-delta sign agreement. Where did this axis end up relative to its
///      start? "Down then back to centre" ends near zero; "down only" ends
///      negative — same direction sequence in the first half but different
///      net displacement.
///
///   3. Amplitude ratio (floored at 0.5 so a 2× amplitude difference costs
///      ~25%, not 100%).
///
/// Per-axis sub-scores are combined as `direction × endAgree × ampRatio`.
/// Axes where BOTH paths are essentially flat (below noise floor) contribute
/// neutral 1.0 and zero weight — so a pure-roll gesture is judged on roll
/// alone. Axes where ONE path is flat and the other is active contribute 0.0
/// (a real mismatch — that axis carries info on one side but not the other).
///
/// The per-axis scores are weighted-averaged using each axis's amplitude on
/// either side. A separate phase-order score penalizes extra reversals such as
/// "right down, then left while still down" so the recognizer accepts natural
/// coupled motion but rejects added movement outside the learned shape.
enum AirGestureMatcher {
    struct MatchResult {
        let gesture: AirGestureDefinition
        let score: Double
    }

    struct ScoreBreakdown {
        let gestureName: String
        let sampleNumber: Int
        let axisScore: Double
        let phaseScore: Double
        let terminalScore: Double
        let productScore: Double
        let dominantScore: Double
        let compositeScore: Double
        let reversalScore: Double
        let finalScore: Double
        let chosenScore: String
        let axes: String
        let performedPhases: String
        let samplePhases: String
        let axisDetails: String
    }

    struct RankedEvaluation {
        let matches: [MatchResult]
        let breakdowns: [ScoreBreakdown]
    }

    private static let resampleCount = 64

    static func match(
        performedPath: [AirGesturePoint],
        gestures: [AirGestureDefinition],
        confidence: Double,
        minimumPathLength: Double
    ) -> [MatchResult] {
        rankedMatches(
            performedPath: performedPath,
            gestures: gestures,
            minimumPathLength: minimumPathLength
        )
        .filter { $0.score >= confidence }
    }

    static func rankedMatches(
        performedPath: [AirGesturePoint],
        gestures: [AirGestureDefinition],
        minimumPathLength _: Double
    ) -> [MatchResult] {
        rankedEvaluation(
            performedPath: performedPath,
            gestures: gestures,
            minimumPathLength: 0
        ).matches
    }

    static func rankedEvaluation(
        performedPath: [AirGesturePoint],
        gestures: [AirGestureDefinition],
        minimumPathLength _: Double
    ) -> RankedEvaluation {
        guard performedPath.count >= 8 else {
            return RankedEvaluation(matches: [], breakdowns: [])
        }

        let perf = resampleByTime(performedPath, to: resampleCount)
        var results: [MatchResult] = []
        var breakdowns: [ScoreBreakdown] = []

        for gesture in gestures where gesture.isEnabled && gesture.inputType == .discrete {
            var bestScore = 0.0

            for (sampleIndex, sample) in gesture.samples.enumerated() where sample.points.count >= 4 {
                let s = resampleByTime(sample.points, to: resampleCount)

                let axes = usesRawRotation(sample.points) ? Axis.rawRotationalAxes : Axis.legacyProjectedAxes
                let requiredAxis = matcherAxis(for: gesture.axis, axes: axes)
                let shapeAxes = phaseShapeAxes(from: axes, requiredAxis: requiredAxis, sample: s)
                let axisScore = combinedAxisSimilarity(perf, s, axes: axes, requiredAxis: requiredAxis)
                let phaseScore = phaseSimilarity(performed: perf, sample: s, axes: shapeAxes)
                let terminalScore = terminalRetentionSimilarity(performed: perf, sample: s, axes: shapeAxes)
                let productScore = axisScore * phaseScore * terminalScore
                let dominantScore = singleDominantPhaseSimilarity(
                    performed: perf,
                    sample: s,
                    axes: axes,
                    requiredAxis: requiredAxis
                )
                let compositeScore = orderedCompositePhaseSimilarity(
                    performed: perf,
                    sample: s,
                    axes: axes,
                    requiredAxis: requiredAxis
                )
                let reversalScore = singleAxisReversalSimilarity(
                    performed: perf,
                    sample: s,
                    axes: axes,
                    requiredAxis: requiredAxis
                )
                let scoreComponents = [
                    (name: "product", score: productScore),
                    (name: "dominant", score: dominantScore),
                    (name: "composite", score: compositeScore),
                    (name: "reversal", score: reversalScore)
                ]
                let chosen = scoreComponents.max { lhs, rhs in lhs.score < rhs.score } ?? (name: "product", score: productScore)
                let combined = chosen.score

                breakdowns.append(ScoreBreakdown(
                    gestureName: gesture.name,
                    sampleNumber: sampleIndex + 1,
                    axisScore: axisScore,
                    phaseScore: phaseScore,
                    terminalScore: terminalScore,
                    productScore: productScore,
                    dominantScore: dominantScore,
                    compositeScore: compositeScore,
                    reversalScore: reversalScore,
                    finalScore: combined,
                    chosenScore: chosen.name,
                    axes: axes.map(\.name).joined(separator: ","),
                    performedPhases: phaseSequenceDescription(perf, axes: axes),
                    samplePhases: phaseSequenceDescription(s, axes: axes),
                    axisDetails: axisBreakdownSummary(performed: perf, sample: s, axes: axes)
                ))

                bestScore = max(bestScore, combined)
            }

            if bestScore > 0 {
                results.append(MatchResult(gesture: gesture, score: bestScore))
            }
        }

        return RankedEvaluation(
            matches: results.sorted { $0.score > $1.score },
            breakdowns: breakdowns.sorted { $0.finalScore > $1.finalScore }
        )
    }

    // MARK: - Per-axis 1-D similarity

    private static func combinedAxisSimilarity(
        _ performed: [AirGesturePoint],
        _ sample: [AirGesturePoint],
        axes: [Axis],
        requiredAxis: Axis?
    ) -> Double {
        var weightedScore = 0.0
        var totalWeight = 0.0

        for axis in axes {
            let performedAxis = relativeAxis(performed, axis)
            let sampleAxis = relativeAxis(sample, axis)
            let score = axisSimilarity(performedAxis, sampleAxis)
            let weight = max(amplitude(performedAxis), amplitude(sampleAxis)) * axisWeightBoost(axis, requiredAxis: requiredAxis)
            weightedScore += score * weight
            totalWeight += weight
        }

        guard totalWeight > 1e-6 else { return 0 }
        return weightedScore / totalWeight
    }

    private static func axisSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        let count = min(a.count, b.count)
        guard count >= 2 else { return 0 }

        let ampA = amplitude(a)
        let ampB = amplitude(b)

        // Flat threshold: minimum amplitude before we consider an axis "active".
        // 0.03 in cursor units ≈ 3% of a full-screen sweep; in radians ≈ 1.7°.
        // Below this, the axis is dominated by sensor noise.
        let flatThreshold = 0.03
        let aFlat = ampA < flatThreshold
        let bFlat = ampB < flatThreshold

        // Both flat → axis carries no info, return neutral 1.0. Combined with
        // amplitude-based weighting, this means the axis effectively drops out
        // of the score for both sides.
        if aFlat && bFlat { return 1.0 }
        // One flat, one active → real mismatch. The recorded gesture uses this
        // axis but the live one doesn't (or vice versa).
        if aFlat || bFlat { return 0.0 }

        // 1. Per-segment direction agreement, deadband ∝ each path's amplitude.
        let deadbandA = ampA * 0.05
        let deadbandB = ampB * 0.05
        var matchSum = 0.0
        var matchCount = 0
        for i in 1..<count {
            let dA = a[i] - a[i - 1]
            let dB = b[i] - b[i - 1]
            let sA: Int = dA > deadbandA ? 1 : (dA < -deadbandA ? -1 : 0)
            let sB: Int = dB > deadbandB ? 1 : (dB < -deadbandB ? -1 : 0)
            if sA == 0 && sB == 0 {
                matchSum += 1                  // both idle on this axis right now
            } else if sA == 0 || sB == 0 {
                matchSum += 0.5                // one moving, one not — half credit
            } else {
                matchSum += sA == sB ? 1 : 0   // same direction = full, opposite = 0
            }
            matchCount += 1
        }
        let direction = matchCount > 0 ? matchSum / Double(matchCount) : 0

        // 2. End-delta sign agreement. Did this axis end on the same side of
        // its starting value? "down then back to centre" ends ~0; "down only"
        // ends negative. Both are non-flat (passed gate) but their endpoints
        // differ. Allow a deadband around zero so a near-zero endpoint
        // doesn't flip the sign on a noisy frame.
        let endA = a.last ?? 0
        let endB = b.last ?? 0
        let endDeadbandA = ampA * 0.20
        let endDeadbandB = ampB * 0.20
        let signA: Int = endA > endDeadbandA ? 1 : (endA < -endDeadbandA ? -1 : 0)
        let signB: Int = endB > endDeadbandB ? 1 : (endB < -endDeadbandB ? -1 : 0)
        let aReverses = axisHasReversal(a)
        let bReverses = axisHasReversal(b)
        let endAgree: Double
        if aReverses && bReverses {
            if signA == 0 || signB == 0 {
                endAgree = 0.95
            } else {
                endAgree = signA == signB ? 1.0 : 0.65
            }
        } else if signA == 0 && signB == 0 {
            endAgree = 1.0
        } else if signA == 0 || signB == 0 {
            endAgree = 0.35
        } else {
            endAgree = signA == signB ? 1.0 : 0.1
        }

        // 3. Amplitude ratio, floored at 0.5 (so 2× amp diff costs ~25%).
        let ampRatio = min(ampA, ampB) / max(ampA, ampB)
        let ampScore = 0.5 + 0.5 * ampRatio

        return direction * endAgree * ampScore
    }

    // MARK: - Sequence helpers

    private enum Axis: Equatable {
        case x, y, yaw, pitch, roll

        static let rawRotationalAxes: [Axis] = [.yaw, .pitch, .roll]
        static let legacyProjectedAxes: [Axis] = [.x, .y, .roll]

        var name: String {
            switch self {
            case .x: return "x"
            case .y: return "y"
            case .yaw: return "yaw"
            case .pitch: return "pitch"
            case .roll: return "roll"
            }
        }
    }

    private static func axisWeightBoost(_ axis: Axis, requiredAxis: Axis?) -> Double {
        if axis == .roll {
            return requiredAxis == .roll ? 1.5 : 0.55
        }
        return axis == requiredAxis ? 1.10 : 1.0
    }

    private static func phaseShapeAxes(from axes: [Axis], requiredAxis: Axis?, sample: [AirGesturePoint]) -> [Axis] {
        guard requiredAxis != .roll else { return axes }
        let compositePhases = compositeEndpointPhases(sample, axes: axes, requiredAxis: requiredAxis)
        guard compositePhases.count >= 2 else { return axes }
        return axes.filter { $0 != .roll }
    }

    private struct Phase: Equatable {
        let axis: Axis
        let sign: Int
    }

    private static func phaseSequenceDescription(_ points: [AirGesturePoint], axes: [Axis]) -> String {
        let phases = phaseSequence(points, axes: axes)
        guard !phases.isEmpty else { return "none" }
        return phases.map { "\($0.axis.name)\($0.sign > 0 ? "+" : "-")" }.joined(separator: ">")
    }

    private static func axisBreakdownSummary(performed: [AirGesturePoint], sample: [AirGesturePoint], axes: [Axis]) -> String {
        axes.map { axis in
            let performedAxis = relativeAxis(performed, axis)
            let sampleAxis = relativeAxis(sample, axis)
            let score = axisSimilarity(performedAxis, sampleAxis)
            return String(
                format: "%@{score=%.2f pAmp=%.4f sAmp=%.4f pEnd=%.4f sEnd=%.4f}",
                axis.name,
                score,
                amplitude(performedAxis),
                amplitude(sampleAxis),
                performedAxis.last ?? 0,
                sampleAxis.last ?? 0
            )
        }.joined(separator: ";")
    }

    private static func usesRawRotation(_ points: [AirGesturePoint]) -> Bool {
        amplitude(points.map(\.yaw)) >= 0.02 || amplitude(points.map(\.pitch)) >= 0.02
    }

    /// Extract one axis as a sequence of values relative to the first point.
    /// Subtracting the first value makes the comparison translation-invariant
    /// (the user's neutral head pose at the start of a gesture doesn't matter).
    private static func relativeAxis(_ pts: [AirGesturePoint], _ axis: Axis) -> [Double] {
        guard let first = pts.first else { return [] }
        switch axis {
        case .x:     return pts.map { $0.x - first.x }
        case .y:     return pts.map { $0.y - first.y }
        case .yaw:   return pts.map { $0.yaw - first.yaw }
        case .pitch: return pts.map { $0.pitch - first.pitch }
        case .roll:  return pts.map { $0.roll - first.roll }
        }
    }

    private static func phaseSimilarity(
        performed: [AirGesturePoint],
        sample: [AirGesturePoint],
        axes: [Axis]
    ) -> Double {
        let performedPhases = phaseSequence(performed, axes: axes)
        let samplePhases = phaseSequence(sample, axes: axes)

        guard !samplePhases.isEmpty else {
            return performedPhases.isEmpty ? 1.0 : 0.45
        }
        guard !performedPhases.isEmpty else { return 0.0 }

        let common = longestCommonSubsequenceCount(performedPhases, samplePhases)
        let sampleCoverage = Double(common) / Double(samplePhases.count)
        let extraCount = max(0, performedPhases.count - common)
        let extraPenalty = pow(0.90, Double(extraCount))

        if sampleCoverage >= 0.85 {
            return max(0.75, extraPenalty)
        }

        return max(0.05, sampleCoverage * extraPenalty)
    }

    private static func terminalRetentionSimilarity(
        performed: [AirGesturePoint],
        sample: [AirGesturePoint],
        axes: [Axis]
    ) -> Double {
        var penalty = 1.0

        for axis in axes {
            let performedAxis = relativeAxis(performed, axis)
            let sampleAxis = relativeAxis(sample, axis)
            guard let sampleEnd = sampleAxis.last, let performedEnd = performedAxis.last else { continue }

            let sampleAmplitude = amplitude(sampleAxis)
            let performedAmplitude = amplitude(performedAxis)
            guard sampleAmplitude >= 0.06 else { continue }
            guard abs(sampleEnd) >= sampleAmplitude * 0.45 else { continue }

            if performedAmplitude < 0.03 {
                penalty = min(penalty, 0.35)
                continue
            }

            let sampleSign = sampleEnd > 0 ? 1 : -1
            let performedSign = performedEnd > 0 ? 1 : -1
            guard sampleSign == performedSign else {
                penalty = min(penalty, 0.20)
                continue
            }

            let retained = abs(performedEnd) / max(performedAmplitude, 1e-9)
            if retained < 0.25 {
                penalty = min(penalty, 0.25)
            } else if retained < 0.45 {
                penalty = min(penalty, 0.55)
            } else if retained < 0.60 {
                penalty = min(penalty, 0.80)
            }
        }

        return penalty
    }

    private static func singleDominantPhaseSimilarity(
        performed: [AirGesturePoint],
        sample: [AirGesturePoint],
        axes: [Axis],
        requiredAxis: Axis?
    ) -> Double {
        guard let samplePhase = singleDominantEndpointPhase(sample, axes: axes, secondaryLimit: 0.28),
              let performedPhase = singleDominantEndpointPhase(performed, axes: axes, secondaryLimit: 0.55),
              samplePhase == performedPhase else {
            return 0
        }
        if let requiredAxis, samplePhase.axis != requiredAxis {
            return 0
        }

        let performedAxis = relativeAxis(performed, samplePhase.axis)
        let sampleAxis = relativeAxis(sample, samplePhase.axis)
        let endpointScore = dominantAxisEndpointSimilarity(performedAxis, sampleAxis, expectedSign: samplePhase.sign)
        let terminalScore = terminalRetentionSimilarity(performed: performed, sample: sample, axes: [samplePhase.axis])
        let secondaryScore = dominantSecondaryAxisCompatibility(
            performed: performed,
            sample: sample,
            axes: axes,
            dominantAxis: samplePhase.axis
        )
        return endpointScore * terminalScore * secondaryScore
    }

    private static func orderedCompositePhaseSimilarity(
        performed: [AirGesturePoint],
        sample: [AirGesturePoint],
        axes: [Axis],
        requiredAxis: Axis?
    ) -> Double {
        let samplePhases = compositeEndpointPhases(sample, axes: axes, requiredAxis: requiredAxis)
        guard samplePhases.count >= 2 else { return 0 }
        guard !hasReversal(sample, among: samplePhases.map(\.phase.axis)) else { return 0 }

        let performedPhases = samplePhases.compactMap { timedPhase in
            timedEndpointPhase(performed, axis: timedPhase.phase.axis, expectedSign: timedPhase.phase.sign)
        }
        guard performedPhases.count == samplePhases.count else { return 0 }

        let sampleOrder = samplePhases.sorted { $0.index < $1.index }.map(\.phase)
        let performedOrder = performedPhases.sorted { $0.index < $1.index }.map(\.phase)
        let orderScore: Double
        if sampleOrder == performedOrder {
            orderScore = 1.0
        } else {
            let common = longestCommonSubsequenceCount(performedOrder, sampleOrder)
            orderScore = max(0.20, Double(common) / Double(sampleOrder.count) * 0.55)
        }

        let axisScores = zip(samplePhases, performedPhases).map { samplePhase, _ in
            endpointAxisIntentSimilarity(
                relativeAxis(performed, samplePhase.phase.axis),
                relativeAxis(sample, samplePhase.phase.axis),
                expectedSign: samplePhase.phase.sign
            )
        }
        let axisScore = axisScores.reduce(0, +) / Double(axisScores.count)
        return axisScore * orderScore
    }

    private static func singleAxisReversalSimilarity(
        performed: [AirGesturePoint],
        sample: [AirGesturePoint],
        axes: [Axis],
        requiredAxis: Axis?
    ) -> Double {
        guard let requiredAxis else { return 0 }

        let performedAxis = relativeAxis(performed, requiredAxis)
        let sampleAxis = relativeAxis(sample, requiredAxis)
        let performedAmplitude = amplitude(performedAxis)
        let sampleAmplitude = amplitude(sampleAxis)
        guard performedAmplitude >= 0.08, sampleAmplitude >= 0.08 else { return 0 }
        guard axisHasReversal(performedAxis), axisHasReversal(sampleAxis) else { return 0 }
        let performedEndsNearCenter = isNearCenterReversalEndpoint(performedAxis)
            || absolutePathEndsNearCenter(performed, axis: requiredAxis, relativeAmplitude: performedAmplitude)
        let sampleEndsNearCenter = isNearCenterReversalEndpoint(sampleAxis)
            || absolutePathEndsNearCenter(sample, axis: requiredAxis, relativeAmplitude: sampleAmplitude)
        guard performedEndsNearCenter, sampleEndsNearCenter else { return 0 }
        guard sampleLooksLikeSingleAxisReversal(sample: sample, axes: axes, requiredAxis: requiredAxis) else { return 0 }

        let phaseScore = reversalPhaseSimilarity(performed: performed, sample: sample, axis: requiredAxis)
        guard phaseScore > 0 else { return 0 }

        let axisScore = axisSimilarity(performedAxis, sampleAxis)
        let terminalScore = terminalRetentionSimilarity(performed: performed, sample: sample, axes: [requiredAxis])
        let secondaryScore = singleAxisReversalSecondaryCompatibility(
            performed: performed,
            sample: sample,
            axes: axes,
            requiredAxis: requiredAxis
        )
        return axisScore * phaseScore * terminalScore * secondaryScore
    }

    private static func sampleLooksLikeSingleAxisReversal(
        sample: [AirGesturePoint],
        axes: [Axis],
        requiredAxis: Axis
    ) -> Bool {
        let requiredAmplitude = amplitude(relativeAxis(sample, requiredAxis))
        guard requiredAmplitude >= 0.08 else { return false }

        for axis in axes where axis != requiredAxis && axis != .roll {
            let secondaryAmplitude = amplitude(relativeAxis(sample, axis))
            if secondaryAmplitude >= max(0.10, requiredAmplitude * 0.35) {
                return false
            }
        }
        return true
    }

    private static func singleAxisReversalSecondaryCompatibility(
        performed: [AirGesturePoint],
        sample: [AirGesturePoint],
        axes: [Axis],
        requiredAxis: Axis
    ) -> Double {
        let performedRequiredAmplitude = amplitude(relativeAxis(performed, requiredAxis))
        let sampleRequiredAmplitude = amplitude(relativeAxis(sample, requiredAxis))
        guard performedRequiredAmplitude >= 0.08, sampleRequiredAmplitude >= 0.08 else { return 0 }

        var compatibility = 1.0
        for axis in axes where axis != requiredAxis {
            let performedAmplitude = amplitude(relativeAxis(performed, axis))
            let sampleAmplitude = amplitude(relativeAxis(sample, axis))

            if axis == .roll {
                if performedAmplitude >= performedRequiredAmplitude * 0.85
                    && sampleAmplitude < sampleRequiredAmplitude * 0.35 {
                    compatibility = min(compatibility, 0.55)
                }
                continue
            }

            if performedAmplitude >= max(0.10, performedRequiredAmplitude * 0.35) {
                compatibility = min(compatibility, 0.45)
            }
        }
        return compatibility
    }

    private static func reversalPhaseSimilarity(
        performed: [AirGesturePoint],
        sample: [AirGesturePoint],
        axis: Axis
    ) -> Double {
        let performedPhases = phaseSequence(performed, axes: [axis])
        let samplePhases = phaseSequence(sample, axes: [axis])
        guard samplePhases.count == 2,
              samplePhases[0].axis == axis,
              samplePhases[1].axis == axis,
              samplePhases[0].sign == -samplePhases[1].sign else {
            return 0
        }
        guard longestCommonSubsequenceCount(performedPhases, samplePhases) == samplePhases.count else {
            return 0
        }

        let extraCount = max(0, performedPhases.count - samplePhases.count)
        return pow(0.82, Double(extraCount))
    }

    private static func isNearCenterReversalEndpoint(_ values: [Double]) -> Bool {
        let axisAmplitude = amplitude(values)
        guard axisAmplitude >= 0.06 else { return false }
        return abs(values.last ?? 0) <= max(0.06, axisAmplitude * 0.18)
    }

    private static func absolutePathEndsNearCenter(_ points: [AirGesturePoint], axis: Axis, relativeAmplitude: Double) -> Bool {
        guard relativeAmplitude >= 0.06 else { return false }
        let values = absoluteAxis(points, axis)
        guard let end = values.last else { return false }
        return abs(end) <= max(0.06, relativeAmplitude * 0.18)
    }

    private static func absoluteAxis(_ pts: [AirGesturePoint], _ axis: Axis) -> [Double] {
        switch axis {
        case .x:     return pts.map { $0.x - 0.5 }
        case .y:     return pts.map { $0.y - 0.5 }
        case .yaw:   return pts.map(\.yaw)
        case .pitch: return pts.map(\.pitch)
        case .roll:  return pts.map(\.roll)
        }
    }

    private static func compositeEndpointPhases(
        _ points: [AirGesturePoint],
        axes: [Axis],
        requiredAxis: Axis?
    ) -> [(phase: Phase, index: Int)] {
        let candidateAxes = compositeCandidateAxes(from: axes, requiredAxis: requiredAxis)
        guard !candidateAxes.isEmpty else { return [] }

        let measurements = candidateAxes.map { axis -> (axis: Axis, values: [Double], amplitude: Double, end: Double) in
            let values = relativeAxis(points, axis)
            return (axis, values, amplitude(values), values.last ?? 0)
        }
        guard let strongestAmplitude = measurements.map(\.amplitude).max(), strongestAmplitude >= 0.08 else {
            return []
        }

        let phases = measurements.compactMap { measurement -> (phase: Phase, index: Int)? in
            let isRequiredAxis = measurement.axis == requiredAxis
            let endpointStrength = abs(measurement.end)
            let enoughAmplitude = measurement.amplitude >= max(0.08, strongestAmplitude * (isRequiredAxis ? 0.25 : 0.38))
            let enoughEndpoint = endpointStrength >= max(0.055, measurement.amplitude * (isRequiredAxis ? 0.20 : 0.30))
            guard enoughAmplitude, enoughEndpoint else { return nil }

            let expectedSign = measurement.end > 0 ? 1 : -1
            return timedEndpointPhase(points, axis: measurement.axis, expectedSign: expectedSign)
        }

        if let requiredAxis, !phases.contains(where: { $0.phase.axis == requiredAxis }) {
            return []
        }
        return phases.sorted { $0.index < $1.index }
    }

    private static func compositeCandidateAxes(from axes: [Axis], requiredAxis: Axis?) -> [Axis] {
        if requiredAxis == .roll {
            return []
        }

        let preferredAxes: [Axis]
        if axes.contains(.yaw) || axes.contains(.pitch) {
            preferredAxes = [.yaw, .pitch]
        } else {
            preferredAxes = [.x, .y]
        }
        return preferredAxes.filter { axes.contains($0) }
    }

    private static func timedEndpointPhase(
        _ points: [AirGesturePoint],
        axis: Axis,
        expectedSign: Int
    ) -> (phase: Phase, index: Int)? {
        let values = relativeAxis(points, axis)
        guard values.count >= 2, let end = values.last else { return nil }

        let axisAmplitude = amplitude(values)
        let signedEnd = end * Double(expectedSign)
        guard axisAmplitude >= 0.03, signedEnd >= max(0.045, axisAmplitude * 0.20) else { return nil }

        let crossing = max(0.035, signedEnd * 0.45)
        for index in values.indices where values[index] * Double(expectedSign) >= crossing {
            return (Phase(axis: axis, sign: expectedSign), index)
        }
        return (Phase(axis: axis, sign: expectedSign), values.count - 1)
    }

    private static func endpointAxisIntentSimilarity(_ performed: [Double], _ sample: [Double], expectedSign: Int) -> Double {
        guard let performedEnd = performed.last, let sampleEnd = sample.last else { return 0 }

        let performedAmplitude = amplitude(performed)
        let sampleAmplitude = amplitude(sample)
        let performedSignedEnd = performedEnd * Double(expectedSign)
        let sampleSignedEnd = sampleEnd * Double(expectedSign)
        guard performedSignedEnd >= max(0.045, performedAmplitude * 0.20),
              sampleSignedEnd >= max(0.045, sampleAmplitude * 0.20) else {
            return 0
        }

        let endpointRatio = min(abs(performedEnd), abs(sampleEnd)) / max(abs(performedEnd), abs(sampleEnd), 1e-9)
        let amplitudeRatio = min(performedAmplitude, sampleAmplitude) / max(performedAmplitude, sampleAmplitude, 1e-9)
        let endpointScore = 0.55 + 0.45 * endpointRatio
        let amplitudeScore = 0.65 + 0.35 * amplitudeRatio
        let consistency = min(
            directionalConsistency(performed, expectedSign: expectedSign),
            directionalConsistency(sample, expectedSign: expectedSign)
        )
        return endpointScore * amplitudeScore * (0.75 + 0.25 * consistency)
    }

    private static func dominantSecondaryAxisCompatibility(
        performed: [AirGesturePoint],
        sample: [AirGesturePoint],
        axes: [Axis],
        dominantAxis: Axis
    ) -> Double {
        let dominantValues = relativeAxis(performed, dominantAxis)
        let dominantAmplitude = amplitude(dominantValues)
        let dominantEndpoint = abs(dominantValues.last ?? 0)
        guard dominantAmplitude >= 0.03, dominantEndpoint >= 0.03 else { return 1.0 }
        let sampleDominantValues = relativeAxis(sample, dominantAxis)
        let sampleDominantAmplitude = amplitude(sampleDominantValues)
        let sampleDominantEndpoint = abs(sampleDominantValues.last ?? 0)

        var compatibility = 1.0
        for axis in axes where axis != dominantAxis {
            let performedValues = relativeAxis(performed, axis)
            let sampleValues = relativeAxis(sample, axis)
            let performedAmplitude = amplitude(performedValues)
            let performedEndpoint = performedValues.last ?? 0
            let endpointRatio = abs(performedEndpoint) / max(dominantEndpoint, 1e-9)
            let amplitudeRatio = performedAmplitude / max(dominantAmplitude, 1e-9)

            let terminalSecondary = abs(performedEndpoint) >= max(0.075, performedAmplitude * 0.35)
                && endpointRatio >= 0.30
            let sweepingSecondary = performedAmplitude >= 0.16
                && amplitudeRatio >= 0.55
            let performedReversal = axis != .roll
                && axisHasReversal(performedValues)
                && performedAmplitude >= max(0.12, dominantAmplitude * 0.35)

            let sampleAmplitude = amplitude(sampleValues)
            let sampleEndpoint = sampleValues.last ?? 0
            let sampleReversal = axisHasReversal(sampleValues)
            let oppositeSignedSecondary = sampleEndpoint * performedEndpoint < 0
                && abs(performedEndpoint) >= 0.03
                && performedAmplitude >= 0.03
            guard terminalSecondary || sweepingSecondary || oppositeSignedSecondary || performedReversal else { continue }

            if performedReversal && !sampleReversal {
                compatibility = min(compatibility, 0.20)
                continue
            }

            let sampleEndpointRatio = abs(sampleEndpoint) / max(sampleDominantEndpoint, 1e-9)
            let sampleAmplitudeRatio = sampleAmplitude / max(sampleDominantAmplitude, 1e-9)
            let sameSignedRollCoupling = axis == .roll
                && sampleEndpoint * performedEndpoint > 0
                && abs(sampleEndpoint) >= 0.04
            let sampleSupportsAxis = abs(sampleEndpoint) >= max(0.04, sampleAmplitude * 0.25)
                && sampleEndpoint * performedEndpoint > 0
                && (sameSignedRollCoupling || sampleEndpointRatio >= endpointRatio * 0.75 || sampleAmplitudeRatio >= amplitudeRatio * 0.75)
            guard !sampleSupportsAxis else { continue }

            if oppositeSignedSecondary || endpointRatio >= 0.45 || amplitudeRatio >= 0.65 {
                compatibility = min(compatibility, 0.35)
            } else {
                compatibility = min(compatibility, 0.55)
            }
        }

        return compatibility
    }

    private static func axisHasReversal(_ values: [Double]) -> Bool {
        guard values.count >= 3 else { return false }

        let axisAmplitude = amplitude(values)
        guard axisAmplitude >= 0.06 else { return false }

        let deadband = axisAmplitude * 0.015
        var positiveMovement = 0.0
        var negativeMovement = 0.0
        for index in 1..<values.count {
            let delta = values[index] - values[index - 1]
            guard abs(delta) > deadband else { continue }
            if delta > 0 {
                positiveMovement += delta
            } else {
                negativeMovement += abs(delta)
            }
        }

        let reversalThreshold = axisAmplitude * 0.28
        return positiveMovement >= reversalThreshold && negativeMovement >= reversalThreshold
    }

    private static func hasReversal(_ points: [AirGesturePoint], among keyAxes: [Axis]) -> Bool {
        guard !keyAxes.isEmpty else { return false }
        var signsByAxis: [(axis: Axis, signs: [Int])] = []
        for phase in phaseSequence(points, axes: keyAxes) {
            if let existingIndex = signsByAxis.firstIndex(where: { $0.axis == phase.axis }) {
                if !signsByAxis[existingIndex].signs.contains(phase.sign) {
                    signsByAxis[existingIndex].signs.append(phase.sign)
                }
            } else {
                signsByAxis.append((axis: phase.axis, signs: [phase.sign]))
            }
        }
        return signsByAxis.contains { $0.signs.count > 1 }
    }

    private static func singleDominantEndpointPhase(_ points: [AirGesturePoint], axes: [Axis], secondaryLimit: Double) -> Phase? {
        let candidates = axes.compactMap { axis -> (phase: Phase, strength: Double)? in
            let values = relativeAxis(points, axis)
            let axisAmplitude = amplitude(values)
            guard axisAmplitude >= 0.03, let end = values.last else { return nil }
            let strength = abs(end)
            guard strength >= max(0.05, axisAmplitude * 0.35) else { return nil }
            return (Phase(axis: axis, sign: end > 0 ? 1 : -1), strength)
        }
        .sorted { $0.strength > $1.strength }

        guard let strongest = candidates.first else { return nil }
        let runnerUpStrength = candidates.dropFirst().first?.strength ?? 0
        guard runnerUpStrength <= strongest.strength * secondaryLimit else { return nil }
        return strongest.phase
    }

    private static func matcherAxis(for gestureAxis: AirGestureAxis, axes: [Axis]) -> Axis? {
        switch gestureAxis {
        case .yaw:
            return axes.contains(.yaw) ? .yaw : (axes.contains(.x) ? .x : nil)
        case .pitch:
            return axes.contains(.pitch) ? .pitch : (axes.contains(.y) ? .y : nil)
        case .roll:
            return axes.contains(.roll) ? .roll : nil
        case .lateralX:
            return axes.contains(.x) ? .x : nil
        case .verticalY:
            return axes.contains(.y) ? .y : nil
        case .depthZ:
            return nil
        }
    }

    private static func dominantAxisEndpointSimilarity(_ performed: [Double], _ sample: [Double], expectedSign: Int) -> Double {
        guard let performedEnd = performed.last, let sampleEnd = sample.last else { return 0 }

        let performedAmplitude = amplitude(performed)
        let sampleAmplitude = amplitude(sample)
        guard performedAmplitude >= 0.03, sampleAmplitude >= 0.03 else { return 0 }
        guard performedEnd * Double(expectedSign) > performedAmplitude * 0.35,
              sampleEnd * Double(expectedSign) > sampleAmplitude * 0.35 else {
            return 0
        }

        let endRatio = min(abs(performedEnd), abs(sampleEnd)) / max(abs(performedEnd), abs(sampleEnd), 1e-9)
        let amplitudeScore = 0.5 + 0.5 * endRatio
        let consistency = min(
            directionalConsistency(performed, expectedSign: expectedSign),
            directionalConsistency(sample, expectedSign: expectedSign)
        )
        return amplitudeScore * (0.65 + 0.35 * consistency)
    }

    private static func directionalConsistency(_ values: [Double], expectedSign: Int) -> Double {
        guard values.count >= 2 else { return 0 }

        let axisAmplitude = amplitude(values)
        let deadband = axisAmplitude * 0.015
        var alignedMovement = 0.0
        var totalMovement = 0.0

        for index in 1..<values.count {
            let delta = values[index] - values[index - 1]
            guard abs(delta) > deadband else { continue }
            let movement = abs(delta)
            totalMovement += movement
            if delta * Double(expectedSign) > 0 {
                alignedMovement += movement
            }
        }

        guard totalMovement > 1e-9 else { return 0 }
        return alignedMovement / totalMovement
    }

    private static func phaseSequence(_ points: [AirGesturePoint], axes: [Axis]) -> [Phase] {
        guard points.count >= 2 else { return [] }

        var seriesByAxis: [(axis: Axis, values: [Double], amplitude: Double)] = axes.map { axis in
            let values = relativeAxis(points, axis)
            return (axis, values, amplitude(values))
        }
        seriesByAxis.removeAll { $0.amplitude < 0.03 }
        guard !seriesByAxis.isEmpty else { return [] }

        var phases: [Phase] = []
        for index in 1..<points.count {
            var bestPhase: Phase?
            var bestMagnitude = 0.0

            for series in seriesByAxis {
                let delta = series.values[index] - series.values[index - 1]
                let deadband = series.amplitude * 0.035
                guard abs(delta) > deadband else { continue }
                let normalized = abs(delta) / max(series.amplitude, 1e-9)
                guard normalized > bestMagnitude else { continue }
                bestMagnitude = normalized
                bestPhase = Phase(axis: series.axis, sign: delta > 0 ? 1 : -1)
            }

            guard let bestPhase else { continue }
            if phases.last != bestPhase {
                phases.append(bestPhase)
            }
        }

        return phases
    }

    private static func longestCommonSubsequenceCount(_ lhs: [Phase], _ rhs: [Phase]) -> Int {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }

        var previous = Array(repeating: 0, count: rhs.count + 1)
        for leftIndex in 1...lhs.count {
            var current = Array(repeating: 0, count: rhs.count + 1)
            for rightIndex in 1...rhs.count {
                if lhs[leftIndex - 1] == rhs[rightIndex - 1] {
                    current[rightIndex] = previous[rightIndex - 1] + 1
                } else {
                    current[rightIndex] = max(previous[rightIndex], current[rightIndex - 1])
                }
            }
            previous = current
        }
        return previous[rhs.count]
    }

    /// Peak-to-peak amplitude (max − min) of a sequence.
    private static func amplitude(_ s: [Double]) -> Double {
        guard !s.isEmpty else { return 0 }
        var lo = s[0], hi = s[0]
        for v in s {
            if v < lo { lo = v }
            if v > hi { hi = v }
        }
        return hi - lo
    }

    /// Uniform-time resample to `count` points via linear interpolation.
    /// Time-based (not arc-length-based) so per-axis temporal alignment is
    /// preserved — the i-th resampled sample of two recordings of the same
    /// gesture corresponds to the same fractional time, regardless of the
    /// path's geometry.
    private static func resampleByTime(_ pts: [AirGesturePoint], to count: Int) -> [AirGesturePoint] {
        let fallback = pts.first ?? AirGesturePoint(x: 0.5, y: 0.5, timestamp: 0)
        guard pts.count >= 2 else {
            return Array(repeating: fallback, count: count)
        }
        let t0 = pts.first!.timestamp
        let t1 = pts.last!.timestamp
        let totalTime = t1 - t0
        guard totalTime > 1e-6 else {
            return Array(repeating: fallback, count: count)
        }
        let dt = totalTime / Double(count - 1)
        var out: [AirGesturePoint] = []
        out.reserveCapacity(count)
        var j = 0
        for i in 0..<count {
            let t = t0 + dt * Double(i)
            // Advance j so that pts[j].timestamp <= t <= pts[j+1].timestamp.
            while j + 1 < pts.count - 1, pts[j + 1].timestamp < t { j += 1 }
            let a = pts[j]
            let b = pts[min(j + 1, pts.count - 1)]
            let span = b.timestamp - a.timestamp
            let alpha = span > 1e-9 ? max(0, min(1, (t - a.timestamp) / span)) : 0
            let interp = AirGesturePoint(
                x: a.x + alpha * (b.x - a.x),
                y: a.y + alpha * (b.y - a.y),
                timestamp: t,
                yaw: a.yaw + alpha * (b.yaw - a.yaw),
                pitch: a.pitch + alpha * (b.pitch - a.pitch),
                roll: a.roll + alpha * (b.roll - a.roll),
                tx: a.tx + alpha * (b.tx - a.tx),
                ty: a.ty + alpha * (b.ty - a.ty),
                tz: a.tz + alpha * (b.tz - a.tz)
            )
            out.append(interp)
        }
        return out
    }
}

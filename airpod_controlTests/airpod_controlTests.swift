//
//  airpod_controlTests.swift
//  airpod_controlTests
//
//  Created by Jos on 25/4/26.
//

import Testing
import Foundation
@testable import airpod_control

@MainActor
struct airpod_controlTests {

    @Test func movementMagnitudeIsComputedFromVector() async throws {
        let vector = Vector3Value(x: 3, y: 4, z: 12)
        let magnitude = SensorSampleModel.magnitude(for: vector)
        #expect(abs(magnitude - 13) < 0.0001)
    }

    @Test func nonFiniteValuesAreSanitizedToZero() async throws {
        #expect(SensorSampleModel.sanitize(.infinity) == 0)
        #expect(SensorSampleModel.sanitize(-.infinity) == 0)
        #expect(SensorSampleModel.sanitize(.nan) == 0)
    }

    @Test func sampleDerivedMetricsTrackAttitudeAndMagnitude() async throws {
        let sample = SensorSampleModel(
            timestamp: Date(),
            attitude: AttitudeValue(roll: 0.1, pitch: -0.2, yaw: 0.3),
            rotationRate: Vector3Value(x: 1, y: 2, z: 3),
            gravity: Vector3Value(x: 0, y: -1, z: 0),
            userAcceleration: Vector3Value(x: 0.5, y: 0.5, z: 0.5),
            updateFrequencyHz: 60
        )

        #expect(sample.derived.headTilt == 0.1)
        #expect(sample.derived.nodAngle == -0.2)
        #expect(sample.derived.shakeAngle == 0.3)
        #expect(abs(sample.derived.movementMagnitude - 0.8660254) < 0.0001)
        #expect(sample.derived.updateFrequencyHz == 60)
    }

    @Test func alwaysOnStartGateRequiresDistanceAndSpeed() async throws {
        let startThreshold = 0.145
        let speedThreshold = 0.90

        #expect(!AlwaysOnStartGate.shouldStartCandidate(
            poseDistance: 0.144,
            angularSpeed: 1.20,
            startThreshold: startThreshold,
            speedThreshold: speedThreshold
        ))
        #expect(AlwaysOnStartGate.displayState(
            poseDistance: 0.144,
            angularSpeed: 1.20,
            startThreshold: startThreshold,
            speedThreshold: speedThreshold
        ) == .waiting)
        #expect(!AlwaysOnStartGate.shouldStartCandidate(
            poseDistance: 0.180,
            angularSpeed: 0.89,
            startThreshold: startThreshold,
            speedThreshold: speedThreshold
        ))
        #expect(AlwaysOnStartGate.displayState(
            poseDistance: 0.180,
            angularSpeed: 0.89,
            startThreshold: startThreshold,
            speedThreshold: speedThreshold
        ) == .slow)
        #expect(!AlwaysOnStartGate.shouldRefreshSlowDriftNeutral(
            poseDistance: 0.180,
            angularSpeed: 0.89,
            startThreshold: startThreshold,
            speedThreshold: speedThreshold,
            slowDuration: 0.29,
            settleDuration: 0.30
        ))
        #expect(AlwaysOnStartGate.shouldRefreshSlowDriftNeutral(
            poseDistance: 0.180,
            angularSpeed: 0.89,
            startThreshold: startThreshold,
            speedThreshold: speedThreshold,
            slowDuration: 0.30,
            settleDuration: 0.30
        ))
        #expect(AlwaysOnStartGate.shouldStartCandidate(
            poseDistance: 0.180,
            angularSpeed: 0.90,
            startThreshold: startThreshold,
            speedThreshold: speedThreshold
        ))
        #expect(AlwaysOnStartGate.displayState(
            poseDistance: 0.180,
            angularSpeed: 0.90,
            startThreshold: startThreshold,
            speedThreshold: speedThreshold
        ) == .capturing)
    }

    @Test func alwaysOnCalmGateUsesCalmMotionThreshold() async throws {
        #expect(AlwaysOnCalmGate.isCalm(motionMagnitude: 0.0009, threshold: 0.001))
        #expect(AlwaysOnCalmGate.isCalm(motionMagnitude: 0.001, threshold: 0.001))
        #expect(!AlwaysOnCalmGate.isCalm(motionMagnitude: 0.0011, threshold: 0.001))
        #expect(!AlwaysOnCalmGate.isCalm(motionMagnitude: 0.0001, threshold: -0.001))
    }

    @Test func debugLogCanBeClearedWhileEnabled() async throws {
        let defaults = UserDefaults.standard
        let previousDebugMode = DebugFileLog.persistentBool(forKey: DebugFileLog.debugModeKey)
        defer {
            defaults.set(previousDebugMode, forKey: DebugFileLog.debugModeKey)
            DebugFileLog.setEnabled(previousDebugMode, reason: "unit_test_restore")
        }

        defaults.set(true, forKey: DebugFileLog.debugModeKey)
        DebugFileLog.setEnabled(true, reason: "unit_test_enable")
        DebugFileLog.log("unit_test payload before_clear")
        try await Task.sleep(nanoseconds: 200_000_000)

        DebugFileLog.clearLog(reason: "unit_test_clear")
        try await Task.sleep(nanoseconds: 200_000_000)

        let logURL = URL(fileURLWithPath: DebugFileLog.logPath)
        let contents = try String(contentsOf: logURL, encoding: .utf8)
        #expect(contents.contains("debug_log cleared reason=unit_test_clear"))
        #expect(!contents.contains("unit_test payload before_clear"))
    }

    @Test func gestureReplayLogEncoderCompactsPathForAnalysis() throws {
        let path = syntheticGesturePath([
            (10.00, 0.0000, 0.0000, 0.0000),
            (10.25, -0.1000, 0.0200, -0.0300),
            (10.50, -0.2000, 0.0300, -0.0600),
            (10.75, -0.3000, 0.0400, -0.0900),
            (11.00, -0.4000, 0.0500, -0.1200)
        ])

        let json = try #require(GestureReplayLogEncoder.encode(
            intended: "CAL 01 Right",
            path: path,
            scores: [GestureReplayLogEncoder.Score(name: "CAL 01 Right", score: 0.87654)],
            threshold: 0.63,
            marginThreshold: 0.10,
            maximumPoints: 4
        ))
        let record = try JSONDecoder().decode(GestureReplayLogEncoder.Record.self, from: Data(json.utf8))

        #expect(record.schema == 1)
        #expect(record.intended == "CAL 01 Right")
        #expect(record.sourceCount == path.count)
        #expect(record.points.count == 4)
        #expect(record.points.first?.t == 0)
        #expect(record.points.last?.t == 1)
        #expect(record.points.last?.yaw == -0.4)
        #expect(record.scores.first?.score == 0.877)
    }

    @Test func gestureBackupPayloadRoundTripsCurrentTemplatesAndSettings() throws {
        var recognitionSettings = AirGestureRecognitionSettings()
        recognitionSettings.confidenceThreshold = 0.63
        recognitionSettings.motionThreshold = 0.012
        recognitionSettings.alwaysOnStartThreshold = 0.07
        recognitionSettings.alwaysOnHoldDuration = 0.45
        recognitionSettings.alwaysOnReturnToNeutralRadius = 0.09
        recognitionSettings.alwaysOnNeutralSettleDuration = 0.55
        recognitionSettings.alwaysOnGestureSpeed = 0.95
        recognitionSettings.alwaysOnGestureSize = 0.14
        recognitionSettings.alwaysOnFinishDelay = 0.12
        recognitionSettings.alwaysOnCooldownDuration = 0.40
        var appearanceSettings = AirGestureAppearanceSettings()
        appearanceSettings.showTrail = false
        let gesture = AirGestureDefinition(
            name: "Backup Test",
            inputType: .discrete,
            samples: [AirGestureSample(points: syntheticGesturePath([
                (0.00, 0.0000, 0.0000, 0.0000),
                (0.50, 0.3000, 0.0100, 0.0200),
                (1.00, 0.0200, 0.0000, 0.0000)
            ]))],
            axis: .yaw,
            trigger: GestureTrigger(type: .builtIn, builtInAction: .markEvent)
        )
        let payload = GestureBackupPayload(
            appRevision: "test-revision",
            gestures: [gesture],
            recognitionSettings: recognitionSettings,
            appearanceSettings: appearanceSettings
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(GestureBackupPayload.self, from: data)

        #expect(decoded.schema == 1)
        #expect(decoded.appRevision == "test-revision")
        #expect(decoded.gestures.first?.name == "Backup Test")
        #expect(decoded.gestures.first?.samples.first?.points.last?.yaw == 0.02)
        #expect(decoded.recognitionSettings.confidenceThreshold == 0.63)
        #expect(decoded.recognitionSettings.motionThreshold == 0.012)
        #expect(decoded.recognitionSettings.alwaysOnStartThreshold == 0.07)
        #expect(decoded.recognitionSettings.alwaysOnHoldDuration == 0.45)
        #expect(decoded.recognitionSettings.alwaysOnReturnToNeutralRadius == 0.09)
        #expect(decoded.recognitionSettings.alwaysOnNeutralSettleDuration == 0.55)
        #expect(decoded.recognitionSettings.alwaysOnGestureSpeed == 0.95)
        #expect(decoded.recognitionSettings.alwaysOnGestureSize == 0.14)
        #expect(decoded.recognitionSettings.alwaysOnFinishDelay == 0.12)
        #expect(decoded.recognitionSettings.alwaysOnCooldownDuration == 0.40)
        #expect(decoded.appearanceSettings.showTrail == false)
    }

    @Test func trackingPreferenceDefaultsOnAndPersists() async throws {
        let defaults = UserDefaults.standard
        let key = AirGestureStore.trackingEnabledKey
        let previousValue = defaults.object(forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        #expect(AirGestureStore.shared.loadTrackingEnabled())
        AirGestureStore.shared.saveTrackingEnabled(false)
        #expect(!AirGestureStore.shared.loadTrackingEnabled())
        AirGestureStore.shared.saveTrackingEnabled(true)
        #expect(AirGestureStore.shared.loadTrackingEnabled())
    }

    @Test func rightDownMatcherRejectsExtraLeftReversal() async throws {
        let rightDown = AirGestureDefinition(
            name: "Right Down",
            inputType: .discrete,
            samples: [AirGestureSample(points: syntheticGesturePath([
                (0.00, 0.00, 0.00, 0.00),
                (0.35, -0.34, -0.02, -0.06),
                (0.70, -0.45, -0.16, -0.10),
                (1.00, -0.46, -0.22, -0.12)
            ]))],
            trigger: GestureTrigger(type: .builtIn, builtInAction: .markEvent)
        )

        let cleanAttempt = syntheticGesturePath([
            (0.00, 0.00, 0.00, 0.00),
            (0.35, -0.33, -0.02, -0.06),
            (0.70, -0.44, -0.15, -0.10),
            (1.00, -0.45, -0.21, -0.12)
        ])

        let extraLeftAttempt = syntheticGesturePath([
            (0.00, 0.00, 0.00, 0.00),
            (0.28, -0.34, -0.02, -0.06),
            (0.62, -0.45, -0.18, -0.10),
            (1.00, -0.05, -0.22, -0.09)
        ])

        let cleanScore = try #require(AirGestureMatcher.rankedMatches(
            performedPath: cleanAttempt,
            gestures: [rightDown],
            minimumPathLength: 0
        ).first?.score)

        let extraLeftScore = try #require(AirGestureMatcher.rankedMatches(
            performedPath: extraLeftAttempt,
            gestures: [rightDown],
            minimumPathLength: 0
        ).first?.score)

        #expect(cleanScore > 0.75, "cleanScore=\(cleanScore)")
        #expect(extraLeftScore < 0.66, "extraLeftScore=\(extraLeftScore)")
    }

    @Test func singlePhaseMatcherToleratesNaturalSecondaryCoupling() async throws {
        let right = AirGestureDefinition(
            name: "Right",
            inputType: .discrete,
            samples: [AirGestureSample(points: syntheticGesturePath([
                (0.00, 0.00, 0.00, 0.00),
                (1.00, -0.40, 0.01, -0.10)
            ]))],
            trigger: GestureTrigger(type: .builtIn, builtInAction: .markEvent)
        )
        let down = AirGestureDefinition(
            name: "Down",
            inputType: .discrete,
            samples: [AirGestureSample(points: syntheticGesturePath([
                (0.00, 0.00, 0.00, 0.00),
                (0.35, -0.02, -0.10, 0.00),
                (0.70, -0.04, -0.18, -0.01),
                (1.00, -0.04, -0.23, -0.01)
            ]))],
            trigger: GestureTrigger(type: .builtIn, builtInAction: .markEvent)
        )
        let downRight = AirGestureDefinition(
            name: "Down Right",
            inputType: .discrete,
            samples: [AirGestureSample(points: syntheticGesturePath([
                (0.00, 0.00, 0.00, 0.00),
                (0.35, -0.02, -0.16, -0.02),
                (0.70, -0.20, -0.21, -0.06),
                (1.00, -0.35, -0.23, -0.08)
            ]))],
            trigger: GestureTrigger(type: .builtIn, builtInAction: .markEvent)
        )

        let pureRightAttempt = syntheticGesturePath([
            (0.00, 0.00, 0.00, 0.00),
            (1.00, -0.24, 0.00, -0.09)
        ])
        let pureDownAttempt = syntheticGesturePath([
            (0.00, 0.00, 0.00, 0.00),
            (0.35, -0.01, -0.07, 0.00),
            (0.70, -0.01, -0.12, 0.01),
            (1.00, -0.01, -0.14, 0.01)
        ])

        let rightScore = try #require(AirGestureMatcher.rankedMatches(
            performedPath: pureRightAttempt,
            gestures: [right],
            minimumPathLength: 0
        ).first?.score)
        let downScore = try #require(AirGestureMatcher.rankedMatches(
            performedPath: pureDownAttempt,
            gestures: [down],
            minimumPathLength: 0
        ).first?.score)
        let downRightScoreForPureDown = try #require(AirGestureMatcher.rankedMatches(
            performedPath: pureDownAttempt,
            gestures: [downRight],
            minimumPathLength: 0
        ).first?.score)

        #expect(rightScore > 0.66, "rightScore=\(rightScore)")
        #expect(downScore > 0.66, "downScore=\(downScore)")
        #expect(downRightScoreForPureDown < 0.66, "downRightScoreForPureDown=\(downRightScoreForPureDown)")
    }

    @Test func rightMatcherToleratesNaturalRollCouplingFromDiagnosticBatch() async throws {
        let right = AirGestureDefinition(
            name: "Right",
            inputType: .discrete,
            samples: [AirGestureSample(points: syntheticGesturePath([
                (0.00, 0.0000, 0.0000, 0.0000),
                (0.60, -0.3850, 0.0068, -0.0200),
                (1.00, -0.3990, 0.0068, -0.0866)
            ]))],
            axis: .yaw,
            trigger: GestureTrigger(type: .builtIn, builtInAction: .markEvent)
        )
        let downRight = AirGestureDefinition(
            name: "Down Right",
            inputType: .discrete,
            samples: [AirGestureSample(points: syntheticGesturePath([
                (0.00, 0.0000, 0.0000, 0.0000),
                (0.35, -0.0300, -0.1500, -0.0200),
                (0.70, -0.2500, -0.2100, -0.0600),
                (1.00, -0.3966, -0.1447, -0.0768)
            ]))],
            axis: .pitch,
            trigger: GestureTrigger(type: .builtIn, builtInAction: .markEvent)
        )

        let coupledRightAttempt = syntheticGesturePath([
            (0.00, 0.0000, 0.0000, 0.0000),
            (0.35, -0.1200, 0.0000, -0.1600),
            (0.70, -0.2500, 0.0750, -0.1800),
            (1.00, -0.3765, 0.0810, -0.1840)
        ])

        let scores = AirGestureMatcher.rankedMatches(
            performedPath: coupledRightAttempt,
            gestures: [right, downRight],
            minimumPathLength: 0
        )
        let rightScore = try #require(scores.first(where: { $0.gesture.name == "Right" })?.score)
        let downRightScore = try #require(scores.first(where: { $0.gesture.name == "Down Right" })?.score)

        #expect(rightScore > 0.66, "rightScore=\(rightScore)")
        #expect(downRightScore < 0.66, "downRightScore=\(downRightScore)")
    }

    @Test func orderedCompositesBeatSimpleRightFallbackForCalibrationBatch() async throws {
        let right = AirGestureDefinition(
            name: "Right",
            inputType: .discrete,
            samples: [
                AirGestureSample(points: syntheticGesturePath([
                    (0.00, 0.0000, 0.0000, 0.0000),
                    (0.55, -0.3000, -0.0900, -0.0500),
                    (1.00, -0.4520, -0.1397, -0.0664)
                ])),
                AirGestureSample(points: syntheticGesturePath([
                    (0.00, 0.0000, 0.0000, 0.0000),
                    (1.00, -0.3990, 0.0068, -0.0866)
                ]))
            ],
            axis: .yaw,
            trigger: GestureTrigger(type: .builtIn, builtInAction: .markEvent)
        )
        let rightDown = AirGestureDefinition(
            name: "Right Down",
            inputType: .discrete,
            samples: [AirGestureSample(points: syntheticGesturePath([
                (0.00, 0.0000, 0.0000, 0.0000),
                (0.45, -0.2500, 0.0380, -0.0060),
                (1.00, -0.3073, -0.1554, -0.0394)
            ]))],
            axis: .yaw,
            trigger: GestureTrigger(type: .builtIn, builtInAction: .markEvent)
        )
        let downRight = AirGestureDefinition(
            name: "Down Right",
            inputType: .discrete,
            samples: [AirGestureSample(points: syntheticGesturePath([
                (0.00, 0.0000, 0.0000, 0.0000),
                (0.45, -0.0300, -0.1500, -0.0200),
                (1.00, -0.3966, -0.1447, -0.0768)
            ]))],
            axis: .pitch,
            trigger: GestureTrigger(type: .builtIn, builtInAction: .markEvent)
        )

        let rightDownAttempt = syntheticGesturePath([
            (0.00, 0.0000, 0.0000, 0.0000),
            (0.45, -0.2520, 0.0380, 0.0020),
            (1.00, -0.2927, -0.1393, 0.0070)
        ])
        let downRightAttempt = syntheticGesturePath([
            (0.00, 0.0000, 0.0000, 0.0000),
            (0.40, -0.0300, -0.1800, -0.0300),
            (1.00, -0.5424, -0.1692, -0.1937)
        ])

        let rightDownScores = AirGestureMatcher.rankedMatches(
            performedPath: rightDownAttempt,
            gestures: [right, rightDown, downRight],
            minimumPathLength: 0
        )
        let downRightScores = AirGestureMatcher.rankedMatches(
            performedPath: downRightAttempt,
            gestures: [right, rightDown, downRight],
            minimumPathLength: 0
        )

        #expect(rightDownScores.first?.gesture.name == "Right Down", "scores=\(rightDownScores.map { "\($0.gesture.name)=\($0.score)" })")
        #expect(downRightScores.first?.gesture.name == "Down Right", "scores=\(downRightScores.map { "\($0.gesture.name)=\($0.score)" })")
        #expect((rightDownScores.first?.score ?? 0) > 0.75)
        #expect((downRightScores.first?.score ?? 0) > 0.75)
    }

    @Test func rollEndpointBeatsSimpleRightYawFallback() async throws {
        let right = AirGestureDefinition(
            name: "Right",
            inputType: .discrete,
            samples: [AirGestureSample(points: syntheticGesturePath([
                (0.00, 0.0000, 0.0000, 0.0000),
                (1.00, -0.3990, 0.0068, -0.0866)
            ]))],
            axis: .yaw,
            trigger: GestureTrigger(type: .builtIn, builtInAction: .markEvent)
        )
        let rollRight = AirGestureDefinition(
            name: "Roll Right",
            inputType: .discrete,
            samples: [AirGestureSample(points: syntheticGesturePath([
                (0.00, 0.0000, 0.0000, 0.0000),
                (0.45, -0.1200, 0.0240, 0.1200),
                (1.00, -0.1218, 0.0241, 0.2411)
            ]))],
            axis: .roll,
            trigger: GestureTrigger(type: .builtIn, builtInAction: .markEvent)
        )

        let rollAttempt = syntheticGesturePath([
            (0.00, 0.0000, 0.0000, 0.0000),
            (0.45, -0.1900, 0.0220, 0.0320),
            (1.00, -0.1950, 0.0223, 0.0600)
        ])
        let scores = AirGestureMatcher.rankedMatches(
            performedPath: rollAttempt,
            gestures: [right, rollRight],
            minimumPathLength: 0
        )

        let rollScore = try #require(scores.first(where: { $0.gesture.name == "Roll Right" })?.score)
        let rightScore = scores.first(where: { $0.gesture.name == "Right" })?.score ?? 0
        #expect(scores.first?.gesture.name == "Roll Right", "scores=\(scores.map { "\($0.gesture.name)=\($0.score)" })")
        #expect(rollScore > rightScore, "rollScore=\(rollScore) rightScore=\(rightScore)")
    }

    @Test func rightDownUpReversalBeatsSimpleRightFallback() async throws {
        let right = AirGestureDefinition(
            name: "Right",
            inputType: .discrete,
            samples: [
                AirGestureSample(points: syntheticGesturePath([
                    (0.00, 0.0000, 0.0000, 0.0000),
                    (0.15, -0.2000, 0.0500, -0.0400),
                    (1.00, -0.3797, 0.1024, -0.0907)
                ])),
                AirGestureSample(points: syntheticGesturePath([
                    (0.00, 0.0000, 0.0000, 0.0000),
                    (1.00, -0.3990, 0.0068, -0.0866)
                ]))
            ],
            axis: .yaw,
            trigger: GestureTrigger(type: .builtIn, builtInAction: .markEvent)
        )
        let rightDownUp = AirGestureDefinition(
            name: "Right Down Up",
            inputType: .discrete,
            samples: [AirGestureSample(points: syntheticGesturePath([
                (0.00, 0.0000, 0.0000, 0.0000),
                (0.18, -0.3000, -0.1500, -0.0600),
                (0.45, -0.5000, -0.0600, -0.1000),
                (1.00, -0.5381, 0.0847, -0.1106)
            ]))],
            axis: .pitch,
            trigger: GestureTrigger(type: .builtIn, builtInAction: .markEvent)
        )

        let attempt = syntheticGesturePath([
            (0.00, 0.0000, 0.0000, 0.0000),
            (0.16, -0.2500, 0.0300, -0.0200),
            (0.36, -0.3400, -0.1880, -0.0800),
            (1.00, -0.2790, -0.0120, -0.0030)
        ])
        let scores = AirGestureMatcher.rankedMatches(
            performedPath: attempt,
            gestures: [right, rightDownUp],
            minimumPathLength: 0
        )

        let rightDownUpScore = try #require(scores.first(where: { $0.gesture.name == "Right Down Up" })?.score)
        let rightScore = scores.first(where: { $0.gesture.name == "Right" })?.score ?? 0
        #expect(scores.first?.gesture.name == "Right Down Up", "scores=\(scores.map { "\($0.gesture.name)=\($0.score)" })")
        #expect(rightDownUpScore >= 0.63, "rightDownUpScore=\(rightDownUpScore)")
        #expect(rightDownUpScore > rightScore, "rightDownUpScore=\(rightDownUpScore) rightScore=\(rightScore)")
    }

    @Test func centerReturnYawGestureIgnoresSmallPitchNoise() async throws {
        let right = AirGestureDefinition(
            name: "Right",
            inputType: .discrete,
            samples: [AirGestureSample(points: syntheticGesturePath([
                (0.00, 0.0000, 0.0000, 0.0000),
                (1.00, 0.4000, 0.0050, 0.0800)
            ]))],
            axis: .yaw,
            trigger: GestureTrigger(type: .builtIn, builtInAction: .markEvent)
        )
        let leftCenter = AirGestureDefinition(
            name: "Left Center",
            inputType: .discrete,
            samples: [AirGestureSample(points: syntheticGesturePath([
                (0.00, 0.0000, 0.0000, 0.0000),
                (0.24, 0.3800, 0.0300, 0.1600),
                (0.48, 0.0300, 0.0640, 0.0200),
                (1.00, 0.0200, 0.0060, 0.0120)
            ]))],
            axis: .yaw,
            trigger: GestureTrigger(type: .builtIn, builtInAction: .markEvent)
        )

        let attempt = syntheticGesturePath([
            (0.00, 0.0000, 0.0000, 0.0000),
            (0.22, 0.3650, 0.0030, 0.1450),
            (0.50, 0.0400, 0.0050, 0.0180),
            (1.00, 0.0300, 0.0040, 0.0040)
        ])
        let incompleteAttempt = syntheticGesturePath([
            (0.00, 0.0000, 0.0000, 0.0000),
            (1.00, 0.3650, 0.0030, 0.1450)
        ])

        let scores = AirGestureMatcher.rankedMatches(
            performedPath: attempt,
            gestures: [right, leftCenter],
            minimumPathLength: 0
        )
        let incompleteScores = AirGestureMatcher.rankedMatches(
            performedPath: incompleteAttempt,
            gestures: [leftCenter],
            minimumPathLength: 0
        )

        let leftCenterScore = try #require(scores.first(where: { $0.gesture.name == "Left Center" })?.score)
        let rightScore = scores.first(where: { $0.gesture.name == "Right" })?.score ?? 0
        #expect(scores.first?.gesture.name == "Left Center", "scores=\(scores.map { "\($0.gesture.name)=\($0.score)" })")
        #expect(leftCenterScore >= 0.63, "leftCenterScore=\(leftCenterScore)")
        #expect(leftCenterScore > rightScore, "leftCenterScore=\(leftCenterScore) rightScore=\(rightScore)")
        #expect((incompleteScores.first?.score ?? 0) < 0.63, "incompleteScores=\(incompleteScores.map { "\($0.gesture.name)=\($0.score)" })")
    }

    @Test func lateStartedLeftCenterDoesNotMatchSimpleRightFallback() async throws {
        let right = AirGestureDefinition(
            name: "CAL 01 Right",
            inputType: .discrete,
            samples: [AirGestureSample(points: syntheticGesturePath([
                (0.00,  0.0000, 0.0000,  0.0000),
                (1.00, -0.3990, 0.0068, -0.0866)
            ]))],
            axis: .yaw,
            trigger: GestureTrigger(type: .builtIn, builtInAction: .markEvent)
        )
        let leftCenter = AirGestureDefinition(
            name: "CAL LEFT-CENTER",
            inputType: .discrete,
            samples: [AirGestureSample(points: syntheticGesturePath([
                (0.00, 0.0000,  0.0000,  0.0000),
                (0.22, 0.4000,  0.0500,  0.1500),
                (0.54, 0.0000, -0.0200, -0.0300),
                (1.00, 0.0000, -0.0180, -0.0260)
            ]))],
            axis: .yaw,
            trigger: GestureTrigger(type: .builtIn, builtInAction: .markEvent)
        )

        let lateStartedAttempt = syntheticGesturePath([
            (0.00,  0.1800, 0.0181,  0.0645),
            (0.12,  0.4108, 0.0607,  0.1443),
            (0.30,  0.2401, 0.0329,  0.0526),
            (0.47, -0.0025, 0.0206, -0.0543),
            (0.52, -0.0372, 0.0226, -0.0664),
            (0.77,  0.0011, 0.0135, -0.0308)
        ])

        let scores = AirGestureMatcher.rankedMatches(
            performedPath: lateStartedAttempt,
            gestures: [right, leftCenter],
            minimumPathLength: 0
        )

        let leftCenterScore = try #require(scores.first(where: { $0.gesture.name == "CAL LEFT-CENTER" })?.score)
        let rightScore = scores.first(where: { $0.gesture.name == "CAL 01 Right" })?.score ?? 0
        #expect(scores.first?.gesture.name == "CAL LEFT-CENTER", "scores=\(scores.map { "\($0.gesture.name)=\($0.score)" })")
        #expect(leftCenterScore >= 0.63, "leftCenterScore=\(leftCenterScore)")
        #expect(rightScore < 0.63, "rightScore=\(rightScore)")
    }

    @Test func lateStartedRightReturnDoesNotMatchSimpleLeft() async throws {
        let right = AirGestureDefinition(
            name: "CAL 01 Right",
            inputType: .discrete,
            samples: [AirGestureSample(points: syntheticGesturePath([
                (0.00,  0.0000, 0.0000,  0.0000),
                (1.00, -0.4000, 0.0200, -0.0900)
            ]))],
            axis: .yaw,
            trigger: GestureTrigger(type: .builtIn, builtInAction: .markEvent)
        )
        let left = AirGestureDefinition(
            name: "CAL Left",
            inputType: .discrete,
            samples: [AirGestureSample(points: syntheticGesturePath([
                (0.00, 0.0000, 0.0000, 0.0000),
                (1.00, 0.3900, 0.0200, 0.1300)
            ]))],
            axis: .yaw,
            trigger: GestureTrigger(type: .builtIn, builtInAction: .markEvent)
        )

        let lateStartedRightReturn = syntheticGesturePath([
            (0.00, -0.1800, 0.0050, -0.0350),
            (0.20, -0.4100, 0.0280, -0.0920),
            (0.52, -0.1900, 0.0100, -0.0480),
            (0.78, -0.0200, 0.0040, -0.0100)
        ])

        let scores = AirGestureMatcher.rankedMatches(
            performedPath: lateStartedRightReturn,
            gestures: [right, left],
            minimumPathLength: 0
        )

        let leftScore = scores.first(where: { $0.gesture.name == "CAL Left" })?.score ?? 0
        #expect(leftScore < 0.63, "leftScore=\(leftScore)")
    }

    private func syntheticGesturePath(_ points: [(TimeInterval, Double, Double, Double)]) -> [AirGesturePoint] {
        guard points.count >= 2 else {
            return points.map { timestamp, yaw, pitch, roll in
                AirGesturePoint(x: 0.5 + yaw, y: 0.5 + pitch, timestamp: timestamp, yaw: yaw, pitch: pitch, roll: roll)
            }
        }

        var path: [AirGesturePoint] = []
        let stepsPerSegment = 8

        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]

            for step in 0..<stepsPerSegment {
                if index > 0 && step == 0 { continue }
                let alpha = Double(step) / Double(stepsPerSegment)
                let timestamp = start.0 + alpha * (end.0 - start.0)
                let yaw = start.1 + alpha * (end.1 - start.1)
                let pitch = start.2 + alpha * (end.2 - start.2)
                let roll = start.3 + alpha * (end.3 - start.3)
                path.append(AirGesturePoint(x: 0.5 + yaw, y: 0.5 + pitch, timestamp: timestamp, yaw: yaw, pitch: pitch, roll: roll))
            }
        }

        if let last = points.last {
            path.append(AirGesturePoint(x: 0.5 + last.1, y: 0.5 + last.2, timestamp: last.0, yaw: last.1, pitch: last.2, roll: last.3))
        }

        return path
    }

}

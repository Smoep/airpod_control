import Foundation

enum AlwaysOnCalmGate {
    static func isCalm(motionMagnitude: Double, threshold: Double) -> Bool {
        motionMagnitude <= max(threshold, 0)
    }
}
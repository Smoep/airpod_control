import Foundation

/// Single source of truth for the displayed build revision. Surfaced in the
/// Settings tab so the user can tell which build is running without rebuilding
/// or re-deploying the app.
enum AppRevision {
    static let current = "v1.0.0"
}

import AppKit
import Foundation

enum GestureAppLauncher {
    static func launch(name: String, path: String) -> Bool {
        dbgLog("ENTRY app_launch name=\(name) path=\(path)")
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPath.isEmpty {
            let url = URL(fileURLWithPath: trimmedPath)
            let exists = FileManager.default.fileExists(atPath: url.path)
            dbgLog("EXTERNAL FileManager.fileExists path=\(url.path) return=\(exists)")
            guard exists else {
                dbgLog("BAIL app_launch reason=missing_path path=\(url.path)")
                return false
            }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
                dbgLog("EXTERNAL NSWorkspace.openApplication path=\(url.path) return_app=\(app?.localizedName ?? "nil") error=\(error?.localizedDescription ?? "nil")")
            }
            dbgLog("DONE app_launch request=path path=\(url.path)")
            return true
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            dbgLog("BAIL app_launch reason=empty_name")
            return false
        }

        guard let fullPath = NSWorkspace.shared.fullPath(forApplication: trimmedName) else {
            dbgLog("EXTERNAL NSWorkspace.fullPath application=\(trimmedName) return=nil")
            dbgLog("BAIL app_launch reason=app_not_found name=\(trimmedName)")
            return false
        }
        dbgLog("EXTERNAL NSWorkspace.fullPath application=\(trimmedName) return=\(fullPath)")

        let url = URL(fileURLWithPath: fullPath)
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
            dbgLog("EXTERNAL NSWorkspace.openApplication path=\(url.path) return_app=\(app?.localizedName ?? "nil") error=\(error?.localizedDescription ?? "nil")")
        }
        dbgLog("DONE app_launch request=name name=\(trimmedName) path=\(url.path)")
        return true
    }
}

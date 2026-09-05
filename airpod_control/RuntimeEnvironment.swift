import Foundation

enum RuntimeEnvironment {
    static let isAutomatedTest: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }()

    static let isSwiftUIPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"

    static var shouldUsePhysicalMotionHardware: Bool {
        !isAutomatedTest && !isSwiftUIPreview
    }
}

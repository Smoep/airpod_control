//
//  airpod_controlUITests.swift
//  airpod_controlUITests
//
//  Created by Jos on 25/4/26.
//

import XCTest

final class airpod_controlUITests: XCTestCase {

    private func requireInteractiveAutomation() throws {
        throw XCTSkip("UI tests require an interactive macOS automation session.")
    }

    override func setUpWithError() throws {
        try requireInteractiveAutomation()
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        try requireInteractiveAutomation()
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testLaunchPerformance() throws {
        try requireInteractiveAutomation()
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}

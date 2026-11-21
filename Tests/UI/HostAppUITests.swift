import XCTest

final class HostAppUITests: XCTestCase {
    func testSpokenCorrectionPlayground() {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["settings.keyboard"].tap()
        let field = app.textFields["host.playground"].firstMatch.exists ? app.textFields["host.playground"] : app.textViews["host.playground"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Lets meet on Monday, sorry I mean Tuesday.")
        app.buttons["host.applyCorrections"].tap()
        let result = app.staticTexts["host.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(result.label.hasSuffix("meet on Tuesday."), result.label)
    }

    /// Records in the app with a test transcript standing in for speech (Debug only) and checks
    /// the result screen shows the corrected text and the Monday → Tuesday diff.
    func testRecordShowsCorrectionDiff() {
        let app = XCUIApplication()
        app.launchEnvironment["DICTKB_TRANSCRIPT"] = "Let's meet on Monday at noon, sorry I mean Tuesday."
        app.launch()
        app.buttons["host.record"].tap()
        let stop = app.buttons["host.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        stop.tap()
        XCTAssertTrue(app.staticTexts["host.resultText"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["host.resultText"].label, "Let's meet on Tuesday at noon.")
        XCTAssertTrue(app.otherElements["host.correction"].exists || app.staticTexts["Monday changed to Tuesday"].exists)
    }
}

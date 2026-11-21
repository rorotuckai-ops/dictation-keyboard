import XCTest

final class HostAppUITests: XCTestCase {
    func testSpokenCorrectionPlayground() {
        let app = XCUIApplication()
        app.launch()
        let field = app.textFields["host.playground"].firstMatch.exists ? app.textFields["host.playground"] : app.textViews["host.playground"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Lets meet on Monday, sorry I mean Tuesday.")
        app.buttons["host.applyCorrections"].tap()
        XCTAssertTrue(app.staticTexts["Lets meet on Tuesday."].waitForExistence(timeout: 5))
    }
}

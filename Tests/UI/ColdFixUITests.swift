import XCTest

/// Fix from the keyboard in Messages while the host app is not running: the keyboard opens the
/// app, which runs Gemma; going back to Messages must replace the text with the fixed version.
/// Needs the Dictation Keyboard enabled with Full Access and the Gemma model imported.
final class ColdFixUITests: XCTestCase {
    func testFixWithHostColdStartReplacesText() throws {
        let host = XCUIApplication()
        host.terminate()
        sleep(4) // let the host's heartbeat go stale so the keyboard hands off

        let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        messages.launch()
        messages.cells.firstMatch.tap()
        let field = messages.textFields["messageBodyField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let fix = messages.buttons["kb.fix"]
        try XCTSkipUnless(fix.waitForExistence(timeout: 5), "Dictation Keyboard isn't the active keyboard")
        // Type through the keyboard's own keys so its text proxy sees the edits, as when a person types.
        if !messages.buttons["key.a"].exists { messages.buttons["kb.letters"].tap() }
        clear(field, messages)
        let original = "I has went to the store yesterday and buyed milk"
        for char in original {
            let key = messages.buttons[char == " " ? "key.space" : "key.\(char)"]
            (key.exists ? key : messages.buttons["key.\(char.uppercased())"]).tap()
        }
        XCTAssertEqual(field.value as? String, original)
        messages.buttons["kb.letters"].tap()

        fix.tap()
        XCTAssertTrue(host.wait(for: .runningForeground, timeout: 20), "Fix didn't open the app")
        let hint = host.descendants(matching: .any)["host.returnHint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 20))
        let done = NSPredicate(format: "label BEGINSWITH 'Done'")
        expectation(for: done, evaluatedWith: hint)
        waitForExpectations(timeout: 180)

        messages.activate()
        let replaced = NSPredicate { _, _ in
            guard let value = field.value as? String else { return false }
            return !value.isEmpty && value != original
        }
        expectation(for: replaced, evaluatedWith: field)
        waitForExpectations(timeout: 30)
        XCTAssertFalse((field.value as? String ?? "").contains("buyed"), field.value as? String ?? "")
    }

    private func clear(_ field: XCUIElement, _ app: XCUIApplication) {
        guard let value = field.value as? String, !value.isEmpty, value != field.placeholderValue else { return }
        for _ in 0..<value.count { app.buttons["key.delete"].tap() }
    }
}

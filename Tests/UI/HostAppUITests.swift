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

    /// The UI Bot's setup: only a test clip, no transcript. Record must use the clip, not the
    /// simulator's microphone, which crashes the app on a Mac without one.
    func testRecordWithAudioFixtureSkipsMicrophone() throws {
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("dictation.wav")
        try silentWAV(seconds: 1).write(to: clip)
        let app = XCUIApplication()
        app.launchEnvironment["DICTKB_AUDIO"] = clip.path
        app.resetAuthorizationStatus(for: .microphone)
        app.launch()
        app.buttons["host.record"].tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        let stop = app.buttons["host.stop"]
        let error = app.staticTexts["host.recordError"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), error.exists ? error.label : "app state \(app.state.rawValue)")
        stop.tap()
        _ = error.waitForExistence(timeout: 30)
        XCTAssertEqual(app.state, .runningForeground)
    }

    private func silentWAV(seconds: Int, sampleRate: UInt32 = 16_000) -> Data {
        let samples = Data(count: Int(sampleRate) * seconds * 2)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples.count))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(sampleRate); append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(samples.count))
        return data + samples
    }
}

import XCTest

final class SpokenCorrectionsTests: XCTestCase {
    private func fix(_ s: String) -> String { SpokenCorrections.apply(s).text }

    func testSorryIMeanWeekday() {
        XCTAssertEqual(fix("Let's meet on Monday, sorry I mean Tuesday."), "Let's meet on Tuesday.")
        XCTAssertEqual(fix("Let's meet on Monday. Sorry, I mean Tuesday."), "Let's meet on Tuesday.")
        XCTAssertEqual(fix("lets meet monday sorry i mean tuesday at noon"), "Lets meet tuesday at noon")
    }

    func testNoWaitMakeItTime() {
        XCTAssertEqual(fix("The call is at 4pm, no wait, make it 5pm."), "The call is at 5pm.")
        XCTAssertEqual(fix("Dinner at 7:30 p.m. No wait, make it 8 p.m."), "Dinner at 8 p.m.")
    }

    func testGenericReplacement() {
        XCTAssertEqual(fix("Send it to John, sorry I mean Jane."), "Send it to Jane.")
        let r = SpokenCorrections.apply("I'll take the red one, sorry I mean the blue one.")
        XCTAssertEqual(r.text, "I'll take the blue one.")
        XCTAssertFalse(r.needsModel)
    }

    func testCompoundAndPercentCorrections() {
        XCTAssertEqual(fix("Meet Monday at noon, sorry I mean Tuesday at 1pm."), "Meet Tuesday at 1pm.")
        XCTAssertEqual(fix("Raise it 10%, sorry I mean 20%."), "Raise it 20%.")
    }

    func testDeleteSentenceWithDecimals() {
        XCTAssertEqual(fix("Hi there. It costs 4.50 at 5 p.m. today. Delete the last sentence."), "Hi there.")
        XCTAssertEqual(fix("Arrive at 5 p.m. Bring cake. Delete the last sentence."), "Arrive at 5 p.m.")
    }

    func testScratchThat() {
        XCTAssertEqual(fix("Meet at the cafe. Scratch that. Meet at the library."), "Meet at the library.")
        XCTAssertEqual(fix("Hi Sam. I'll bring cake scratch that I'll bring pie."), "Hi Sam. I'll bring pie.")
    }

    func testDeleteLastSentence() {
        XCTAssertEqual(fix("First point. Second point. Delete the last sentence. Third point."), "First point. Third point.")
    }

    func testFillersAndCapitalization() {
        XCTAssertEqual(fix("um so i think uh we should go."), "So I think we should go.")
    }

    func testHardCaseIsFlaggedForModel() {
        let r = SpokenCorrections.apply("Book the flight for the morning, sorry I mean push everything to the evening after the meeting.")
        XCTAssertTrue(r.needsModel)
    }

    func testPlainTextUntouched() {
        let r = SpokenCorrections.apply("This is fine.")
        XCTAssertEqual(r.text, "This is fine.")
        XCTAssertEqual(r.applied, 0)
    }

    func testPromptCleanup() {
        XCTAssertEqual(Prompts.clean("Here is the corrected text:\n\"Hello there.\""), "Hello there.")
        XCTAssertEqual(Prompts.clean("```\nHi.\n```"), "Hi.")
    }
}

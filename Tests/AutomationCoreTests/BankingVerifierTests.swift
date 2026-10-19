import XCTest
@testable import AutomationCore

final class BankingVerifierTests: XCTestCase {
    func testStrictCountParsingDoesNotGuess() {
        XCTAssertEqual(CountFormat.digitsOnly.parse(" 1234 "), 1234)
        XCTAssertEqual(CountFormat.commaGrouped.parse("1,234"), 1234)
        XCTAssertEqual(CountFormat.spaceGrouped.parse("1 234"), 1234)
        for text in ["1.234", "1,23", "Balance: 123", "O", "-1", "9999999999999999999999999"] {
            XCTAssertNil(CountFormat.commaGrouped.parse(text), text)
        }
        XCTAssertNil(CountFormat.digitsOnly.parse("1,234"))
    }

    func testBankIncreaseRequiresFreshReadableEvidenceAndNoProcessing() {
        let before = Observation(matches: [.bankTitle: 1, .bankBalanceText: 1], text: [.bankBalanceText: "100"])
        let increased = Observation(matches: [.bankTitle: 1, .bankBalanceText: 1], text: [.bankBalanceText: "101"])
        XCTAssertTrue(BankingVerifier.verified(before: before, after: increased, mode: .bankBalanceIncrease, format: .digitsOnly))
        XCTAssertFalse(BankingVerifier.verified(before: before, after: before, mode: .bankBalanceIncrease, format: .digitsOnly))
        let pending = Observation(matches: [.bankTitle: 1, .bankBalanceText: 1, .processingIndicator: 1], text: [.bankBalanceText: "101"])
        XCTAssertFalse(BankingVerifier.verified(before: before, after: pending, mode: .bankBalanceIncrease, format: .digitsOnly))
        let uncertain = Observation(matches: [.bankTitle: 1, .bankBalanceText: 0.5], text: [.bankBalanceText: "101"])
        XCTAssertFalse(BankingVerifier.verified(before: before, after: uncertain, mode: .bankBalanceIncrease, format: .digitsOnly))
    }
    private func balance(_ text: String, at offset: Double, processing: Bool = false,
                         confidence: Double = 1) -> Observation {
        var matches: [TargetRole: Double] = [.bankTitle: 1, .bankBalanceText: confidence]
        if processing { matches[.processingIndicator] = 1 }
        return Observation(timestamp: Date().addingTimeInterval(offset), matches: matches,
                           text: [.bankBalanceText: text])
    }

    func testBalanceTrackerRequiresStableBeforeAndAfterReadings() throws {
        var tracker = BankBalanceTracker()
        tracker.observe(balance("1,000", at: -0.8), format: .commaGrouped)
        XCTAssertNil(tracker.reading)
        tracker.observe(balance("1,000", at: -0.6), format: .commaGrouped)
        tracker.observe(balance("1,250", at: -0.4), format: .commaGrouped)
        XCTAssertNil(tracker.reading, "One changed OCR frame must not update the balance")
        tracker.observe(balance("1,250", at: -0.2), format: .commaGrouped)
        let reading = try XCTUnwrap(tracker.reading)
        XCTAssertEqual(reading.balance, 1250)
        XCTAssertEqual(reading.added, 250)
        tracker.observe(Observation(matches: [:]), format: .commaGrouped)
        XCTAssertEqual(tracker.reading, reading, "Closing the bank retains the last stable balance")
    }

    func testBalanceTrackerRejectsPendingLowConfidenceMalformedAndStaleReadings() {
        for bad in [balance("120", at: -0.3, processing: true),
                    balance("120", at: -0.3, confidence: 0.5),
                    balance("Balance 120", at: -0.3), balance("120", at: -5)] {
            var tracker = BankBalanceTracker()
            tracker.observe(balance("100", at: -0.8), format: .digitsOnly)
            tracker.observe(balance("100", at: -0.6), format: .digitsOnly)
            tracker.observe(bad, format: .digitsOnly)
            XCTAssertNil(tracker.reading)
            tracker.observe(balance("120", at: -0.1), format: .digitsOnly)
            XCTAssertNil(tracker.reading, "Bad evidence breaks consecutive agreement")
        }
    }

    func testUnchangedBalanceDoesNotClaimZeroCollected() {
        var tracker = BankBalanceTracker()
        tracker.observe(balance("100", at: -0.4), format: .digitsOnly)
        tracker.observe(balance("100", at: -0.2), format: .digitsOnly)
        XCTAssertEqual(tracker.reading?.balance, 100)
        XCTAssertNil(tracker.reading?.added)
    }

    func testDecreasedBalanceCannotProduceCollectedAmount() {
        var tracker = BankBalanceTracker()
        for (index, text) in ["100", "100", "80", "80"].enumerated() {
            tracker.observe(balance(text, at: -0.8 + Double(index) * 0.2), format: .digitsOnly)
        }
        XCTAssertNil(tracker.reading)
    }

    func testRepeatedSameScreenshotCannotConfirmBalance() {
        var tracker = BankBalanceTracker()
        let frame = balance("100", at: -0.2)
        tracker.observe(frame, format: .digitsOnly)
        tracker.observe(frame, format: .digitsOnly)
        XCTAssertNil(tracker.reading)
    }

}

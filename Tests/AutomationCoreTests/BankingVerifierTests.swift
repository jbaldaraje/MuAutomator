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

    func testNamedJewelsTrackIndependentChangesAndRejectOneUncertainRow() throws {
        let region = try NormalizedRegion(x: 0, y: 0, width: 0.1, height: 0.1)
        let a = NamedBankBalanceTarget(name: "Jewel A", region: region, format: .commaGrouped)
        let b = NamedBankBalanceTarget(name: "Jewel B", region: region)
        let c = NamedBankBalanceTarget(name: "Jewel C", region: region)
        var tracker = NamedBankBalanceTracker()
        for (index, values) in [["1,000", "30"], ["1,000", "30"], ["1,025", "40"], ["1,025", "40"]].enumerated() {
            let frame = Observation(timestamp: Date().addingTimeInterval(-0.8 + Double(index) * 0.2),
                                    matches: [.bankTitle: 1], namedBankBalances: [
                a.id: .init(target: a, text: values[0], confidence: 1),
                b.id: .init(target: b, text: values[1], confidence: 1),
                c.id: .init(target: c, text: "900", confidence: 0.4)
            ])
            tracker.observe(frame)
        }
        XCTAssertEqual(tracker.readings[a.id]?.reading.balance, 1025)
        XCTAssertEqual(tracker.readings[a.id]?.reading.added, 25)
        XCTAssertEqual(tracker.readings[b.id]?.reading.balance, 40)
        XCTAssertEqual(tracker.readings[b.id]?.reading.added, 10)
        XCTAssertNil(tracker.readings[c.id])
        XCTAssertNil(NamedBankBalanceSample(target: a, text: "1,02", confidence: 1).count)
        XCTAssertNil(NamedBankBalanceSample(target: a, text: "1025", confidence: .nan).count)
    }

    func testNamedBalanceDiagnosticsDistinguishBankOCRFormatAndShortVisibility() throws {
        let region = try NormalizedRegion(x: 0, y: 0, width: 0.1, height: 0.1)
        let target = NamedBankBalanceTarget(name: "Jewel of Soul", region: region)
        let noBank = NamedBankBalanceSample(target: target, text: "100", confidence: 1, bankRecognized: false)
        XCTAssertNil(noBank.count, "Diagnostic OCR must not bypass bank recognition")
        XCTAssertEqual(noBank.text, "100")
        XCTAssertTrue(noBank.failureReason?.contains("Bank not recognized") == true)
        let cases: [(NamedBankBalanceSample, String)] = [
            (.init(target: target, text: "", confidence: 0), "No text"),
            (.init(target: target, text: "100", confidence: 0.5), "confidence"),
            (.init(target: target, text: "1,000", confidence: 1), "digitsOnly")
        ]
        for (sample, expected) in cases {
            var tracker = NamedBankBalanceTracker()
            tracker.observe(Observation(matches: [.bankTitle: 1], namedBankBalances: [target.id: sample]))
            XCTAssertTrue(tracker.issues[target.id]?.contains(expected) == true)
            tracker.observe(Observation(matches: [:]))
            XCTAssertTrue(tracker.issues[target.id]?.contains(expected) == true,
                          "Closing the bank must retain the useful failure explanation")
        }
        var tracker = NamedBankBalanceTracker()
        tracker.observe(Observation(matches: [:], namedBankBalances: [target.id: noBank]))
        XCTAssertTrue(tracker.issues[target.id]?.contains("Bank was not recognized") == true)
        tracker.observe(Observation(matches: [.bankTitle: 1], namedBankBalances: [
            target.id: .init(target: target, text: "100", confidence: 1)]))
        XCTAssertTrue(tracker.issues[target.id]?.contains("Only one") == true)
        tracker.observe(Observation(matches: [.bankTitle: 1], namedBankBalances: [
            target.id: .init(target: target, text: "100", confidence: 1)]))
        XCTAssertNil(tracker.issues[target.id])
        XCTAssertEqual(tracker.readings[target.id]?.reading.balance, 100)
    }

    func testPendingAndStaleDiagnosticsTakePriorityOverOldOCRFailure() throws {
        let target = NamedBankBalanceTarget(name: "Jewel of Soul",
            region: try NormalizedRegion(x: 0, y: 0, width: 0.1, height: 0.1))
        var tracker = NamedBankBalanceTracker()
        let bad = NamedBankBalanceSample(target: target, text: "bad", confidence: 1)
        tracker.observe(Observation(matches: [.bankTitle: 1], namedBankBalances: [target.id: bad]))
        tracker.observe(Observation(matches: [.bankTitle: 1, .processingIndicator: 1], namedBankBalances: [target.id: bad]))
        XCTAssertTrue(tracker.issues[target.id]?.contains("processing") == true)
        tracker.observe(Observation(timestamp: Date().addingTimeInterval(-5), matches: [.bankTitle: 1],
                                    namedBankBalances: [target.id: bad]))
        XCTAssertTrue(tracker.issues[target.id]?.contains("too old") == true)
    }

    func testConfirmedJewelBalancesSurviveUnreadableFramesAsBankCloses() throws {
        let target = NamedBankBalanceTarget(name: "Jewel of Soul",
            region: try NormalizedRegion(x: 0, y: 0, width: 0.1, height: 0.1))
        var tracker = NamedBankBalanceTracker()
        for (index, text) in ["100", "100", "125", "125"].enumerated() {
            tracker.observe(Observation(timestamp: Date().addingTimeInterval(-1 + Double(index) * 0.1),
                matches: [.bankTitle: 1], namedBankBalances: [target.id: .init(target: target, text: text, confidence: 1)]))
        }
        let confirmed = try XCTUnwrap(tracker.readings[target.id]?.reading)
        XCTAssertEqual(confirmed.balance, 125)
        XCTAssertEqual(confirmed.added, 25)
        // Closing animation: header is recognized for one frame after numbers vanish.
        tracker.observe(Observation(matches: [.bankTitle: 1], namedBankBalances: [
            target.id: .init(target: target, text: "", confidence: 0)]))
        tracker.observe(Observation(matches: [:], namedBankBalances: [
            target.id: .init(target: target, text: "", confidence: 0, bankRecognized: false)]))
        XCTAssertEqual(tracker.readings[target.id]?.reading, confirmed,
                       "A closing frame must not erase a previously confirmed collection reading")
        XCTAssertTrue(tracker.issues[target.id]?.contains("No text") == true)
    }

}

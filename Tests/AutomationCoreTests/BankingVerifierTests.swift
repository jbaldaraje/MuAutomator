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
}

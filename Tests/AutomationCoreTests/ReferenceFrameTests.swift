import XCTest
@testable import AutomationCore

final class ReferenceFrameTests: XCTestCase {
    func testBankTitleDistinguishesDifferentDialogAndMapList() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "bank-title", withExtension: "json", subdirectory: "Fixtures"))
        let images = try JSONDecoder().decode([String: GrayImage].self, from: Data(contentsOf: url))
        let bank = try XCTUnwrap(images["bank"])
        let later = try XCTUnwrap(images["bankLater"])
        XCTAssertGreaterThan(TemplateMatcher.similarity(bank, later), 0.95, "Bank title should persist across sampled frames")
        for name in ["helper", "warp"] {
            let candidate = try XCTUnwrap(images[name])
            XCTAssertLessThan(TemplateMatcher.similarity(bank, candidate), 0.8, "Other game panels must not count as the bank title")
        }
    }
}

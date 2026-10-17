import XCTest
@testable import AutomationCore

final class OCRTextMatcherTests: XCTestCase {
    func testRelaxedRecognitionPrefersSavedImageWhileNumericProofStillRequiresOCR() {
        XCTAssertEqual(TargetRecognition.score(template: 0.99, ocr: 0, numeric: false, strict: false), 0.99)
        XCTAssertEqual(TargetRecognition.score(template: 0.99, ocr: 0, numeric: false, strict: true), 0)
        XCTAssertEqual(TargetRecognition.score(template: nil, ocr: 0.97, numeric: false, strict: false), 0.97)
        XCTAssertEqual(TargetRecognition.score(template: 0.99, ocr: 0.82, numeric: true, strict: false), 0.82)
        XCTAssertNil(TargetRecognition.score(template: 0.99, ocr: nil, numeric: true, strict: false))
    }

    func testUnrelatedLowConfidenceOCRDoesNotInvalidateMatchingTargetPhrase() {
        let lines = [OCRTextCandidate(text: "Inventory", confidence: 0.99),
                     OCRTextCandidate(text: "noise", confidence: 0.1)]
        XCTAssertEqual(OCRTextMatcher.confidence(for: "INVENTORY", in: lines), 0.99)
        XCTAssertEqual(OCRTextMatcher.confidence(for: "Jewel Bank", in: lines), 0)
    }

    func testMultilinePhraseUsesConfidenceOfOnlyTheRequiredLines() {
        let lines = [OCRTextCandidate(text: "Jewel", confidence: 0.98),
                     OCRTextCandidate(text: "Bank", confidence: 0.92),
                     OCRTextCandidate(text: "noise", confidence: 0.01)]
        XCTAssertEqual(OCRTextMatcher.confidence(for: "Jewel Bank", in: lines), 0.92)
    }

    func testIndependentTargetsDoNotReusePreviousPhraseOrConfidence() {
        let inventory = [OCRTextCandidate(text: "Inventory", confidence: 0.99)]
        let bank = [OCRTextCandidate(text: "Jewel Bank", confidence: 0.97)]
        XCTAssertEqual(OCRTextMatcher.confidence(for: "Inventory", in: inventory), 0.99)
        XCTAssertEqual(OCRTextMatcher.confidence(for: "Inventory", in: bank), 0)
        XCTAssertEqual(OCRTextMatcher.confidence(for: "Jewel Bank", in: bank), 0.97)
        XCTAssertEqual(OCRTextMatcher.confidence(for: "", in: bank), 0)
    }
}

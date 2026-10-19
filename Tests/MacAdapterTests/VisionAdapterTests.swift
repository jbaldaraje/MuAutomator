import XCTest
import AppKit
import Vision
@testable import MUAutomator
import AutomationCore

final class VisionAdapterTests: XCTestCase {
    func testRecoveryPhraseIsReadEvenWhenLiveOptionalOCRIsDisabled() throws {
        let frame = try image("bank")
        let region = try AutomationCore.NormalizedRegion(x: 238.0/640, y: 154.0/412, width: 164.0/640, height: 20.0/412)
        let template = try XCTUnwrap(VisionService.gray(try XCTUnwrap(VisionService.crop(frame, region: region))))
        var profile = CalibrationProfile()
        profile.targets = [.init(role: .deathIndicator, region: region, template: template,
                                 expectedText: "A DEATH PHRASE NOT IN THIS IMAGE")]
        let result = try VisionService.detect(image: frame, profile: profile, timestamp: Date(),
                                             strictRecognition: false, includeOCRDiagnostics: false)
        XCTAssertNotNil(result.text[.deathIndicator])
        XCTAssertFalse(result.has(.deathIndicator), "An unchanged image must not substitute for a missing death phrase")
    }

    func testRelaxedSavedImageEvidenceIsNotBlockedByOldOCRPhrase() throws {
        let frame = try image("bank")
        let region = try AutomationCore.NormalizedRegion(x: 238.0/640, y: 154.0/412, width: 164.0/640, height: 20.0/412)
        let template = try XCTUnwrap(VisionService.gray(try XCTUnwrap(VisionService.crop(frame, region: region))))
        var profile = CalibrationProfile()
        profile.targets = [.init(role: .bankTitle, region: region, template: template,
                                 expectedText: "A PHRASE NOT PRESENT IN THIS IMAGE")]
        XCTAssertFalse(try VisionService.detect(image: frame, profile: profile, timestamp: Date()).has(.bankTitle))
        let relaxed = try VisionService.detect(image: frame, profile: profile, timestamp: Date(),
                                               strictRecognition: false, includeOCRDiagnostics: false)
        XCTAssertTrue(relaxed.has(.bankTitle))
        XCTAssertNil(relaxed.text[.bankTitle], "Live relaxed matching need not OCR a template-backed label")
    }

    @MainActor func testDistinctCroppedLabelsHaveIndependentOCRResults() throws {
        let canvas = NSImage(size: NSSize(width: 1000, height: 160))
        canvas.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1000, height: 160)).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 40),
                                                       .foregroundColor: NSColor.black]
        ("INVENTORY" as NSString).draw(at: NSPoint(x: 20, y: 50), withAttributes: attributes)
        ("JEWEL BANK" as NSString).draw(at: NSPoint(x: 520, y: 50), withAttributes: attributes)
        canvas.unlockFocus()
        let frame = try XCTUnwrap(canvas.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var profile = CalibrationProfile()
        profile.targets = [
            .init(role: .inventoryPanel, region: try AutomationCore.NormalizedRegion(x: 0, y: 0, width: 0.5, height: 1),
                  expectedText: "INVENTORY", threshold: 0.8),
            .init(role: .bankTitle, region: try AutomationCore.NormalizedRegion(x: 0.5, y: 0, width: 0.5, height: 1),
                  expectedText: "JEWEL BANK", threshold: 0.8)
        ]
        let result = try VisionService.detect(image: frame, profile: profile, timestamp: Date())
        let inventory = (result.text[.inventoryPanel] ?? "").uppercased()
        let bank = (result.text[.bankTitle] ?? "").uppercased()
        XCTAssertTrue(inventory.contains("INVENTORY"))
        XCTAssertFalse(inventory.contains("BANK"))
        XCTAssertTrue(bank.contains("JEWEL BANK"))
        XCTAssertFalse(bank.contains("INVENTORY"))
        XCTAssertTrue(result.has(.inventoryPanel))
        XCTAssertTrue(result.has(.bankTitle))
    }

    @MainActor func testRelaxedControlsAcceptSavedRectanglesWhileStrictRequiresRecognitionEvidence() throws {
        var profile = CalibrationProfile()
        profile.targets = [.init(role: .inventoryControl,
                                 region: try AutomationCore.NormalizedRegion(x: 0.1, y: 0.1, width: 0.1, height: 0.1))]
        XCTAssertNoThrow(try MacWorkflowIO.requireTargets([.inventoryControl], in: profile, strictGameplayRecognition: false))
        XCTAssertThrowsError(try MacWorkflowIO.requireTargets([.inventoryControl], in: profile, strictGameplayRecognition: true))
    }

    @MainActor func testNamedJewelNumberRegionsProduceIndependentLiveOCRSamples() throws {
        let canvas = NSImage(size: NSSize(width: 1000, height: 160))
        canvas.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1000, height: 160)).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 48),
                                                       .foregroundColor: NSColor.black]
        ("1000" as NSString).draw(at: NSPoint(x: 20, y: 50), withAttributes: attributes)
        ("2500" as NSString).draw(at: NSPoint(x: 520, y: 50), withAttributes: attributes)
        canvas.unlockFocus()
        let frame = try XCTUnwrap(canvas.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let left = try AutomationCore.NormalizedRegion(x: 0, y: 0, width: 0.5, height: 1)
        let right = try AutomationCore.NormalizedRegion(x: 0.5, y: 0, width: 0.5, height: 1)
        var profile = CalibrationProfile()
        // Reuse the left text as this synthetic frame's bank-presence evidence.
        profile.targets = [.init(role: .bankTitle, region: left, expectedText: "1000", threshold: 0.8)]
        let soul = NamedBankBalanceTarget(name: "Jewel of Soul", region: left, threshold: 0.8)
        let creation = NamedBankBalanceTarget(name: "Jewel of Creation", region: right, threshold: 0.8)
        profile.namedBankBalances = [soul, creation]
        let result = try VisionService.detect(image: frame, profile: profile, timestamp: Date(),
                                             strictRecognition: false, includeOCRDiagnostics: false)
        XCTAssertEqual(result.namedBankBalances[soul.id]?.count, 1000)
        XCTAssertEqual(result.namedBankBalances[creation.id]?.count, 2500)
        profile.targets = []
        let closed = try VisionService.detect(image: frame, profile: profile, timestamp: Date())
        XCTAssertNil(closed.namedBankBalances[soul.id]?.count, "Numbers outside a recognized bank must not update balances")
    }

    private func image(_ name: String) throws -> CGImage {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures"))
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        return try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    func testReferenceFrameBankDetectionAndOtherDialogRejection() throws {
        let bank = try image("bank")
        let region = try AutomationCore.NormalizedRegion(x: 238.0/640, y: 154.0/412, width: 164.0/640, height: 20.0/412)
        let crop = try XCTUnwrap(VisionService.crop(bank, region: region))
        let template = try XCTUnwrap(VisionService.gray(crop))
        var profile = CalibrationProfile()
        profile.targets = [.init(role: .bankTitle, region: region, template: template)]
        XCTAssertTrue(try VisionService.detect(image: bank, profile: profile, timestamp: Date()).has(.bankTitle))
        for name in ["helper", "warp"] {
            XCTAssertFalse(try VisionService.detect(image: image(name), profile: profile, timestamp: Date()).has(.bankTitle))
        }
    }

    @MainActor func testTransferWithdrawOverlapFailsPreflight() async throws {
        let region = try AutomationCore.NormalizedRegion(x: 0.2, y: 0.2, width: 0.2, height: 0.2)
        let template = GrayImage(width: 2, height: 2, pixels: [0,255,0,255])
        var profile = CalibrationProfile()
        profile.targets = [
            .init(role: .transferButton, region: region, template: template),
            .init(role: .withdrawExcluded, region: region, template: template)
        ]
        XCTAssertThrowsError(try MacWorkflowIO.requireTargets([.transferButton, .withdrawExcluded], in: profile))
    }
}

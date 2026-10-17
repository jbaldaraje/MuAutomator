import XCTest
import AppKit
@testable import MUAutomator
import AutomationCore

final class VisionAdapterTests: XCTestCase {
    private func image(_ name: String) throws -> CGImage {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures"))
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        return try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    func testReferenceFrameBankDetectionAndOtherDialogRejection() throws {
        let bank = try image("bank")
        let region = try NormalizedRegion(x: 238.0/640, y: 154.0/412, width: 164.0/640, height: 20.0/412)
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
        let region = try NormalizedRegion(x: 0.2, y: 0.2, width: 0.2, height: 0.2)
        let template = GrayImage(width: 2, height: 2, pixels: [0,255,0,255])
        var profile = CalibrationProfile()
        profile.targets = [
            .init(role: .transferButton, region: region, template: template),
            .init(role: .withdrawExcluded, region: region, template: template)
        ]
        XCTAssertThrowsError(try MacWorkflowIO.requireTargets([.transferButton, .withdrawExcluded], in: profile))
    }
}

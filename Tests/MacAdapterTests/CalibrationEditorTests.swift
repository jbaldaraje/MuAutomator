import XCTest
import AutomationCore
@testable import MUAutomator

final class CalibrationEditorTests: XCTestCase {
    @MainActor func testEditingExistingTargetPersistsWithoutRedrawingAndDoesNotChangeOtherTarget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try fixture(in: directory)
        let model = CaptureModel(profileURL: url)
        model.role = .inventoryControl
        let originalRegion = model.profile.targets.first { $0.role == .inventoryControl }?.region
        model.expectedText = "Inventory edited"
        model.threshold = 0.87
        model.save()

        let reloaded = CaptureModel(profileURL: url)
        reloaded.role = .inventoryControl
        XCTAssertEqual(reloaded.expectedText, "Inventory edited")
        XCTAssertEqual(reloaded.threshold, 0.87)
        XCTAssertEqual(reloaded.profile.targets.first { $0.role == .inventoryControl }?.region, originalRegion)
        reloaded.role = .bankControl
        XCTAssertEqual(reloaded.expectedText, "Bank original")
        XCTAssertEqual(reloaded.threshold, 0.92)
    }

    @MainActor func testSwitchingTargetsLoadsIndependentSettingsAndNewTargetStartsEmpty() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = CaptureModel(profileURL: try fixture(in: directory))
        model.role = .inventoryControl
        XCTAssertEqual(model.expectedText, "Inventory original")
        model.expectedText = "Inventory edited"
        model.role = .bankControl
        XCTAssertEqual(model.expectedText, "Bank original")
        model.expectedText = "Bank edited"
        model.role = .helperControl
        XCTAssertEqual(model.expectedText, "")
        XCTAssertEqual(model.threshold, 0.95)
        model.role = .inventoryControl
        XCTAssertEqual(model.expectedText, "Inventory edited")
        model.role = .bankControl
        XCTAssertEqual(model.expectedText, "Bank edited")
    }

    @MainActor func testNamedProfileReloadAndClearRefreshCurrentTargetSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = CaptureModel(profileURL: try fixture(in: directory))
        model.role = .inventoryControl; model.expectedText = "Named profile text"
        model.profileName = "Custom"; model.saveNamedProfile()
        model.expectedText = "Unsaved edit"
        model.loadNamedProfile()
        XCTAssertEqual(model.expectedText, "Named profile text")
        model.clear()
        XCTAssertEqual(model.expectedText, "")
        XCTAssertEqual(model.threshold, 0.95)
        XCTAssertTrue(model.profile.targets.isEmpty)
        XCTAssertNil(model.detection)
    }

    private func fixture(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("calibration.json")
        var profile = CalibrationProfile()
        let first = try NormalizedRegion(x: 0.1, y: 0.1, width: 0.1, height: 0.1)
        let second = try NormalizedRegion(x: 0.5, y: 0.1, width: 0.1, height: 0.1)
        profile.targets = [
            .init(role: .inventoryControl, region: first, expectedText: "Inventory original", threshold: 0.91),
            .init(role: .bankControl, region: second, expectedText: "Bank original", threshold: 0.92)
        ]
        try JSONEncoder().encode(profile).write(to: url)
        return url
    }
}

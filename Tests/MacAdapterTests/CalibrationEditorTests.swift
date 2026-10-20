import XCTest
import AutomationCore
@testable import MUAutomator

final class CalibrationEditorTests: XCTestCase {
    @MainActor func testCursorPositionChangesOnlySelectedClickAndPersists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try fixture(in: directory)
        var profile = try JSONDecoder().decode(CalibrationProfile.self, from: Data(contentsOf: url))
        profile.targets.append(.init(role: .gameViewport, region: try NormalizedRegion(x: 0, y: 0, width: 1, height: 1)))
        try JSONEncoder().encode(profile).write(to: url)
        let model = CaptureModel(profileURL: url); model.role = .inventoryControl
        let original = model.profile.targets[0]
        try model.setClickPoint(CalibratedClickPoint(x: 0.7, y: 0.8)); model.save()
        let reloaded = CaptureModel(profileURL: url)
        XCTAssertEqual(reloaded.profile.targets[0].clickPoint, try CalibratedClickPoint(x: 0.7, y: 0.8))
        XCTAssertEqual(reloaded.profile.targets[0].region, original.region)
        XCTAssertEqual(reloaded.profile.targets[0].expectedText, original.expectedText)
        XCTAssertNil(reloaded.profile.targets[1].clickPoint)
        try model.setClickPoint(nil)
        XCTAssertNil(model.profile.targets[0].clickPoint)
    }

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

    @MainActor func testOCROnlySelectionPersistsAndPreservesOtherCalibration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try fixture(in: directory)
        var profile = try JSONDecoder().decode(CalibrationProfile.self, from: Data(contentsOf: url))
        let region = try NormalizedRegion(x: 0.3, y: 0.2, width: 0.1, height: 0.1)
        let template = GrayImage(width: 2, height: 2, pixels: [0, 255, 0, 255])
        profile.targets.append(.init(role: .bankTitle, region: region, template: template,
                                     expectedText: "Jewel bank", threshold: 0.95))
        profile.namedBankBalances = [.init(name: "Jewel of Soul", region: region, format: .commaGrouped)]
        try JSONEncoder().encode(profile).write(to: url)
        let model = CaptureModel(profileURL: url); model.role = .bankTitle
        model.useOCROnly(); model.save()
        let loaded = CaptureModel(profileURL: url).profile
        let header = try XCTUnwrap(loaded.targets.first { $0.role == .bankTitle })
        XCTAssertNil(header.template)
        XCTAssertEqual(header.expectedText, "Jewel bank")
        XCTAssertEqual(header.threshold, 0.95)
        XCTAssertEqual(header.region, region)
        XCTAssertEqual(loaded.targets[0].expectedText, profile.targets[0].expectedText)
        XCTAssertEqual(loaded.targets[0].region, profile.targets[0].region)
        XCTAssertEqual(loaded.namedBankBalances.map(\.id), profile.namedBankBalances.map(\.id))
    }

    @MainActor func testOCROnlyCannotRemoveTemplateWithoutAPhrase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try fixture(in: directory)
        var profile = try JSONDecoder().decode(CalibrationProfile.self, from: Data(contentsOf: url))
        profile.targets[0].expectedText = nil
        profile.targets[0].template = GrayImage(width: 2, height: 2, pixels: [0, 255, 0, 255])
        try JSONEncoder().encode(profile).write(to: url)
        let model = CaptureModel(profileURL: url); model.role = .inventoryControl
        model.useOCROnly()
        XCTAssertNotNil(model.profile.targets[0].template)
        XCTAssertTrue(model.message.contains("enter its fixed OCR phrase"))
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

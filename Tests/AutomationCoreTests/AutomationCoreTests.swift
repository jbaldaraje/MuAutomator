import XCTest
@testable import AutomationCore

final class AutomationCoreTests: XCTestCase {
    func testExistingSettingsDefaultToRelaxedRecognitionAndPreserveOptions() throws {
        let legacy = Data(#"{"schemaVersion":1,"mode":"fullAutomation","dryRun":false,"helperEnabled":false,"recoveryEnabled":true,"skillsEnabled":true,"actionTimeoutSeconds":25,"maximumRetries":1}"#.utf8)
        var config = try JSONDecoder().decode(AutomationConfiguration.self, from: legacy)
        XCTAssertFalse(config.strictGameplayRecognition)
        XCTAssertEqual(config.mode, .fullAutomation)
        XCTAssertFalse(config.dryRun)
        XCTAssertFalse(config.helperEnabled)
        XCTAssertTrue(config.recoveryEnabled)
        XCTAssertTrue(config.skillsEnabled)
        XCTAssertEqual(config.actionTimeoutSeconds, 25)
        XCTAssertEqual(config.maximumRetries, 1)
        config.strictGameplayRecognition = true
        let decoded = try JSONDecoder().decode(AutomationConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded, config)
    }

    func testPersistenceAndValidation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("configuration.json"))
        XCTAssertEqual(try store.load().mode, .jewelsOnly)
        var config = AutomationConfiguration()
        config.mode = .fullAutomation
        try store.save(config)
        XCTAssertEqual(try store.load(), config)
        config.maximumRetries = -1
        XCTAssertThrowsError(try store.save(config))
        config.maximumRetries = 2
        config.schemaVersion = 99
        XCTAssertThrowsError(try store.save(config))
    }
}

import XCTest
@testable import AutomationCore

final class AutomationCoreTests: XCTestCase {
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

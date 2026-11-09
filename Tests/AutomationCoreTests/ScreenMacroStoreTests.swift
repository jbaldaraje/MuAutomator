import XCTest
@testable import AutomationCore

final class ScreenMacroStoreTests: XCTestCase {
    private func withStore(_ body: (ScreenMacroStore) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try body(ScreenMacroStore(directory: url))
    }
    func testRecordingsAndDecimalHoursPersist() throws {
        try withStore { store in
            XCTAssertNil(try store.load())
            let macro = ScreenMacro(layout: .init(displays: [.init(x: 0, y: 0, width: 100, height: 100)]),
                                    events: [.init(time: 0, action: .move(.init(x: 20, y: 30)))], duration: 0.5)
            try store.save(macro); try store.saveSettings(.init(hours: 0.5))
            XCTAssertEqual(try store.load(), macro)
            XCTAssertEqual(try store.loadSettings().hours, 0.5)
            var invalid = macro; invalid.duration = -1
            XCTAssertThrowsError(try store.save(invalid))
            XCTAssertEqual(try store.load(), macro)
            XCTAssertThrowsError(try store.saveSettings(.init(hours: .nan)))
            XCTAssertEqual(try store.loadSettings().hours, 0.5)
        }
    }
    func testOldHoursAreRetainedWithoutReinterpretingOrModifyingWindowRecordings() throws {
        try withStore { store in
            let old = store.directory.appendingPathComponent("workflow.json")
            let data = Data(#"{"macroRepeat":{"durationSeconds":7200},"bankingRecording":{"windowWidth":1000}}"#.utf8)
            try data.write(to: old)
            XCTAssertEqual(try store.loadSettings().hours, 2)
            XCTAssertNil(try store.load())
            XCTAssertEqual(try Data(contentsOf: old), data)
            let profiles = store.directory.appendingPathComponent("window-macros.json")
            let calibration = store.directory.appendingPathComponent("calibration.json")
            let previous = Data("old profile data".utf8)
            try previous.write(to: profiles); try previous.write(to: calibration)
            let macro = ScreenMacro(layout: .init(displays: [.init(x: 0, y: 0, width: 100, height: 100)]),
                                    events: [.init(time: 0, action: .move(.init(x: 10, y: 10)))], duration: 1)
            try store.save(macro)
            try store.saveSettings(.init(hours: 0.25))
            XCTAssertEqual(try Data(contentsOf: profiles), previous)
            XCTAssertEqual(try Data(contentsOf: calibration), previous)
            XCTAssertEqual(try store.loadSettings().hours, 0.25)
            XCTAssertEqual(try Data(contentsOf: old), data)
        }
    }
    func testCorruptRecordingReportsFailureWithoutDeletingIt() throws {
        try withStore { store in
            let data = Data("not a macro".utf8); try data.write(to: store.recordingURL)
            XCTAssertThrowsError(try store.load())
            XCTAssertEqual(try Data(contentsOf: store.recordingURL), data)
        }
    }
    func testInvalidOldHoursFallBackToOneHour() throws {
        try withStore { store in
            try Data(#"{"macroRepeat":{"durationSeconds":-1}}"#.utf8).write(to: store.directory.appendingPathComponent("workflow.json"))
            XCTAssertEqual(try store.loadSettings().hours, 1)
        }
    }
    func testRepeatIntervalPersistsAndHoursOnlySettingsRemainCompatible() throws {
        try withStore { store in
            let settingsFile = store.directory.appendingPathComponent("screen-macro-settings.json")
            try Data(#"{"hours":0.5}"#.utf8).write(to: settingsFile)
            let legacy = try store.loadSettings()
            XCTAssertEqual(legacy.hours, 0.5)
            XCTAssertEqual(legacy.intervalSeconds, 0)
            try store.saveSettings(.init(hours: 2, intervalSeconds: 60.5))
            XCTAssertEqual(try store.loadSettings(), .init(hours: 2, intervalSeconds: 60.5))
            for interval in [-1, Double.nan, .infinity, 86400.1] {
                XCTAssertThrowsError(try store.saveSettings(.init(hours: 2, intervalSeconds: interval)))
            }
            XCTAssertEqual(try store.loadSettings().intervalSeconds, 60.5)
        }
    }

}

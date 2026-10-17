import XCTest
@testable import AutomationCore

final class InputRecordingTests: XCTestCase {
    func testRecordingTimingAndWindowSizeRoundTripWithSettings() throws {
        var recording = InputRecording(windowWidth: 1024, windowHeight: 768)
        recording.steps = [.init(action: .point(x: 0.1, y: 0.2), delayBeforeSeconds: 1.5, holdSeconds: 0.15),
                           .init(action: .key(12), delayBeforeSeconds: 2, holdSeconds: 1.2)]
        recording.tailDelaySeconds = 3
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        settings.bankingRecording = recording; settings.route.recording = recording
        let loaded = try JSONDecoder().decode(WorkflowSettings.self, from: JSONEncoder().encode(settings))
        try loaded.validate()
        XCTAssertEqual(loaded.bankingInputMode, .recordedInput)
        XCTAssertEqual(loaded.bankingRecording, recording)
        XCTAssertEqual(loaded.route.recording, recording)
        XCTAssertTrue(loaded.route.hasActions)
        XCTAssertEqual(recording.duration, 7.85, accuracy: 0.0001)
        XCTAssertTrue(recording.matchesWindow(width: 1024, height: 768))
        XCTAssertFalse(recording.matchesWindow(width: 1280, height: 960), "Same aspect ratio is insufficient for recorded coordinates")
    }

    func testLegacySettingsKeepImageWorkflowAndCheckpointRoute() throws {
        let settings = try JSONDecoder().decode(WorkflowSettings.self, from: Data(#"{"route":{"name":"Old route","steps":[],"validated":false}}"#.utf8))
        XCTAssertEqual(settings.bankingInputMode, .visualWorkflow)
        XCTAssertNil(settings.bankingRecording)
        XCTAssertNil(settings.route.recording)
        try settings.validate()
    }

    func testRecordingRejectsInvalidCoordinatesHoldsDelaysAndLabelClicks() throws {
        var recording = InputRecording(windowWidth: 1000, windowHeight: 800)
        for step in [RecordedInputStep(action: .point(x: 1.2, y: 0.5)),
                     .init(action: .key(128)), .init(action: .key(12), delayBeforeSeconds: -.infinity),
                     .init(action: .key(12), holdSeconds: .nan), .init(action: .key(12), holdSeconds: 31),
                     .init(action: .click(.transferButton))] {
            recording.steps = [step]
            XCTAssertThrowsError(try recording.validate())
        }
    }

    func testRecordedBankNeedsNoImagesAndRecordedRecoveryRetainsDeathSpawnDestination() {
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        var config = AutomationConfiguration(); config.helperEnabled = false
        XCTAssertTrue(CalibrationRequirements.roles(configuration: config, settings: settings).isEmpty)
        config.mode = .fullAutomation; config.recoveryEnabled = true
        settings.route.recording = InputRecording(windowWidth: 1000, windowHeight: 800)
        XCTAssertEqual(CalibrationRequirements.roles(configuration: config, settings: settings),
                       [.deathIndicator, .deathConfirmation, .respawnIndicator, .destinationLandmark])
    }

    func testRecoveryOCRCannotBeOverriddenByAnUnchangedImageInRelaxedMode() {
        XCTAssertTrue(TargetRole.deathIndicator.isRecoveryEvidence)
        XCTAssertTrue(TargetRole.respawnIndicator.isRecoveryEvidence)
        XCTAssertFalse(TargetRole.inventoryPanel.isRecoveryEvidence)
        XCTAssertEqual(TargetRecognition.score(template: 1, ocr: 0, numeric: false, strict: false, preferOCR: true), 0)
        XCTAssertEqual(TargetRecognition.score(template: 0, ocr: 0.99, numeric: false, strict: false, preferOCR: true), 0.99)
    }
}

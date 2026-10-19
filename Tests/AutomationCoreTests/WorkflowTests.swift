import XCTest
@testable import AutomationCore

@MainActor
private final class FakeIO: WorkflowIO {
    var frames: [[TargetRole]] = []
    var actions: [GameAction] = []
    var unsafe = false
    var focused = true
    var focusLossBeforePress = false
    var focusLossAfterPress = false
    var observationCount = 0
    var resumeChecks = 0
    var refocusAttempts = 0
    var refocusFailuresRemaining = 0
    var onRefocus: (() -> Void)?
    var onObservation: (() -> Void)?
    var texts: [TargetRole: String] = [:]
    var scores: [TargetRole: Double] = [:]
    var recordedSteps: [RecordedInputStep] = []
    var configuredTargets: Set<TargetRole> = []
    var onAction: ((GameAction) -> Void)?
    func checkSafety() throws {
        if unsafe { throw WorkflowFailure.unsafe("Window closed or permissions unavailable") }
        if !focused { throw WorkflowFailure.focusUnavailable("Another window has focus") }
    }
    func hasCalibratedTarget(_ role: TargetRole) -> Bool { configuredTargets.contains(role) }
    func observe() async throws -> Observation {
        try checkSafety()
        let roles = frames.count > 1 ? frames.removeFirst() : (frames.first ?? [])
        observationCount += 1
        let value = Observation(matches: Dictionary(uniqueKeysWithValues: roles.map { ($0, 0.99) }), text: texts, scores: scores)
        onObservation?()
        return value
    }
    func perform(_ action: GameAction) async throws {
        try Task.checkCancellation(); try checkSafety()
        if focusLossBeforePress {
            focusLossBeforePress = false; focused = false
            throw WorkflowFailure.focusUnavailable("Focus changed before the press")
        }
        actions.append(action); onAction?(action)
        if focusLossAfterPress {
            focusLossAfterPress = false; focused = false
            throw WorkflowFailure.focusLostAfterInput("Focus changed during a delivered press")
        }
    }
    func performRecorded(_ step: RecordedInputStep) async throws {
        recordedSteps.append(step)
        try await perform(step.action)
    }
    func prepareToResumeAfterFocus() async throws { try checkSafety(); resumeChecks += 1 }
    func refocusSelectedWindow() async throws {
        try Task.checkCancellation()
        refocusAttempts += 1
        if refocusFailuresRemaining > 0 {
            refocusFailuresRemaining -= 1
            throw WorkflowFailure.focusUnavailable("Game cannot regain focus yet")
        }
        focused = true; try checkSafety(); onRefocus?()
    }
}

final class WorkflowTests: XCTestCase {
    func testAutoRefocusSettingsPreserveLegacyDefaultsAndCustomInterval() throws {
        let legacy = try JSONDecoder().decode(WorkflowSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(legacy.autoRefocus.enabled)
        XCTAssertEqual(legacy.autoRefocus.delaySeconds, 1800)
        var settings = legacy; settings.autoRefocus.enabled = true; settings.autoRefocus.delaySeconds = 3600
        let decoded = try JSONDecoder().decode(WorkflowSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.autoRefocus, settings.autoRefocus)
        for invalid in [0, -1, Double.infinity, Double.nan, 31_536_001] {
            settings.autoRefocus.delaySeconds = invalid
            XCTAssertThrowsError(try settings.validate())
        }
    }

    @MainActor func testAutoRefocusResumesWaitingMacroWithoutRestartingDeliveredInputs() async throws {
        let io = FakeIO(); io.frames = [[]]
        io.onAction = { _ in if io.actions.count == 1 { io.focused = false } }
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        settings.bankingRecording = recording([.key(12), .key(13)])
        settings.autoRefocus.enabled = true; settings.autoRefocus.delaySeconds = 0.05
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await waitForFocusWait(runner)
        XCTAssertEqual(io.actions, [.key(12)])
        try await finish(runner)
        XCTAssertGreaterThan(io.refocusAttempts, 0)
        XCTAssertEqual(io.actions, [.key(12), .key(13)])
        XCTAssertEqual(runner.stage, .completed)
        let attempts = io.refocusAttempts
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(io.refocusAttempts, attempts, "Completed sessions must not be restarted")
    }

    @MainActor func testEnabledAutoRefocusResumesManualPause() async throws {
        let io = FakeIO(); io.frames = [[]]
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        settings.bankingRecording = recording([.key(12)])
        settings.autoRefocus.enabled = true; settings.autoRefocus.delaySeconds = 0.05
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        runner.pause(); io.focused = false
        XCTAssertTrue(io.actions.isEmpty)
        try await finish(runner)
        XCTAssertGreaterThan(io.refocusAttempts, 0)
        XCTAssertEqual(io.actions, [.key(12)])
        XCTAssertEqual(runner.stage, .completed)
    }

    @MainActor func testAutoRefocusRetriesTemporaryFailureWithoutDeliveringInputElsewhere() async throws {
        let io = FakeIO(); io.frames = [[]]; io.focused = false; io.refocusFailuresRemaining = 1
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        settings.bankingRecording = recording([.key(12)])
        settings.autoRefocus.enabled = true; settings.autoRefocus.delaySeconds = 0.05
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await waitUntil { io.refocusAttempts == 1 }
        XCTAssertTrue(io.actions.isEmpty)
        XCTAssertTrue(runner.active)
        try await finish(runner)
        XCTAssertGreaterThanOrEqual(io.refocusAttempts, 2)
        XCTAssertEqual(io.actions, [.key(12)])
        XCTAssertEqual(runner.stage, .completed)
    }

    @MainActor func testAutoRefocusRechecksGameEvidenceBeforeContinuing() async throws {
        let io = FakeIO(); io.frames = [[]]; io.focused = false
        io.onRefocus = { io.frames = [[.deathIndicator]] }
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        settings.bankingRecording = recording([.key(12)])
        settings.autoRefocus.enabled = true; settings.autoRefocus.delaySeconds = 0.05
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertGreaterThan(io.refocusAttempts, 0)
        XCTAssertTrue(io.actions.isEmpty)
        XCTAssertEqual(runner.stage, .waitingForManualIntervention)
    }

    @MainActor func testEmergencyStopCancelsPendingAutoRefocus() async throws {
        let io = FakeIO(); io.frames = [[]]; io.focused = false
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        settings.bankingRecording = recording([.key(12)])
        settings.autoRefocus.enabled = true; settings.autoRefocus.delaySeconds = 0.2
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await waitForFocusWait(runner)
        runner.stop(); try await finish(runner)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(io.refocusAttempts, 0)
        XCTAssertTrue(io.actions.isEmpty)
        XCTAssertEqual(runner.stage, .cancelled)
    }

    @MainActor func testAutoRefocusAlsoRunsDuringIdleMonitoring() async throws {
        let io = FakeIO(); io.frames = [[]]
        var settings = WorkflowSettings(); settings.bankingEnabled = false; settings.pollSeconds = 0.01
        settings.autoRefocus.enabled = true; settings.autoRefocus.delaySeconds = 0.05
        var config = AutomationConfiguration(); config.dryRun = false
        config.mode = .fullAutomation; config.helperEnabled = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await waitUntil { io.refocusAttempts > 0 }
        XCTAssertTrue(runner.active)
        XCTAssertTrue(io.actions.isEmpty)
        runner.stop(); try await finish(runner)
        XCTAssertEqual(runner.stage, .cancelled)
    }

    @MainActor func testVisualTransferFocusWaitFreezesVerificationAndDoesNotRepeatTransfer() async throws {
        let io = FakeIO(); configureBankingWithoutGameplay(io)
        let original = io.onAction
        io.onAction = { action in
            original?(action)
            if action == .click(.transferButton) { io.focused = false }
        }
        var settings = WorkflowSettings(); settings.actionTimeoutSeconds = 0.1; settings.pollSeconds = 0.01
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await waitForFocusWait(runner)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(io.actions.filter { $0 == .click(.transferButton) }.count, 1)
        io.focused = true
        try await finish(runner)
        XCTAssertEqual(runner.stage, .completed)
        XCTAssertEqual(io.actions.filter { $0 == .click(.transferButton) }.count, 1)
    }

    @MainActor func testDeliveredVisualTransferIsVerifiedAfterFocusReturnsWithoutRetry() async throws {
        let io = FakeIO(); configureBankingWithoutGameplay(io)
        let original = io.onAction
        io.onAction = { action in
            original?(action)
            if action == .click(.transferButton) { io.focusLossAfterPress = true }
        }
        var settings = WorkflowSettings(); settings.actionTimeoutSeconds = 0.1; settings.pollSeconds = 0.01
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await waitForFocusWait(runner)
        io.focused = true
        try await finish(runner)
        XCTAssertEqual(runner.stage, .completed)
        XCTAssertEqual(io.actions.filter { $0 == .click(.transferButton) }.count, 1)
    }

    @MainActor func testRecordedReturnRouteTimeoutExcludesFocusWait() async throws {
        let io = FakeIO(); io.frames = [[.respawnIndicator]]
        io.onAction = { _ in
            if io.actions.count == 1 { io.focused = false }
            else { io.frames = [[.destinationLandmark]] }
        }
        var settings = WorkflowSettings(); settings.bankingEnabled = false; settings.routeTimeoutSeconds = 0.1
        settings.route.recording = recording([.key(12), .key(13)])
        var config = AutomationConfiguration(); config.dryRun = false; config.mode = .fullAutomation
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io, routeTest: true)
        try await waitForFocusWait(runner)
        try await Task.sleep(nanoseconds: 200_000_000)
        io.focused = true
        try await finish(runner)
        XCTAssertEqual(io.actions, [.key(12), .key(13)])
        XCTAssertEqual(runner.stage, .completed)
        XCTAssertEqual(runner.lastVerifiedAction, "farming destination")
    }

    @MainActor private func waitForFocusWait(_ runner: AutomationCoordinator) async throws {
        let until = Date().addingTimeInterval(1)
        while runner.active && !runner.isWaitingForFocus && Date() < until {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(runner.isWaitingForFocus)
    }

    @MainActor func testFocusLossKeepsSessionAliveAndResumesPendingMacroInput() async throws {
        let io = FakeIO(); io.frames = [[]]; io.focused = false
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        settings.bankingRecording = recording([.key(12), .key(13)])
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await waitForFocusWait(runner)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(runner.active)
        XCTAssertEqual(runner.stage, .waitingForFocus)
        XCTAssertTrue(io.actions.isEmpty)
        XCTAssertNil(runner.lastError)
        XCTAssertEqual(io.refocusAttempts, 0, "Disabled auto-refocus must leave the foreground app alone")
        io.focused = true
        try await finish(runner)
        XCTAssertEqual(io.actions, [.key(12), .key(13)])
        XCTAssertEqual(runner.stage, .completed)
        XCTAssertGreaterThan(io.resumeChecks, 0)
    }

    @MainActor func testFocusLossBetweenStepsDoesNotReplayDeliveredStepOrConsumeSessionTime() async throws {
        let io = FakeIO(); io.frames = [[]]
        io.onAction = { _ in if io.actions.count == 1 { io.focused = false } }
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        settings.workflowTimeoutSeconds = 1
        settings.bankingRecording = recording([.key(12), .key(13)])
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await waitForFocusWait(runner)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(io.actions, [.key(12)])
        io.focused = true
        try await finish(runner)
        XCTAssertEqual(io.actions, [.key(12), .key(13)])
        XCTAssertEqual(runner.stage, .completed)
    }

    @MainActor func testFocusChangeBeforePressRetriesOnlyUnsentInput() async throws {
        let io = FakeIO(); io.frames = [[]]; io.focusLossBeforePress = true
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        settings.bankingRecording = recording([.key(12)])
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await waitForFocusWait(runner)
        XCTAssertTrue(io.actions.isEmpty)
        io.focused = true
        try await finish(runner)
        XCTAssertEqual(io.actions, [.key(12)])
        XCTAssertEqual(runner.stage, .completed)
    }

    @MainActor func testFocusLossDuringDeliveredPressNeverRepeatsThatPress() async throws {
        let io = FakeIO(); io.frames = [[]]; io.focusLossAfterPress = true
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        settings.bankingRecording = recording([.point(x: 0.3, y: 0.4), .key(13)])
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await waitForFocusWait(runner)
        XCTAssertEqual(io.actions, [.point(x: 0.3, y: 0.4)])
        io.focused = true
        try await finish(runner)
        XCTAssertEqual(io.actions, [.point(x: 0.3, y: 0.4), .key(13)])
        XCTAssertEqual(runner.stage, .completed)
    }

    @MainActor func testManualPauseWhileWaitingDoesNotAutoResumeOnFocusReturn() async throws {
        let io = FakeIO(); io.frames = [[]]; io.focused = false
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        settings.bankingRecording = recording([.key(12)])
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await waitForFocusWait(runner)
        runner.pause(); io.focused = true
        let until = Date().addingTimeInterval(1)
        while runner.isWaitingForFocus && Date() < until { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(runner.stage, .paused)
        XCTAssertTrue(io.actions.isEmpty)
        try runner.resume(); try await finish(runner)
        XCTAssertEqual(io.actions, [.key(12)])
        XCTAssertEqual(runner.stage, .completed)
    }

    @MainActor func testFocusWaitCanBeCancelledWithoutRestoringGameFocus() async throws {
        let io = FakeIO(); io.frames = [[]]; io.focused = false
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        settings.bankingRecording = recording([.key(12)])
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await waitForFocusWait(runner)
        runner.stop(); try await finish(runner)
        XCTAssertEqual(runner.stage, .cancelled)
        XCTAssertFalse(runner.isWaitingForFocus)
        XCTAssertTrue(io.actions.isEmpty)
    }

    @MainActor func testPermanentFailureWhileWaitingStillStopsSession() async throws {
        let io = FakeIO(); io.frames = [[]]; io.focused = false
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        settings.bankingRecording = recording([.key(12)])
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await waitForFocusWait(runner)
        io.unsafe = true
        try await finish(runner)
        XCTAssertEqual(runner.stage, .waitingForManualIntervention)
        XCTAssertTrue(io.actions.isEmpty)
    }

    @MainActor func testFrameCapturedBeforeFocusWaitIsDiscardedBeforeInput() async throws {
        let io = FakeIO(); io.frames = [[]]
        io.onObservation = {
            if io.observationCount == 1 { io.focused = false; io.frames = [[.deathIndicator]] }
        }
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        settings.bankingRecording = recording([.key(12)])
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await waitForFocusWait(runner)
        io.focused = true
        try await finish(runner)
        XCTAssertGreaterThanOrEqual(io.observationCount, 2)
        XCTAssertTrue(io.actions.isEmpty)
        XCTAssertEqual(runner.stage, .waitingForManualIntervention)
    }

    @MainActor func testMacroHoursExcludeBackgroundFocusWait() async throws {
        let io = FakeIO(); io.frames = [[]]
        io.onAction = { _ in if io.actions.count == 1 { io.focused = false } }
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput; settings.pollSeconds = 0.01
        settings.bankingRecording = recording([.key(12)])
        settings.bankingRecording?.tailDelaySeconds = 0.05
        settings.macroRepeat.mode = .duration; settings.macroRepeat.durationSeconds = 0.2
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await waitForFocusWait(runner)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(io.actions, [.key(12)])
        io.focused = true
        try await finish(runner)
        XCTAssertGreaterThan(runner.macroRunsCompleted, 1)
        XCTAssertEqual(runner.stage, .completed)
    }

    @MainActor func testMacroHoursExcludesPausedTime() async throws {
        let io = FakeIO(); io.frames = [[]]
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput; settings.pollSeconds = 0.01
        settings.bankingRecording = recording([.key(12)])
        settings.bankingRecording?.tailDelaySeconds = 0.05
        settings.macroRepeat.mode = .duration; settings.macroRepeat.durationSeconds = 0.2
        let runner = AutomationCoordinator(); var didPause = false
        runner.onChange = {
            if runner.macroRunsCompleted == 1 && !didPause { didPause = true; runner.pause() }
        }
        var config = AutomationConfiguration(); config.dryRun = false
        try runner.start(configuration: config, settings: settings, io: io)
        let until = Date().addingTimeInterval(1)
        while !didPause && Date() < until { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(didPause)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(io.actions, [.key(12)])
        try runner.resume(); try await finish(runner)
        XCTAssertGreaterThan(runner.macroRunsCompleted, 1, "Paused wall time must not consume the remaining hours budget")
        XCTAssertEqual(runner.stage, .completed)
        runner.onChange = nil
    }

    @MainActor func testMacroRepeatsDoNotRepeatReturnRouteReplay() async throws {
        let io = FakeIO(); io.frames = [[.respawnIndicator]]
        io.onAction = { _ in io.frames = [[.destinationLandmark]] }
        var settings = WorkflowSettings(); settings.bankingEnabled = false
        settings.route.recording = recording([.key(12)])
        settings.macroRepeat.mode = .count; settings.macroRepeat.count = 3
        var config = AutomationConfiguration(); config.dryRun = false; config.mode = .fullAutomation
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io, routeTest: true)
        try await finish(runner)
        XCTAssertEqual(io.actions, [.key(12)])
        XCTAssertEqual(runner.stage, .completed)
        XCTAssertEqual(runner.lastVerifiedAction, "farming destination")
        XCTAssertEqual(runner.macroRunsCompleted, 0)
    }

    @MainActor func testMacroCountReplaysWholeSequenceExactlyNTimes() async throws {
        let io = FakeIO(); io.frames = [[]]
        let actions: [GameAction] = [.key(12), .point(x: 0.3, y: 0.4)]
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        settings.bankingRecording = recording(actions)
        settings.macroRepeat.mode = .count; settings.macroRepeat.count = 3
        settings.macroRepeat.delayBetweenRunsSeconds = 0.02
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(io.actions, actions + actions + actions)
        XCTAssertEqual(runner.macroRunsCompleted, 3)
        XCTAssertEqual(runner.stage, .completed)
        XCTAssertNil(runner.lastVerifiedAction)
    }

    @MainActor func testMacroHoursFinishesCurrentCycleThenDoesNotStartAnother() async throws {
        let io = FakeIO(); io.frames = [[]]
        let actions: [GameAction] = [.key(12), .key(13)]
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput; settings.pollSeconds = 0.01
        settings.bankingRecording = recording(actions)
        settings.bankingRecording?.steps[1].delayBeforeSeconds = 0.12
        settings.macroRepeat.mode = .duration; settings.macroRepeat.durationSeconds = 0.08
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(io.actions, actions, "Finish the second input of the current cycle after time expires")
        XCTAssertEqual(runner.macroRunsCompleted, 1)
        XCTAssertEqual(runner.stage, .completed)
    }

    @MainActor func testMacroHoursDoesNotStartCycleAfterBetweenRunDelay() async throws {
        let io = FakeIO(); io.frames = [[]]
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput; settings.pollSeconds = 0.01
        settings.bankingRecording = recording([.key(12)])
        settings.macroRepeat.mode = .duration; settings.macroRepeat.durationSeconds = 0.08
        settings.macroRepeat.delayBetweenRunsSeconds = 0.2
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(io.actions, [.key(12)])
        XCTAssertEqual(runner.macroRunsCompleted, 1)
        XCTAssertEqual(runner.stage, .completed)
    }

    @MainActor func testMacroCountUsesOwnLimitInsteadOfDefaultSessionCutoff() async throws {
        let io = FakeIO(); io.frames = [[]]
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput; settings.pollSeconds = 0.01
        settings.workflowTimeoutSeconds = 1
        settings.bankingRecording = recording([.key(12)])
        settings.bankingRecording?.tailDelaySeconds = 0.55
        settings.macroRepeat.mode = .count; settings.macroRepeat.count = 2
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .completed)
        XCTAssertEqual(runner.macroRunsCompleted, 2)
        XCTAssertEqual(io.actions, [.key(12), .key(12)])
    }

    @MainActor func testMacroHoursUsesOwnLimitInsteadOfDefaultSessionCutoff() async throws {
        let io = FakeIO(); io.frames = [[]]
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput; settings.pollSeconds = 0.01
        settings.workflowTimeoutSeconds = 1
        settings.bankingRecording = recording([.key(12)])
        settings.bankingRecording?.tailDelaySeconds = 1.1
        settings.macroRepeat.mode = .duration; settings.macroRepeat.durationSeconds = 1.05
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .completed)
        XCTAssertEqual(runner.macroRunsCompleted, 1)
    }

    @MainActor func testMacroRepeatStopsOnInterruptionWithoutRetryingFailedCycle() async throws {
        let io = FakeIO(); io.frames = [[]]
        io.onAction = { _ in io.frames = [[.deathIndicator]] }
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        settings.bankingRecording = recording([.key(12)])
        settings.macroRepeat.mode = .count; settings.macroRepeat.count = 3
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(io.actions, [.key(12)])
        XCTAssertEqual(runner.macroRunsCompleted, 0)
        XCTAssertEqual(runner.stage, .waitingForManualIntervention)
    }

    @MainActor func testMacroRepeatCanPauseBetweenCyclesThenResume() async throws {
        let io = FakeIO(); io.frames = [[]]
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        settings.bankingRecording = recording([.key(12)])
        settings.macroRepeat.mode = .count; settings.macroRepeat.count = 2
        let runner = AutomationCoordinator(); var didPause = false
        runner.onChange = {
            if runner.macroRunsCompleted == 1 && !didPause { didPause = true; runner.pause() }
        }
        var config = AutomationConfiguration(); config.dryRun = false
        try runner.start(configuration: config, settings: settings, io: io)
        let until = Date().addingTimeInterval(1)
        while !didPause && Date() < until { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(didPause)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(io.actions, [.key(12)])
        try runner.resume(); try await finish(runner)
        XCTAssertEqual(io.actions, [.key(12), .key(12)])
        XCTAssertEqual(runner.macroRunsCompleted, 2)
        runner.onChange = nil
    }

    @MainActor func testMacroRepeatCanBeCancelledBetweenCycles() async throws {
        let io = FakeIO(); io.frames = [[]]
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        settings.bankingRecording = recording([.key(12)])
        settings.macroRepeat.mode = .count; settings.macroRepeat.count = 100
        let runner = AutomationCoordinator(); var didStop = false
        runner.onChange = {
            if runner.macroRunsCompleted == 1 && !didStop { didStop = true; runner.stop() }
        }
        var config = AutomationConfiguration(); config.dryRun = false
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(io.actions, [.key(12)])
        XCTAssertEqual(runner.stage, .cancelled)
        runner.onChange = nil
    }

    private func recording(_ actions: [GameAction]) -> InputRecording {
        var value = InputRecording(windowWidth: 1000, windowHeight: 800)
        value.steps = actions.map { .init(action: $0, holdSeconds: 0.1) }
        return value
    }

    @MainActor func testRecordedJewelsReplayExactInputsWithoutImageTargetsOrFalseTransferSuccess() async throws {
        let io = FakeIO(); io.frames = [[]]
        let actions: [GameAction] = [.point(x: 0.15, y: 0.8), .key(12), .point(x: 0.6, y: 0.4)]
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        settings.bankingRecording = recording(actions)
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .completed)
        XCTAssertEqual(io.actions, actions)
        XCTAssertEqual(io.recordedSteps, settings.bankingRecording?.steps)
        XCTAssertNil(runner.lastVerifiedAction)
        XCTAssertTrue(runner.events.last?.message.contains("not visually verified") == true)
    }

    @MainActor func testRecordedWaitAndTailDelayAreHonored() async throws {
        let io = FakeIO(); io.frames = [[]]
        var times: [Date] = []; io.onAction = { _ in times.append(Date()) }
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput; settings.pollSeconds = 0.01
        settings.bankingRecording = recording([.key(12), .key(13)])
        settings.bankingRecording?.steps[1].delayBeforeSeconds = 0.08
        settings.bankingRecording?.tailDelaySeconds = 0.08
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(times.count, 2)
        if times.count == 2 {
            XCTAssertGreaterThanOrEqual(times[1].timeIntervalSince(times[0]), 0.07)
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(times[1]), 0.07)
        }
    }

    @MainActor func testRecordedPlaybackPauseAndCancellationPreventPendingInput() async throws {
        let io = FakeIO(); io.frames = [[]]
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput; settings.pollSeconds = 0.01
        settings.bankingRecording = recording([.key(12)])
        settings.bankingRecording?.steps[0].delayBeforeSeconds = 0.1
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        runner.pause()
        try await Task.sleep(nanoseconds: 130_000_000)
        XCTAssertTrue(io.actions.isEmpty)
        try runner.resume()
        runner.stop()
        try await finish(runner)
        XCTAssertTrue(io.actions.isEmpty)
        XCTAssertEqual(runner.stage, .cancelled)
    }

    @MainActor func testDeathDuringRecordedWaitStopsBeforeNextInput() async throws {
        let io = FakeIO(); io.frames = [[]]
        io.onAction = { _ in io.frames = [[.deathIndicator]] }
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        settings.bankingRecording = recording([.key(12), .key(13)])
        settings.bankingRecording?.steps[1].delayBeforeSeconds = 0.1
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(io.actions, [.key(12)])
        XCTAssertEqual(runner.stage, .waitingForManualIntervention)
    }

    @MainActor func testRecordedRouteRunsAfterSpawnAndChecksDestinationWithoutPerStepLabels() async throws {
        let io = FakeIO(); io.frames = [[.respawnIndicator]]
        io.onAction = { _ in io.frames = [[.destinationLandmark]] }
        var settings = WorkflowSettings(); settings.bankingEnabled = false; settings.pollSeconds = 0.01
        settings.route.recording = recording([.key(12), .point(x: 0.3, y: 0.4)])
        settings.route.validated = true
        var config = AutomationConfiguration(); config.dryRun = false; config.mode = .fullAutomation
        config.helperEnabled = false; config.recoveryEnabled = true
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        let until = Date().addingTimeInterval(1)
        while runner.lastVerifiedAction != "farming destination" && runner.active && Date() < until {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(runner.lastVerifiedAction, "farming destination")
        XCTAssertEqual(io.actions, settings.route.recording?.steps.map(\.action))
        runner.stop(); try await finish(runner)
    }

    @MainActor func testRecordedRouteMissingDestinationStopsWithoutHelperRestart() async throws {
        let io = FakeIO(); io.frames = [[.respawnIndicator]]
        io.onAction = { _ in io.frames = [[]] }
        var settings = WorkflowSettings(); settings.bankingEnabled = false; settings.pollSeconds = 0.01
        settings.actionTimeoutSeconds = 0.1
        settings.route.recording = recording([.key(12)])
        var config = AutomationConfiguration(); config.dryRun = false; config.mode = .fullAutomation
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io, routeTest: true)
        try await finish(runner)
        XCTAssertEqual(io.actions, [.key(12)])
        XCTAssertEqual(runner.stage, .waitingForManualIntervention)
        XCTAssertNil(runner.lastVerifiedAction)
    }

    @MainActor func testMissingJewelRecordingCannotStart() async throws {
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        var config = AutomationConfiguration(); config.dryRun = false
        XCTAssertThrowsError(try AutomationCoordinator().start(configuration: config, settings: settings, io: FakeIO()))
    }

    @MainActor func testRecordedRouteTimeoutStopsDuringSavedWait() async throws {
        let io = FakeIO(); io.frames = [[.respawnIndicator]]
        var settings = WorkflowSettings(); settings.bankingEnabled = false; settings.pollSeconds = 0.01
        settings.routeTimeoutSeconds = 0.1
        settings.route.recording = recording([.key(12)])
        settings.route.recording?.steps[0].delayBeforeSeconds = 0.3
        var config = AutomationConfiguration(); config.dryRun = false; config.mode = .fullAutomation
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io, routeTest: true)
        try await finish(runner)
        XCTAssertTrue(io.actions.isEmpty)
        XCTAssertTrue(runner.lastError?.contains("Maximum route duration") == true)
    }

    @MainActor func testMissedInventoryClickReportsPanelScoreWithoutOpeningBankOrRepeatingClick() async throws {
        let io = FakeIO(); io.frames = [[]]; io.configuredTargets = [.inventoryControl]
        io.scores = [.inventoryPanel: 0.42]
        var config = AutomationConfiguration(); config.dryRun = false
        var settings = WorkflowSettings(); settings.actionTimeoutSeconds = 0.1; settings.pollSeconds = 0.01
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .waitingForManualIntervention)
        XCTAssertEqual(io.actions, [.click(.inventoryControl)])
        XCTAssertTrue(runner.lastError?.contains("inventoryPanel score: 0.420") == true)
        XCTAssertNil(runner.lastVerifiedAction)
    }

    func testTemplateSimilarityAndInvalidImages() {
        let black = GrayImage(width: 2, height: 2, pixels: [0,0,0,0])
        let white = GrayImage(width: 2, height: 2, pixels: [255,255,255,255])
        XCTAssertEqual(TemplateMatcher.similarity(black, black), 0, "Featureless regions are not evidence")
        XCTAssertEqual(TemplateMatcher.similarity(black, white), 0)
        XCTAssertEqual(TemplateMatcher.similarity(black, .init(width: 2, height: 2, pixels: [])), 0)
        let pattern = GrayImage(width: 2, height: 2, pixels: [0,255,60,180])
        XCTAssertEqual(TemplateMatcher.similarity(pattern, pattern), 1, accuracy: 0.000001)
    }

    func testContradictoryStatesAndDisconnectPrecedence() {
        XCTAssertEqual(Observation(matches: [.bankTitle: 1, .helperPanel: 1]).state, .unknown)
        XCTAssertEqual(Observation(matches: [.deathIndicator: 1, .respawnIndicator: 1]).state, .unknown)
        XCTAssertEqual(Observation(matches: [.disconnected: 1, .normalGameplay: 1]).state, .disconnected)
        XCTAssertTrue(Observation(matches: [:]).blocksInput)
        XCTAssertFalse(Observation(matches: [.normalGameplay: .nan]).has(.normalGameplay))
        XCTAssertFalse(Observation(matches: [.normalGameplay: 0.2]).has(.normalGameplay))
    }

    @MainActor private func finish(_ runner: AutomationCoordinator) async throws {
        let limit = Date().addingTimeInterval(2)
        while runner.active && Date() < limit { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(runner.active, "Workflow did not terminate")
    }

    @MainActor func testBankingEndToEndAndJewelsOnlyIsolation() async throws {
        let io = FakeIO()
        let gameplay: [TargetRole] = [.normalGameplay, .inventoryControl]
        let inventory: [TargetRole] = [.inventoryPanel, .bankControl, .inventoryClose]
        let bank: [TargetRole] = [.inventoryPanel, .bankTitle, .transferButton, .bankClose]
        let success = bank + [.transferSuccess]
        io.frames = [gameplay, gameplay, inventory, inventory, bank, bank, success, success, inventory, inventory, gameplay]
        let runner = AutomationCoordinator()
        var config = AutomationConfiguration(); config.dryRun = false
        config.skillsEnabled = true; config.recoveryEnabled = true
        try runner.start(configuration: config, settings: .init(), io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .completed)
        XCTAssertEqual(io.actions, [.click(.inventoryControl), .click(.bankControl), .click(.transferButton), .click(.bankClose), .click(.inventoryClose)])
    }

    @MainActor func testRelaxedBankingCompletesWithoutNormalGameplayIncludingUnknownClosure() async throws {
        let io = FakeIO()
        configureBankingWithoutGameplay(io)
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: .init(), io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .completed)
        XCTAssertEqual(io.actions, [.click(.inventoryControl), .click(.bankControl), .click(.transferButton), .click(.bankClose), .click(.inventoryClose)])
        XCTAssertEqual(runner.lastObservation?.state, .unknown, "Do not fabricate a gameplay match")
    }

    @MainActor func testRelaxedBankingUsesAllSavedControlPositionsWithoutButtonRecognition() async throws {
        let io = FakeIO()
        io.configuredTargets = [.inventoryControl, .bankControl, .transferButton, .bankClose, .inventoryClose]
        io.frames = [[]]
        io.onAction = { action in
            switch action {
            case .click(.inventoryControl): io.frames = [[.inventoryPanel]]
            case .click(.bankControl): io.frames = [[.inventoryPanel, .bankTitle]]
            case .click(.transferButton): io.frames = [[.inventoryPanel, .bankTitle, .transferSuccess]]
            case .click(.bankClose): io.frames = [[.inventoryPanel]]
            case .click(.inventoryClose): io.frames = [[]]
            default: break
            }
        }
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: .init(), io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .completed)
        XCTAssertEqual(io.actions, [.click(.inventoryControl), .click(.bankControl), .click(.transferButton), .click(.bankClose), .click(.inventoryClose)])
    }

    @MainActor func testStrictRecognitionStillRequiresButtonMatchDespiteSavedPosition() async throws {
        let io = FakeIO(); io.frames = [[.normalGameplay]]; io.configuredTargets = [.inventoryControl]
        var config = AutomationConfiguration(); config.dryRun = false; config.strictGameplayRecognition = true
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: .init(), io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .waitingForManualIntervention)
        XCTAssertTrue(io.actions.isEmpty)
    }

    @MainActor func testSavedTransferPositionDoesNotRepeatUnverifiedTransfer() async throws {
        let io = FakeIO(); io.frames = [[.inventoryPanel, .bankTitle]]; io.configuredTargets = [.transferButton]
        var config = AutomationConfiguration(); config.dryRun = false
        var settings = WorkflowSettings(); settings.actionTimeoutSeconds = 0.1; settings.pollSeconds = 0.01
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .waitingForManualIntervention)
        XCTAssertEqual(io.actions, [.click(.transferButton)])
    }

    @MainActor func testRelaxedTransferWaitToleratesBriefMissingBankTitleWhileStrictStops() async throws {
        let bank: [TargetRole] = [.inventoryPanel, .bankTitle, .transferButton, .bankClose]
        let success = bank + [.transferSuccess]
        let inventory: [TargetRole] = [.inventoryPanel, .inventoryClose]
        for strict in [false, true] {
            let io = FakeIO()
            io.frames = [bank, bank, [], success, success, inventory, inventory, [.normalGameplay]]
            var config = AutomationConfiguration(); config.dryRun = false; config.strictGameplayRecognition = strict
            var settings = WorkflowSettings(); settings.pollSeconds = 0.01
            let runner = AutomationCoordinator()
            try runner.start(configuration: config, settings: settings, io: io)
            try await finish(runner)
            XCTAssertEqual(runner.stage, strict ? .waitingForManualIntervention : .completed)
            XCTAssertEqual(io.actions.filter { $0 == .click(.transferButton) }.count, 1)
        }
    }

    @MainActor func testRelaxedActionWaitsForTransientlyMissingPanelBeforeClicking() async throws {
        let inventory: [TargetRole] = [.inventoryPanel, .bankControl, .inventoryClose]
        let bank: [TargetRole] = [.inventoryPanel, .bankTitle, .transferButton, .bankClose]
        let success = bank + [.transferSuccess]
        let io = FakeIO()
        io.frames = [inventory, [], inventory, bank, bank, success, success, inventory, inventory, [.normalGameplay]]
        var config = AutomationConfiguration(); config.dryRun = false
        var settings = WorkflowSettings(); settings.pollSeconds = 0.01
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .completed)
        XCTAssertEqual(io.actions.first, .click(.bankControl))
    }

    @MainActor func testInterruptionDuringRelaxedPreconditionWaitStopsBeforeClick() async throws {
        let io = FakeIO(); io.frames = [[.inventoryPanel], [], [.deathIndicator], [.inventoryPanel]]
        io.configuredTargets = [.bankControl]
        var config = AutomationConfiguration(); config.dryRun = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: .init(), io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .waitingForManualIntervention)
        XCTAssertTrue(io.actions.isEmpty)
    }

    @MainActor func testStrictRecognitionStillRejectsMissingGameplayBeforeInventoryClick() async throws {
        let io = FakeIO(); io.frames = [[.inventoryControl]]
        var config = AutomationConfiguration(); config.dryRun = false; config.strictGameplayRecognition = true
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: .init(), io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .waitingForManualIntervention)
        XCTAssertTrue(io.actions.isEmpty)
    }

    @MainActor func testRelaxedRecognitionStillStopsOnExplicitInterruptionMatches() async throws {
        for interruption: TargetRole in [.disconnected, .loginScreen, .characterSelection, .browserLoading,
                                         .loadingTransition, .deathIndicator, .respawnIndicator] {
            let io = FakeIO(); io.frames = [[.inventoryControl, interruption]]
            var config = AutomationConfiguration(); config.dryRun = false
            let runner = AutomationCoordinator()
            try runner.start(configuration: config, settings: .init(), io: io)
            try await finish(runner)
            XCTAssertEqual(runner.stage, .waitingForManualIntervention, interruption.rawValue)
            XCTAssertTrue(io.actions.isEmpty, interruption.rawValue)
        }
    }

    @MainActor func testRelaxedFullModeKeepsMonitoringAfterBankingWithoutGameplayLabel() async throws {
        let io = FakeIO(); configureBankingWithoutGameplay(io)
        var config = AutomationConfiguration(); config.dryRun = false
        config.mode = .fullAutomation; config.helperEnabled = false
        var settings = WorkflowSettings(); settings.pollSeconds = 0.01; settings.inventoryMonitoringEnabled = false
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await waitUntil { runner.stage == .farming }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(runner.active)
        XCTAssertEqual(runner.lastObservation?.state, .unknown)
        runner.stop(); try await finish(runner)
        XCTAssertEqual(runner.stage, .cancelled)
        XCTAssertEqual(io.actions.count, 5)
    }

    @MainActor private func configureBankingWithoutGameplay(_ io: FakeIO) {
        io.frames = [[.inventoryControl]]
        io.onAction = { action in
            switch action {
            case .click(.inventoryControl): io.frames = [[.inventoryPanel, .bankControl, .inventoryClose]]
            case .click(.bankControl): io.frames = [[.inventoryPanel, .bankTitle, .transferButton, .bankClose]]
            case .click(.transferButton): io.frames = [[.inventoryPanel, .bankTitle, .bankClose, .transferSuccess]]
            case .click(.bankClose): io.frames = [[.inventoryPanel, .inventoryClose]]
            case .click(.inventoryClose): io.frames = [[]]
            default: break
            }
        }
    }

    @MainActor func testUnverifiedTransferNeverRepeats() async throws {
        let io = FakeIO()
        io.frames = [[.inventoryPanel, .bankTitle, .transferButton]]
        let runner = AutomationCoordinator()
        var config = AutomationConfiguration(); config.dryRun = false
        var settings = WorkflowSettings(); settings.actionTimeoutSeconds = 0.1; settings.pollSeconds = 0.01
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .waitingForManualIntervention)
        XCTAssertEqual(io.actions, [.click(.transferButton)])
    }

    @MainActor func testUnknownOrDisconnectCannotSendInput() async throws {
        for roles: [TargetRole] in [[], [.disconnected]] {
            let io = FakeIO(); io.frames = [roles]
            let runner = AutomationCoordinator()
            var config = AutomationConfiguration(); config.dryRun = false
            try runner.start(configuration: config, settings: .init(), io: io)
            try await finish(runner)
            XCTAssertEqual(runner.stage, .waitingForManualIntervention)
            XCTAssertTrue(io.actions.isEmpty)
        }
    }

    @MainActor func testEmergencyStopCancelsVerification() async throws {
        let io = FakeIO(); io.frames = [[.inventoryPanel, .bankTitle, .transferButton]]
        let runner = AutomationCoordinator()
        io.onAction = { _ in runner.stop() }
        var config = AutomationConfiguration(); config.dryRun = false
        try runner.start(configuration: config, settings: .init(), io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .cancelled)
        XCTAssertEqual(io.actions.count, 1)
    }

    @MainActor func testPermanentFailureAfterTransferStopsFurtherInput() async throws {
        let io = FakeIO(); io.frames = [[.inventoryPanel, .bankTitle, .transferButton]]
        io.onAction = { _ in io.unsafe = true }
        let runner = AutomationCoordinator()
        var config = AutomationConfiguration(); config.dryRun = false
        try runner.start(configuration: config, settings: .init(), io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .waitingForManualIntervention)
        XCTAssertEqual(io.actions.count, 1)
    }

    @MainActor func testStaleSuccessAndProcessingBlockTransfer() async throws {
        for marker: TargetRole in [.transferSuccess, .processingIndicator] {
            let io = FakeIO(); io.frames = [[.inventoryPanel, .bankTitle, .transferButton, marker]]
            let runner = AutomationCoordinator()
            var config = AutomationConfiguration(); config.dryRun = false
            try runner.start(configuration: config, settings: .init(), io: io)
            try await finish(runner)
            XCTAssertTrue(io.actions.isEmpty)
            XCTAssertEqual(runner.stage, .waitingForManualIntervention)
        }
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let until = Date().addingTimeInterval(2)
        while !condition() && Date() < until { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition())
    }

    @MainActor func testHelperAlreadyRunningDoesNotToggle() async throws {
        let io = FakeIO(); io.frames = [[.normalGameplay, .helperRunning]]
        let runner = AutomationCoordinator()
        var config = AutomationConfiguration(); config.dryRun = false; config.mode = .fullAutomation
        var settings = WorkflowSettings(); settings.bankingEnabled = false; settings.pollSeconds = 0.01
        try runner.start(configuration: config, settings: settings, io: io)
        try await waitUntil { runner.stage == .farming }
        runner.stop(); try await finish(runner)
        XCTAssertTrue(io.actions.isEmpty)
    }

    @MainActor func testHelperActivationVerified() async throws {
        let io = FakeIO()
        io.frames = [[.normalGameplay, .helperControl]]
        io.onAction = { action in
            if action == .click(.helperControl) { io.frames = [[.helperPanel, .helperStart]] }
            if action == .click(.helperStart) { io.frames = [[.normalGameplay, .helperRunning]] }
        }
        let runner = AutomationCoordinator()
        var config = AutomationConfiguration(); config.dryRun = false; config.mode = .fullAutomation
        var settings = WorkflowSettings(); settings.bankingEnabled = false; settings.pollSeconds = 0.01
        try runner.start(configuration: config, settings: settings, io: io)
        try await waitUntil { runner.stage == .farming }
        runner.stop(); try await finish(runner)
        XCTAssertEqual(io.actions, [.click(.helperControl), .click(.helperStart)])
    }

    @MainActor func testMissingHelperStartStops() async throws {
        let io = FakeIO(); io.frames = [[.helperPanel]]
        let runner = AutomationCoordinator()
        var config = AutomationConfiguration(); config.dryRun = false; config.mode = .fullAutomation
        var settings = WorkflowSettings(); settings.bankingEnabled = false
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .waitingForManualIntervention)
        XCTAssertTrue(io.actions.isEmpty)
    }

    @MainActor func testFalsePositiveDeathDoesNotMove() async throws {
        let io = FakeIO(); io.frames = [[.deathIndicator], [.normalGameplay]]
        let runner = AutomationCoordinator()
        var config = AutomationConfiguration()
        config.dryRun = false; config.mode = .fullAutomation; config.helperEnabled = false; config.recoveryEnabled = true
        var settings = WorkflowSettings(); settings.bankingEnabled = false; settings.pollSeconds = 0.01
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .waitingForManualIntervention)
        XCTAssertTrue(io.actions.isEmpty)
    }

    @MainActor func testConfirmedDeathRespawnTimeout() async throws {
        let io = FakeIO(); io.frames = [[.deathIndicator, .deathConfirmation]]
        let runner = AutomationCoordinator()
        var config = AutomationConfiguration()
        config.dryRun = false; config.mode = .fullAutomation; config.helperEnabled = false; config.recoveryEnabled = true
        var settings = WorkflowSettings()
        settings.bankingEnabled = false; settings.pollSeconds = 0.01; settings.recoveryTimeoutSeconds = 0.1
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .waitingForManualIntervention)
        XCTAssertTrue(io.actions.isEmpty)
        XCTAssertTrue(runner.events.last?.message.contains("respawn") == true)
    }

    @MainActor func testRecoveryRouteVerifiesDestinationAndRestartsHelper() async throws {
        let io = FakeIO()
        io.frames = [[.helperRunning, .normalGameplay], [.respawnIndicator, .routeCheckpoint]]
        io.onAction = { action in
            switch action {
            case .click(.routeCheckpoint): io.frames = [[.normalGameplay, .destinationLandmark, .helperControl]]
            case .click(.helperControl): io.frames = [[.helperPanel, .helperStart]]
            case .click(.helperStart): io.frames = [[.normalGameplay, .helperRunning]]
            default: break
            }
        }
        let runner = AutomationCoordinator()
        var config = AutomationConfiguration()
        config.dryRun = false; config.mode = .fullAutomation; config.recoveryEnabled = true
        var settings = WorkflowSettings(); settings.bankingEnabled = false; settings.pollSeconds = 0.01
        settings.route.validated = true
        settings.route.steps = [.init(action: .click(.routeCheckpoint), before: .respawnIndicator, after: .destinationLandmark)]
        try runner.start(configuration: config, settings: settings, io: io)
        try await waitUntil { io.actions.contains(.click(.helperStart)) && runner.stage == .farming }
        runner.stop(); try await finish(runner)
        XCTAssertEqual(io.actions, [.click(.routeCheckpoint), .click(.helperControl), .click(.helperStart)])
    }

    @MainActor func testRouteFailureDoesNotRestartHelper() async throws {
        let io = FakeIO(); io.frames = [[.respawnIndicator, .routeCheckpoint]]
        io.onAction = { _ in io.frames = [[.normalGameplay]] }
        let runner = AutomationCoordinator()
        var config = AutomationConfiguration()
        config.dryRun = false; config.mode = .fullAutomation; config.helperEnabled = false; config.recoveryEnabled = true
        var settings = WorkflowSettings()
        settings.bankingEnabled = false; settings.pollSeconds = 0.01; settings.actionTimeoutSeconds = 0.1
        settings.route.validated = true
        settings.route.steps = [.init(action: .click(.routeCheckpoint), before: .respawnIndicator, after: .destinationLandmark)]
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .waitingForManualIntervention)
        XCTAssertEqual(io.actions, [.click(.routeCheckpoint)])
    }

    @MainActor func testNoOverlappingWorkflowsAndPauseStop() async throws {
        let io = FakeIO(); io.frames = [[.normalGameplay]]
        let runner = AutomationCoordinator()
        var config = AutomationConfiguration(); config.dryRun = false; config.mode = .fullAutomation; config.helperEnabled = false
        var settings = WorkflowSettings(); settings.bankingEnabled = false; settings.pollSeconds = 0.01
        try runner.start(configuration: config, settings: settings, io: io)
        XCTAssertThrowsError(try runner.start(configuration: config, settings: settings, io: io))
        runner.pause()
        XCTAssertEqual(runner.stage, .paused)
        runner.stop(); try await finish(runner)
        XCTAssertTrue(io.actions.isEmpty)
    }

    @MainActor func testStrictBankDialogDisappearancePausesWithoutClosingAnything() async throws {
        let io = FakeIO(); io.frames = [[.inventoryPanel, .bankTitle, .transferButton]]
        io.onAction = { _ in io.frames = [[.inventoryPanel]] }
        let runner = AutomationCoordinator()
        var config = AutomationConfiguration(); config.dryRun = false; config.strictGameplayRecognition = true
        try runner.start(configuration: config, settings: .init(), io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .waitingForManualIntervention)
        XCTAssertTrue(runner.events.last?.message.contains("disappeared") == true)
        XCTAssertEqual(io.actions, [.click(.transferButton)])
    }

    @MainActor func testRelaxedPermanentBankDisappearanceTimesOutWithoutRepeatingOrClosing() async throws {
        let io = FakeIO(); io.frames = [[.inventoryPanel, .bankTitle, .transferButton]]
        io.onAction = { _ in io.frames = [[.inventoryPanel]] }
        var config = AutomationConfiguration(); config.dryRun = false
        var settings = WorkflowSettings(); settings.actionTimeoutSeconds = 0.1; settings.pollSeconds = 0.01
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .waitingForManualIntervention)
        XCTAssertEqual(io.actions, [.click(.transferButton)])
    }

    @MainActor func testRouteReplayCannotRunInJewelsOnlyMode() async throws {
        let runner = AutomationCoordinator(), io = FakeIO()
        var config = AutomationConfiguration(); config.dryRun = false
        XCTAssertThrowsError(try runner.start(configuration: config, settings: .init(), io: io, routeTest: true))
        XCTAssertFalse(runner.active)
        XCTAssertTrue(io.actions.isEmpty)
    }

    @MainActor func testReplayTestStopsAtDestinationWithoutStartingHelper() async throws {
        let runner = AutomationCoordinator(), io = FakeIO()
        io.frames = [[.normalGameplay, .routeCheckpoint]]
        io.onAction = { _ in io.frames = [[.normalGameplay, .destinationLandmark]] }
        var config = AutomationConfiguration(); config.dryRun = false; config.mode = .fullAutomation
        var settings = WorkflowSettings()
        settings.route.steps = [.init(action: .click(.routeCheckpoint), before: .routeCheckpoint, after: .destinationLandmark)]
        try runner.start(configuration: config, settings: settings, io: io, routeTest: true)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .completed)
        XCTAssertEqual(io.actions, [.click(.routeCheckpoint)])
    }

    @MainActor func testSkillsHonorCooldownAndStop() async throws {
        let runner = AutomationCoordinator(), io = FakeIO(); io.frames = [[.normalGameplay]]
        var config = AutomationConfiguration()
        config.dryRun = false; config.mode = .fullAutomation; config.helperEnabled = false; config.skillsEnabled = true
        var settings = WorkflowSettings(); settings.bankingEnabled = false; settings.pollSeconds = 0.01
        var skill = SkillAction(); skill.keyCode = 12; skill.delaySeconds = 0.1; skill.cooldownSeconds = 10
        settings.skills = [skill]
        try runner.start(configuration: config, settings: settings, io: io)
        try await waitUntil { io.actions.count == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        runner.stop(); try await finish(runner)
        XCTAssertEqual(io.actions, [.key(12)])
    }

    @MainActor func testGlobalDurationIsBounded() async throws {
        let runner = AutomationCoordinator(), io = FakeIO(); io.frames = [[.normalGameplay]]
        var config = AutomationConfiguration(); config.dryRun = false; config.mode = .fullAutomation; config.helperEnabled = false
        var settings = WorkflowSettings(); settings.bankingEnabled = false; settings.workflowTimeoutSeconds = 1; settings.pollSeconds = 0.01
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .waitingForManualIntervention)
        XCTAssertTrue(runner.events.last?.message.contains("duration") == true)
    }

    func testInvalidRoutesAndDuplicateActionsAreRejected() throws {
        var settings = WorkflowSettings()
        settings.route.steps = [.init(action: .click(.withdrawExcluded), before: .normalGameplay, after: .normalGameplay)]
        XCTAssertThrowsError(try settings.validate())
        settings.route.steps = [.init(action: .point(x: 2, y: 0.5), before: .normalGameplay, after: .normalGameplay)]
        XCTAssertThrowsError(try settings.validate())
        settings.route.steps = []
        let skill = SkillAction(); settings.skills = [skill, skill]
        XCTAssertThrowsError(try settings.validate())
        let old = try JSONDecoder().decode(WorkflowSettings.self, from: Data(#"{"schemaVersion":1}"#.utf8))
        try old.validate()
        XCTAssertEqual(old.routeTimeoutSeconds, 120)
    }

    @MainActor func testInventoryCountVerificationEndToEnd() async throws {
        let io = FakeIO()
        io.frames = [[.inventoryPanel, .bankTitle, .transferButton, .bankClose, .inventoryCountText]]
        io.texts = [.inventoryCountText: "5"]
        io.onAction = { action in
            if action == .click(.transferButton) { io.texts = [.inventoryCountText: "0"] }
            if action == .click(.bankClose) { io.frames = [[.inventoryPanel, .inventoryClose]] }
            if action == .click(.inventoryClose) { io.frames = [[.normalGameplay]] }
        }
        var config = AutomationConfiguration(); config.dryRun = false
        var settings = WorkflowSettings(); settings.bankingVerification = .inventoryCountDecrease
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .completed)
        XCTAssertEqual(io.actions, [.click(.transferButton), .click(.bankClose), .click(.inventoryClose)])
    }
    @MainActor func testVisualCollectionReportsBankBalanceAndIncrease() async throws {
        let io = FakeIO()
        io.frames = [[.inventoryPanel, .bankTitle, .transferButton, .bankClose, .bankBalanceText]]
        io.texts = [.bankBalanceText: "100"]
        io.onAction = { action in
            if action == .click(.transferButton) { io.texts[.bankBalanceText] = "125" }
            if action == .click(.bankClose) { io.frames = [[.inventoryPanel, .inventoryClose]] }
            if action == .click(.inventoryClose) { io.frames = [[]] }
        }
        var config = AutomationConfiguration(); config.dryRun = false
        var settings = WorkflowSettings(); settings.bankingVerification = .bankBalanceIncrease
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .completed)
        XCTAssertEqual(runner.bankBalanceReading?.balance, 125)
        XCTAssertEqual(runner.bankBalanceReading?.added, 25)
        XCTAssertEqual(io.actions, [.click(.transferButton), .click(.bankClose), .click(.inventoryClose)])
    }

    @MainActor func testRecordedCollectionReportsObservedBalanceWithoutClaimingVerifiedTransfer() async throws {
        let io = FakeIO()
        io.frames = [[.bankTitle, .bankBalanceText]]
        io.texts = [.bankBalanceText: "100"]
        io.onAction = { _ in io.texts[.bankBalanceText] = "125" }
        var config = AutomationConfiguration(); config.dryRun = false
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        var macro = recording([.key(12)])
        macro.steps[0].delayBeforeSeconds = 0.05
        macro.tailDelaySeconds = 0.05
        settings.bankingRecording = macro; settings.pollSeconds = 0.01
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .completed)
        XCTAssertEqual(runner.bankBalanceReading?.balance, 125)
        XCTAssertEqual(runner.bankBalanceReading?.added, 25)
        XCTAssertTrue(runner.events.last?.message.contains("not visually verified") == true)

        // A later collection with no numeric evidence must retain the old reading,
        // visibly flagging that it could not be refreshed rather than inventing zero.
        let previous = runner.bankBalanceReading
        io.frames = [[]]
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(runner.bankBalanceReading, previous)
        XCTAssertTrue(runner.bankBalanceStatus.contains("Couldn’t confirm"))

        io.frames = [[.bankTitle, .bankBalanceText]]
        io.texts = [.bankBalanceText: "1000"]
        io.onAction = { _ in io.texts[.bankBalanceText] = "1025" }
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(runner.bankBalanceReading?.balance, 1025)
        XCTAssertEqual(runner.bankBalanceReading?.added, 25, "Each collection needs its own baseline")
        XCTAssertTrue(runner.events.contains { $0.message == "Bank balance: 1025; amount added: +25" })
    }

    @MainActor func testInterruptedCollectionDoesNotPublishPartialBalance() async throws {
        let io = FakeIO(); io.frames = [[.bankTitle, .bankBalanceText]]
        io.texts = [.bankBalanceText: "100"]
        var config = AutomationConfiguration(); config.dryRun = false
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        var macro = recording([.key(12)]); macro.steps[0].delayBeforeSeconds = 0.05
        settings.bankingRecording = macro; settings.pollSeconds = 0.01
        io.onAction = { _ in io.unsafe = true }
        let runner = AutomationCoordinator()
        try runner.start(configuration: config, settings: settings, io: io)
        try await finish(runner)
        XCTAssertEqual(runner.stage, .waitingForManualIntervention)
        XCTAssertNil(runner.bankBalanceReading)
        XCTAssertTrue(runner.bankBalanceStatus.contains("interrupted"))
    }

}

import XCTest
@testable import AutomationCore

@MainActor
private final class FakeIO: WorkflowIO {
    var frames: [[TargetRole]] = []
    var actions: [GameAction] = []
    var unsafe = false
    var texts: [TargetRole: String] = [:]
    var configuredTargets: Set<TargetRole> = []
    var onAction: ((GameAction) -> Void)?
    func checkSafety() throws {
        if unsafe { throw WorkflowFailure.unsafe("Focus lost") }
    }
    func hasCalibratedTarget(_ role: TargetRole) -> Bool { configuredTargets.contains(role) }
    func observe() async throws -> Observation {
        try checkSafety()
        let roles = frames.count > 1 ? frames.removeFirst() : (frames.first ?? [])
        return Observation(matches: Dictionary(uniqueKeysWithValues: roles.map { ($0, 0.99) }), text: texts)
    }
    func perform(_ action: GameAction) async throws {
        try Task.checkCancellation(); try checkSafety()
        actions.append(action); onAction?(action)
    }
}

final class WorkflowTests: XCTestCase {
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

    @MainActor func testFocusLossAfterTransferStopsFurtherInput() async throws {
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
}

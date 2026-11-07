import XCTest
@testable import AutomationCore

@MainActor
private final class QueueInputLedger {
    var focused: UInt32?
    var inputs: [(UInt32, GameAction)] = []
    var held = 0
    var maximumHeld = 0
    var switchedWhileHeld = false
}

@MainActor
private final class QueueTestIO: WorkflowIO {
    let windowID: UInt32
    let ledger: QueueInputLedger
    var focusCalls = 0
    var invalid = false
    var focusDelay: Double = 0
    var hold: Double = 0.001
    var onFocus: (() -> Void)?
    var onInput: (() -> Void)?
    var sample: [UUID: NamedBankBalanceSample] = [:]
    init(_ id: UInt32, _ ledger: QueueInputLedger) { windowID = id; self.ledger = ledger }
    func checkSafety() throws {
        try Task.checkCancellation()
        if invalid { throw WorkflowFailure.unsafe("Window closed or its document changed") }
        if ledger.focused != windowID { throw WorkflowFailure.focusUnavailable("Selected game lost focus") }
    }
    func observe() async throws -> Observation {
        try checkSafety()
        return Observation(matches: sample.isEmpty ? [:] : [.bankTitle: 1], namedBankBalances: sample)
    }
    func refocusSelectedWindow() async throws {
        try Task.checkCancellation(); focusCalls += 1
        if ledger.held > 0 { ledger.switchedWhileHeld = true }
        onFocus?()
        if focusDelay > 0 { try await Task.sleep(nanoseconds: UInt64(focusDelay * 1_000_000_000)) }
        try Task.checkCancellation()
        if invalid { throw WorkflowFailure.unsafe("Window closed or its document changed") }
        ledger.focused = windowID
    }
    func perform(_ action: GameAction) async throws {
        try checkSafety()
        ledger.held += 1; ledger.maximumHeld = max(ledger.maximumHeld, ledger.held)
        defer { ledger.held -= 1 }
        ledger.inputs.append((windowID, action)); onInput?()
        try await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
    }
    func performRecorded(_ step: RecordedInputStep) async throws { try await perform(step.action) }
}

final class WindowMacroQueueTests: XCTestCase {
    private func profile(_ name: String, key: UInt16, count: Int = 1) -> WindowMacroProfile {
        var config = AutomationConfiguration(); config.dryRun = false
        var settings = WorkflowSettings(); settings.bankingInputMode = .recordedInput
        settings.pollSeconds = 0.01
        var recording = InputRecording(windowWidth: 1000, windowHeight: 700)
        recording.steps = [.init(action: .key(key))]
        settings.bankingRecording = recording
        if count > 1 { settings.macroRepeat.mode = .count; settings.macroRepeat.count = count }
        return WindowMacroProfile(name: name, configuration: config, settings: settings, calibration: .init())
    }
    @MainActor private func until(_ condition: () -> Bool, timeout: Double = 2) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition(), "Queue did not reach the expected state")
    }
    @MainActor private func finish(_ queue: WindowMacroQueue) async throws { try await until { !queue.active } }

    @MainActor func testDistinctMacrosRunInFairTurnsWithoutConcurrentInput() async throws {
        let ledger = QueueInputLedger(); let a = QueueTestIO(1, ledger); let b = QueueTestIO(2, ledger)
        let queue = WindowMacroQueue()
        try queue.start([.init(profile: profile("A", key: 12, count: 2), windowID: 1, io: a),
                         .init(profile: profile("B", key: 13, count: 2), windowID: 2, io: b)], inputConsent: true)
        try await finish(queue)
        XCTAssertEqual(queue.phase, .completed)
        XCTAssertEqual(ledger.inputs.map { $0.0 }, [1, 2, 1, 2])
        XCTAssertEqual(ledger.inputs.map { $0.1 }, [.key(12), .key(13), .key(12), .key(13)])
        XCTAssertEqual(queue.items.map(\.completedRuns), [2, 2])
        XCTAssertEqual(ledger.maximumHeld, 1)
        XCTAssertFalse(ledger.switchedWhileHeld)
    }

    @MainActor func testIndependentCooldownAllowsOtherWindowToProceed() async throws {
        let ledger = QueueInputLedger(); let a = QueueTestIO(1, ledger); let b = QueueTestIO(2, ledger)
        var slow = profile("A", key: 12, count: 2); slow.settings.macroRepeat.delayBetweenRunsSeconds = 0.12
        let queue = WindowMacroQueue()
        try queue.start([.init(profile: slow, windowID: 1, io: a),
                         .init(profile: profile("B", key: 13, count: 2), windowID: 2, io: b)], inputConsent: true)
        try await finish(queue)
        XCTAssertEqual(ledger.inputs.map { $0.0 }, [1, 2, 2, 1])
        XCTAssertEqual(queue.items.map(\.completedRuns), [2, 2])
    }

    @MainActor func testGlobalPauseBetweenFocusAndInputPreventsStartingRunner() async throws {
        let ledger = QueueInputLedger(); let a = QueueTestIO(1, ledger)
        let queue = WindowMacroQueue()
        a.onFocus = { queue.pause(); a.onFocus = nil }
        try queue.start([.init(profile: profile("A", key: 12), windowID: 1, io: a)], inputConsent: true)
        try await until { queue.paused }
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(ledger.inputs.isEmpty)
        try queue.resume(); try await finish(queue)
        XCTAssertEqual(ledger.inputs.map { $0.1 }, [.key(12)])
    }

    @MainActor func testPausedWaitingWindowDoesNotBlockOtherWindows() async throws {
        let ledger = QueueInputLedger(); let a = QueueTestIO(1, ledger); let b = QueueTestIO(2, ledger)
        let first = profile("A", key: 12, count: 2); let second = profile("B", key: 13)
        let queue = WindowMacroQueue()
        try queue.start([.init(profile: first, windowID: 1, io: a), .init(profile: second, windowID: 2, io: b)], inputConsent: true)
        queue.pauseEntry(second.id)
        try await until { queue.items[0].finished }
        XCTAssertEqual(ledger.inputs.map { $0.0 }, [1, 1]); XCTAssertEqual(b.focusCalls, 0)
        try queue.resumeEntry(second.id); try await finish(queue)
        XCTAssertEqual(ledger.inputs.map { $0.0 }, [1, 1, 2])
    }

    @MainActor func testFocusLossHoldsCurrentTurnAndDoesNotSendInputToOtherWindow() async throws {
        let ledger = QueueInputLedger(); let a = QueueTestIO(1, ledger); let b = QueueTestIO(2, ledger)
        var first = profile("A", key: 12)
        first.settings.bankingRecording?.steps.append(.init(action: .key(14)))
        a.onInput = { if ledger.inputs.count == 1 { ledger.focused = nil } }
        let queue = WindowMacroQueue()
        try queue.start([.init(profile: first, windowID: 1, io: a),
                         .init(profile: profile("B", key: 13), windowID: 2, io: b)], inputConsent: true)
        try await until { queue.current?.runner.isWaitingForFocus == true }
        XCTAssertEqual(b.focusCalls, 0); XCTAssertEqual(ledger.inputs.count, 1)
        ledger.focused = 1
        try await finish(queue)
        XCTAssertEqual(ledger.inputs.map { $0.0 }, [1, 1, 2])
        XCTAssertEqual(ledger.inputs.map { $0.1 }, [.key(12), .key(14), .key(13)])
    }

    @MainActor func testFailedTurnStopsWholeQueueWithoutRetryOrNextWindowFocus() async throws {
        let ledger = QueueInputLedger(); let a = QueueTestIO(1, ledger); let b = QueueTestIO(2, ledger)
        var first = profile("A", key: 12, count: 3)
        first.settings.bankingRecording?.steps.append(.init(action: .key(14)))
        a.onInput = { a.invalid = true }
        let queue = WindowMacroQueue()
        try queue.start([.init(profile: first, windowID: 1, io: a),
                         .init(profile: profile("B", key: 13), windowID: 2, io: b)], inputConsent: true)
        try await finish(queue)
        XCTAssertEqual(queue.phase, .failed)
        XCTAssertTrue(queue.lastError?.contains("document changed") == true)
        XCTAssertEqual(b.focusCalls, 0); XCTAssertEqual(ledger.inputs.map { $0.1 }, [.key(12)])
        XCTAssertEqual(queue.items.map(\.completedRuns), [0, 0]); XCTAssertEqual(ledger.held, 0)
    }

    @MainActor func testStopCancelsPendingFocusAndNoFutureWindowStarts() async throws {
        let ledger = QueueInputLedger(); let a = QueueTestIO(1, ledger); let b = QueueTestIO(2, ledger)
        a.focusDelay = 0.3
        let queue = WindowMacroQueue()
        try queue.start([.init(profile: profile("A", key: 12), windowID: 1, io: a),
                         .init(profile: profile("B", key: 13), windowID: 2, io: b)], inputConsent: true)
        try await until { a.focusCalls == 1 }
        queue.stop(); try await finish(queue)
        XCTAssertEqual(queue.phase, .stopped)
        XCTAssertTrue(ledger.inputs.isEmpty); XCTAssertEqual(b.focusCalls, 0)
    }

    @MainActor func testStopActiveWindowReleasesHeldInputBeforeNextWindowFocus() async throws {
        let ledger = QueueInputLedger(); let a = QueueTestIO(1, ledger); let b = QueueTestIO(2, ledger)
        a.hold = 0.5
        let first = profile("A", key: 12, count: 3)
        let queue = WindowMacroQueue()
        try queue.start([.init(profile: first, windowID: 1, io: a),
                         .init(profile: profile("B", key: 13), windowID: 2, io: b)], inputConsent: true)
        try await until { ledger.held == 1 }
        queue.stopEntry(first.id); try await finish(queue)
        XCTAssertEqual(queue.items.map(\.completedRuns), [0, 1])
        XCTAssertFalse(ledger.switchedWhileHeld); XCTAssertEqual(ledger.held, 0)
        XCTAssertEqual(ledger.inputs.map { $0.0 }, [1, 2])
    }

    @MainActor func testGlobalStopReleasesInputAndSkipsRemainingTurns() async throws {
        let ledger = QueueInputLedger(); let a = QueueTestIO(1, ledger); let b = QueueTestIO(2, ledger)
        a.hold = 0.5
        let queue = WindowMacroQueue()
        try queue.start([.init(profile: profile("A", key: 12), windowID: 1, io: a),
                         .init(profile: profile("B", key: 13), windowID: 2, io: b)], inputConsent: true)
        try await until { ledger.held == 1 }
        queue.stop(); try await finish(queue)
        XCTAssertEqual(queue.phase, .stopped); XCTAssertEqual(ledger.held, 0)
        XCTAssertEqual(b.focusCalls, 0); XCTAssertEqual(ledger.inputs.count, 1)
    }

    @MainActor func testDurationBudgetExcludesGlobalPauseAndFinishesCurrentCycle() async throws {
        let ledger = QueueInputLedger(); let a = QueueTestIO(1, ledger)
        var first = profile("A", key: 12)
        first.settings.macroRepeat.mode = .duration; first.settings.macroRepeat.durationSeconds = 0.12
        first.settings.macroRepeat.delayBetweenRunsSeconds = 0.05
        let queue = WindowMacroQueue()
        try queue.start([.init(profile: first, windowID: 1, io: a)], inputConsent: true)
        try await until { queue.items[0].completedRuns == 1 }
        queue.pause(); try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(queue.items[0].completedRuns, 1)
        try queue.resume(); try await finish(queue)
        XCTAssertEqual(queue.phase, .completed)
        XCTAssertGreaterThanOrEqual(queue.items[0].completedRuns, 2)
    }

    @MainActor func testBalancesAndEventsStayWithTheirOwnWindowEvenWithSharedTargetIDs() async throws {
        let ledger = QueueInputLedger(); let a = QueueTestIO(1, ledger); let b = QueueTestIO(2, ledger)
        let target = NamedBankBalanceTarget(name: "Jewel of Soul", region: try NormalizedRegion(x: 0, y: 0, width: 0.1, height: 0.1))
        var first = profile("A", key: 12); var second = profile("B", key: 13)
        for index in 0..<2 {
            if index == 0 {
                first.calibration.namedBankBalances = [target]
                first.settings.bankingRecording?.steps[0].delayBeforeSeconds = 0.04
                first.settings.bankingRecording?.tailDelaySeconds = 0.04
            } else {
                second.calibration.namedBankBalances = [target]
                second.settings.bankingRecording?.steps[0].delayBeforeSeconds = 0.04
                second.settings.bankingRecording?.tailDelaySeconds = 0.04
            }
        }
        a.sample[target.id] = .init(target: target, text: "100", confidence: 1)
        b.sample[target.id] = .init(target: target, text: "1000", confidence: 1)
        a.onInput = { a.sample[target.id] = .init(target: target, text: "125", confidence: 1) }
        b.onInput = { b.sample[target.id] = .init(target: target, text: "1005", confidence: 1) }
        let queue = WindowMacroQueue()
        try queue.start([.init(profile: first, windowID: 1, io: a), .init(profile: second, windowID: 2, io: b)], inputConsent: true)
        try await finish(queue)
        XCTAssertEqual(queue.items[0].runner.namedBankBalanceReadings[target.id]?.reading.balance, 125)
        XCTAssertEqual(queue.items[0].runner.namedBankBalanceReadings[target.id]?.reading.added, 25)
        XCTAssertEqual(queue.items[1].runner.namedBankBalanceReadings[target.id]?.reading.balance, 1005)
        XCTAssertEqual(queue.items[1].runner.namedBankBalanceReadings[target.id]?.reading.added, 5)
        XCTAssertTrue(queue.items[0].runner.events.contains { $0.message.contains("key(12)") })
        XCTAssertFalse(queue.items[0].runner.events.contains { $0.message.contains("key(13)") })
    }

    @MainActor func testPreflightRejectsDuplicateWindowsDryRunAndMissingConsentWithoutFocusing() async {
        let ledger = QueueInputLedger(); let a = QueueTestIO(1, ledger); let b = QueueTestIO(2, ledger)
        let first = profile("A", key: 12); let second = profile("B", key: 13)
        let queue = WindowMacroQueue()
        XCTAssertThrowsError(try queue.start([.init(profile: first, windowID: 1, io: a),
                                             .init(profile: second, windowID: 1, io: b)], inputConsent: true))
        XCTAssertThrowsError(try queue.start([.init(profile: first, windowID: 1, io: a)], inputConsent: false))
        XCTAssertThrowsError(try queue.start([.init(profile: first, windowID: 0, io: a)], inputConsent: true))
        XCTAssertThrowsError(try queue.start([.init(profile: first, windowID: 1, io: a),
                                             .init(profile: second, windowID: 2, io: a)], inputConsent: true))
        var dry = first; dry.configuration.dryRun = true
        XCTAssertThrowsError(try queue.start([.init(profile: dry, windowID: 1, io: a)], inputConsent: true))
        XCTAssertFalse(queue.active); XCTAssertEqual(a.focusCalls, 0); XCTAssertEqual(b.focusCalls, 0)
    }

    func testProfileStorePreservesSeparateRecordingsCalibrationAndRepeatLimitsWithoutWindowIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WindowMacroProfileStore(url: directory.appendingPathComponent("profiles.json"))
        XCTAssertTrue(try store.load().isEmpty)
        var first = profile("A", key: 12, count: 3); let second = profile("B", key: 13)
        first.calibration.targets = [.init(role: .bankTitle,
            region: try NormalizedRegion(x: 0.1, y: 0.2, width: 0.2, height: 0.1), expectedText: "Jewel bank")]
        try store.save([first, second])
        let loaded = try store.load()
        XCTAssertEqual(loaded.map(\.id), [first.id, second.id])
        XCTAssertEqual(loaded[0].settings.bankingRecording?.steps.first?.action, .key(12))
        XCTAssertEqual(loaded[1].settings.bankingRecording?.steps.first?.action, .key(13))
        XCTAssertEqual(loaded[0].settings.macroRepeat.count, 3)
        XCTAssertEqual(loaded[0].calibration.targets.first?.expectedText, "Jewel bank")
        XCTAssertTrue(loaded[1].calibration.targets.isEmpty)
        let saved = try String(contentsOf: store.url)
        XCTAssertFalse(saved.contains("windowID")); XCTAssertFalse(saved.contains("inputConsent"))
        XCTAssertThrowsError(try store.save([first, first]))
        XCTAssertEqual(try store.load().count, 2, "Invalid updates must preserve the previous file")
    }
}

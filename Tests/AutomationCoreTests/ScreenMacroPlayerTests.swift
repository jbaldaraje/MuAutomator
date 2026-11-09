import XCTest
@testable import AutomationCore

@MainActor
private final class DesktopTestIO: ScreenMacroIO {
    var events: [ScreenEvent] = []
    var heldKeys: Set<UInt16> = []
    var releases = 0
    var currentWindow = "A"
    var physicalPointer = ScreenPoint(x: 1, y: 1)
    var valid = true
    var onEvent: (() -> Void)?
    func validate(layout: ScreenLayout) throws {
        if !valid { throw ScreenMacroError.invalid("Desktop changed or permission revoked") }
    }
    func perform(_ event: ScreenEvent) throws {
        events.append(event)
        switch event.action {
        case .keyDown(let code, _): heldKeys.insert(code)
        case .keyUp(let code): heldKeys.remove(code)
        default: break
        }
        onEvent?()
    }
    func releaseAll() { heldKeys.removeAll(); releases += 1 }
}

final class ScreenMacroPlayerTests: XCTestCase {
    private func macro(duration: Double = 0.03) -> ScreenMacro {
        ScreenMacro(layout: .init(displays: [.init(x: 0, y: 0, width: 1000, height: 700)]), events: [
            .init(time: 0, action: .keyDown(code: 12, repeatKey: false)),
            .init(time: duration * 0.8, action: .keyUp(code: 12))], duration: duration)
    }
    @MainActor private func until(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(2)
        while !condition(), Date() < end { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(condition())
    }
    @MainActor func testPhysicalCursorMovementAndChangingWindowsNeverStopReplay() async throws {
        let player = ScreenMacroPlayer(); let io = DesktopTestIO()
        io.onEvent = { io.currentWindow = "Another app"; io.physicalPointer = .init(x: 900, y: 600) }
        try player.start(macro(), hours: 0.02 / 3600, io: io, countdown: 0)
        try await until { !player.active }
        XCTAssertEqual(player.phase, .completed)
        XCTAssertEqual(io.events.count, 2)
        XCTAssertEqual(player.completedCycles, 1)
        XCTAssertTrue(io.heldKeys.isEmpty)
    }
    @MainActor func testHoursRepeatMultipleCompleteCyclesAndKeepEventOrder() async throws {
        let player = ScreenMacroPlayer(); let io = DesktopTestIO()
        try player.start(macro(), hours: 0.1 / 3600, io: io, countdown: 0)
        try await until { !player.active }
        XCTAssertEqual(player.phase, .completed)
        XCTAssertGreaterThanOrEqual(player.completedCycles, 2)
        XCTAssertEqual(io.events.count, player.completedCycles * 2)
        for pair in stride(from: 0, to: io.events.count, by: 2) {
            XCTAssertEqual(io.events[pair].action, .keyDown(code: 12, repeatKey: false))
            XCTAssertEqual(io.events[pair + 1].action, .keyUp(code: 12))
        }
        XCTAssertGreaterThanOrEqual(player.elapsed, 0.1)
    }
    @MainActor func testStopDuringHeldKeyReleasesImmediatelyAndDoesNotRepeat() async throws {
        let player = ScreenMacroPlayer(); let io = DesktopTestIO()
        try player.start(macro(duration: 1), hours: 1, io: io, countdown: 0)
        try await until { !io.heldKeys.isEmpty }
        player.stop()
        XCTAssertTrue(io.heldKeys.isEmpty)
        try await until { !player.active }
        XCTAssertEqual(player.phase, .stopped)
        XCTAssertEqual(io.events.count, 1)
        XCTAssertEqual(player.completedCycles, 0)
    }
    @MainActor func testCancelledCountdownNeverInjectsInput() async throws {
        let player = ScreenMacroPlayer(); let io = DesktopTestIO()
        try player.start(macro(), hours: 1, io: io, countdown: 5)
        player.stop()
        try await until { !player.active }
        XCTAssertTrue(io.events.isEmpty)
        XCTAssertEqual(player.phase, .stopped)
    }
    @MainActor func testDesktopOrPermissionFailureStopsAndReleasesWithoutRetry() async throws {
        let player = ScreenMacroPlayer(); let io = DesktopTestIO()
        io.onEvent = { io.valid = false }
        try player.start(macro(), hours: 1, io: io, countdown: 0)
        try await until { !player.active }
        XCTAssertEqual(player.phase, .failed)
        XCTAssertEqual(io.events.count, 1)
        XCTAssertTrue(io.heldKeys.isEmpty)
        XCTAssertNotNil(player.error)
    }
    @MainActor func testInvalidMacroOrHoursAreRejectedBeforeAnyInput() async throws {
        let player = ScreenMacroPlayer(); let io = DesktopTestIO()
        for hours in [0, -1, .nan, .infinity, 8761] { XCTAssertThrowsError(try player.start(macro(), hours: hours, io: io)) }
        var invalid = macro(); invalid.events.removeLast()
        XCTAssertThrowsError(try player.start(invalid, hours: 1, io: io))
        XCTAssertTrue(io.events.isEmpty); XCTAssertFalse(player.active)
    }
    @MainActor func testConcurrentPlaybackIsRejectedAndNewRunCanStartAfterStop() async throws {
        let player = ScreenMacroPlayer(); let io = DesktopTestIO()
        try player.start(macro(), hours: 1, io: io, countdown: 5)
        XCTAssertThrowsError(try player.start(macro(), hours: 1, io: io))
        player.stop(); try await until { !player.active }
        try player.start(macro(), hours: 0.001 / 3600, io: io, countdown: 0)
        try await until { !player.active }
        XCTAssertEqual(player.phase, .completed); XCTAssertEqual(player.completedCycles, 1)
    }
    @MainActor func testStopCanInterruptAZeroDelayBurstWithoutRunningAllEvents() async throws {
        let player = ScreenMacroPlayer(); let io = DesktopTestIO()
        let burst = ScreenMacro(layout: macro().layout, events: (0..<4096).map { _ in
            ScreenEvent(time: 0, action: .move(.init(x: 10, y: 20)))
        }, duration: 0.1)
        try player.start(burst, hours: 1, io: io, countdown: 0)
        let stop = Task { @MainActor in
            while io.events.isEmpty { await Task.yield() }
            player.stop()
        }
        await stop.value
        try await until { !player.active }
        XCTAssertEqual(player.phase, .stopped)
        XCTAssertLessThan(io.events.count, 4096)
    }

}

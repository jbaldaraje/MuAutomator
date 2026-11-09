import XCTest
@testable import AutomationCore

final class ScreenMacroTests: XCTestCase {
    private let layout = ScreenLayout(displays: [ScreenBounds(x: -500, y: 0, width: 500, height: 600),
                                                ScreenBounds(x: 0, y: 0, width: 1000, height: 700)])
    private let point = ScreenPoint(x: 100, y: 200)

    func testFullDesktopRecordsCrossScreenMovesDragKeyboardChordAndScrollWithTiming() throws {
        var buffer = ScreenMacroBuffer(layout: layout)
        let events: [ScreenEvent] = [
            .init(time: 0, action: .move(.init(x: -200, y: 20))),
            .init(time: 0.1, action: .mouseDown(button: 0, point: .init(x: -200, y: 20), clicks: 1)),
            .init(time: 0.2, action: .move(point)),
            .init(time: 0.3, action: .mouseUp(button: 0, point: point, clicks: 1)),
            .init(time: 0.4, action: .flagsChanged(code: 55), modifiers: 1 << 20),
            .init(time: 0.5, action: .keyDown(code: 8, repeatKey: false), modifiers: 1 << 20),
            .init(time: 0.6, action: .keyUp(code: 8), modifiers: 1 << 20),
            .init(time: 0.7, action: .flagsChanged(code: 55)),
            .init(time: 0.8, action: .scroll(x: -3, y: 20, pixels: true))
        ]
        for event in events { try buffer.append(event) }
        let macro = try buffer.finish(at: 1.2)
        XCTAssertEqual(macro.events, events)
        XCTAssertEqual(macro.duration, 1.2)
        let decoded = try JSONDecoder().decode(ScreenMacro.self, from: JSONEncoder().encode(macro))
        try decoded.validate(); XCTAssertEqual(decoded, macro)
    }
    func testFinishBalancesHeldKeysButtonsAndModifiers() throws {
        var buffer = ScreenMacroBuffer(layout: layout)
        try buffer.append(.init(time: 0, action: .flagsChanged(code: 56), modifiers: 1 << 17))
        try buffer.append(.init(time: 0.1, action: .keyDown(code: 12, repeatKey: false), modifiers: 1 << 17))
        try buffer.append(.init(time: 0.2, action: .mouseDown(button: 1, point: point, clicks: 1), modifiers: 1 << 17))
        let macro = try buffer.finish(at: 2)
        XCTAssertTrue(macro.events.contains { $0.action == .keyUp(code: 12) && $0.time == 2 })
        XCTAssertTrue(macro.events.contains { $0.action == .mouseUp(button: 1, point: point, clicks: 1) && $0.time == 2 })
        XCTAssertEqual(macro.events.last?.modifiers, 0)
        try macro.validate()
    }
    func testFinishingHotkeyIsTrimmedWithoutLosingEarlierTailWait() throws {
        var buffer = ScreenMacroBuffer(layout: layout)
        try buffer.append(.init(time: 0, action: .flagsChanged(code: 55), modifiers: 1 << 20))
        try buffer.append(.init(time: 0.1, action: .keyDown(code: 8, repeatKey: false), modifiers: 1 << 20))
        try buffer.append(.init(time: 0.2, action: .keyUp(code: 8), modifiers: 1 << 20))
        try buffer.append(.init(time: 0.3, action: .flagsChanged(code: 55)))
        try buffer.append(.init(time: 6, action: .flagsChanged(code: 59), modifiers: 1 << 18))
        try buffer.append(.init(time: 6.1, action: .flagsChanged(code: 58), modifiers: (1 << 18) | (1 << 19)))
        try buffer.append(.init(time: 6.2, action: .flagsChanged(code: 55), modifiers: (1 << 18) | (1 << 19) | (1 << 20)))
        let macro = try buffer.finish(at: 6.3, trimmingStopShortcut: true)
        XCTAssertEqual(macro.duration, 6)
        XCTAssertEqual(macro.events.count, 4)
        XCTAssertEqual(macro.events.last?.time, 0.3)
    }
    func testMouseMovesAreThrottledButClicksAndFinalPositionsArePreserved() throws {
        var buffer = ScreenMacroBuffer(layout: layout)
        try buffer.append(.init(time: 0, action: .move(point)))
        try buffer.append(.init(time: 0.001, action: .move(.init(x: 101, y: 200))))
        try buffer.append(.init(time: 0.002, action: .mouseDown(button: 0, point: .init(x: 102, y: 200), clicks: 1)))
        try buffer.append(.init(time: 0.003, action: .mouseUp(button: 0, point: .init(x: 103, y: 200), clicks: 1)))
        let macro = try buffer.finish(at: 0.1)
        XCTAssertEqual(macro.events.count, 3)
        XCTAssertEqual(macro.events.last?.action.point?.x, 103)
    }
    func testUnmatchedReleasesAndRepeatsAtRecordingStartAreIgnored() throws {
        var buffer = ScreenMacroBuffer(layout: layout)
        try buffer.append(.init(time: 0, action: .keyUp(code: 12)))
        try buffer.append(.init(time: 0.01, action: .keyDown(code: 12, repeatKey: true)))
        try buffer.append(.init(time: 0.02, action: .mouseUp(button: 0, point: point, clicks: 1)))
        try buffer.append(.init(time: 0.03, action: .keyDown(code: 12, repeatKey: false)))
        try buffer.append(.init(time: 0.04, action: .keyDown(code: 12, repeatKey: true)))
        try buffer.append(.init(time: 0.05, action: .keyUp(code: 12)))
        XCTAssertEqual(try buffer.finish(at: 0.1).events.count, 3)
    }
    func testRejectsBadTimingUnbalancedInputAndInvalidPositions() throws {
        let good: [ScreenEvent] = [.init(time: 0.1, action: .keyDown(code: 12, repeatKey: false)),
                                   .init(time: 0.2, action: .keyUp(code: 12))]
        let badEvents: [[ScreenEvent]] = [
            [], [.init(time: -.infinity, action: .move(point))],
            [.init(time: 0, action: .move(.init(x: 5000, y: 20)))],
            [.init(time: 0.3, action: .move(point)), .init(time: 0.1, action: .move(point))],
            [.init(time: 0, action: .keyDown(code: 12, repeatKey: false))],
            [.init(time: 0, action: .keyUp(code: 12))],
            [.init(time: 0, action: .flagsChanged(code: 12))],
            [.init(time: 0, action: .move(point), modifiers: 1)],
            [.init(time: 0, action: .mouseDown(button: 32, point: point, clicks: 1))],
            [.init(time: 0, action: .keyDown(code: 12, repeatKey: true))],
            [.init(time: 0, action: .scroll(x: .min, y: 0, pixels: false))]
        ]
        for events in badEvents { XCTAssertThrowsError(try ScreenMacro(layout: layout, events: events, duration: 1).validate()) }
        for duration in [0, -1, .nan, .infinity, ScreenMacro.maximumDuration + 1] {
            XCTAssertThrowsError(try ScreenMacro(layout: layout, events: good, duration: duration).validate())
        }
        var unsupported = ScreenMacro(layout: layout, events: good, duration: 1); unsupported.version = 2
        XCTAssertThrowsError(try unsupported.validate())
    }
    func testDisplayMatchingIsOrderIndependentAndChecksArrangementNotIdentity() throws {
        XCTAssertTrue(layout.matches(ScreenLayout(displays: layout.displays.reversed())))
        var changed = layout; changed.displays[0].x -= 20
        XCTAssertFalse(layout.matches(changed))
        XCTAssertFalse(layout.matches(ScreenLayout(displays: [layout.displays[0]])))
        let gap = ScreenLayout(displays: [.init(x: 0, y: 0, width: 100, height: 100), .init(x: 200, y: 0, width: 100, height: 100)])
        XCTAssertFalse(gap.contains(.init(x: 150, y: 50)))
        XCTAssertThrowsError(try ScreenLayout(displays: []).validate())
        XCTAssertThrowsError(try ScreenLayout(displays: [.init(x: .nan, y: 0, width: 1, height: 1)]).validate())
    }
    func testBufferRejectsOutOfOrderAndNonfiniteEndTimes() throws {
        var buffer = ScreenMacroBuffer(layout: layout)
        try buffer.append(.init(time: 1, action: .move(point)))
        XCTAssertThrowsError(try buffer.append(.init(time: 0.5, action: .move(point))))
        XCTAssertThrowsError(try buffer.finish(at: 0.5))
        XCTAssertThrowsError(try buffer.finish(at: .nan))
    }
}

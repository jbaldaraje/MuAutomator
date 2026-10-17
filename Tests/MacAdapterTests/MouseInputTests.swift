import XCTest
import CoreGraphics
@testable import MUAutomator
import AutomationCore

final class MouseInputTests: XCTestCase {
    @MainActor func testInterruptedRecordedKeyHoldReleasesKey() async {
        var events: [CGEventType] = []
        do {
            try await MacMouseInput.key(code: 12, source: nil, post: { events.append($0.type) },
                                       whileHeld: { throw WorkflowFailure.unsafe("Focus lost") }, check: {})
            XCTFail("Expected interrupted hold")
        } catch { XCTAssertEqual(events, [.keyDown, .keyUp]) }
    }

    @MainActor func testInterruptedRecordedMouseHoldReleasesButton() async {
        var events: [CGEventType] = []
        do {
            try await MacMouseInput.click(at: CGPoint(x: 100, y: 100), source: nil, settleNanoseconds: 0,
                                         post: { events.append($0.type) },
                                         whileHeld: { throw WorkflowFailure.unsafe("Focus lost") }, check: {})
            XCTFail("Expected interrupted hold")
        } catch { XCTAssertEqual(events, [.mouseMoved, .leftMouseDown, .leftMouseUp]) }
    }

    @MainActor func testMovePrecedesPressAndReleaseAtSameGlobalPoint() async throws {
        let point = CGPoint(x: -350.5, y: 127.25)
        var events: [CGEvent] = []
        try await MacMouseInput.click(at: point, source: nil, settleNanoseconds: 0, holdNanoseconds: 0,
                                     post: { events.append($0) }, check: {})
        XCTAssertEqual(events.map(\.type), [.mouseMoved, .leftMouseDown, .leftMouseUp])
        XCTAssertTrue(events.allSatisfy { $0.location == point })
        XCTAssertEqual(events[1].getIntegerValueField(.mouseEventClickState), 1)
        XCTAssertEqual(events[2].getIntegerValueField(.mouseEventClickState), 1)
    }

    @MainActor func testLosingWindowDuringPointerMovementPreventsPress() async {
        var events: [CGEventType] = [], checks = 0
        do {
            try await MacMouseInput.click(at: CGPoint(x: 100, y: 100), source: nil, settleNanoseconds: 0,
                                         post: { events.append($0.type) }) {
                checks += 1
                if checks == 2 { throw WorkflowFailure.unsafe("Another window covers the point") }
            }
            XCTFail("Expected focus/occlusion check to block the press")
        } catch {
            XCTAssertEqual(events, [.mouseMoved])
        }
    }

    @MainActor func testCancellationAfterPressStillReleasesButton() async {
        var events: [CGEventType] = []
        var task: Task<Void, Error>?
        task = Task { @MainActor in
            try await MacMouseInput.click(at: CGPoint(x: 100, y: 100), source: nil, settleNanoseconds: 0,
                                         post: { event in
                events.append(event.type)
                if event.type == .leftMouseDown { task?.cancel() }
            }, check: {})
        }
        do { try await task?.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(events, [.mouseMoved, .leftMouseDown, .leftMouseUp])
    }

    @MainActor func testHitTestUsesFrontWindowAtPointIncludingNegativeDisplayOrigin() {
        func window(_ id: UInt32, _ bounds: CGRect, alpha: Double = 1) -> [String: Any] {
            [kCGWindowNumber as String: NSNumber(value: id), kCGWindowAlpha as String: NSNumber(value: alpha),
             kCGWindowBounds as String: bounds.dictionaryRepresentation]
        }
        let game = window(9294, CGRect(x: -1200, y: 0, width: 1000, height: 800))
        let covering = window(42, CGRect(x: -600, y: 100, width: 200, height: 200))
        XCTAssertEqual(MacWorkflowIO.topWindow(at: CGPoint(x: -500, y: 200), windows: [covering, game]), 42)
        XCTAssertEqual(MacWorkflowIO.topWindow(at: CGPoint(x: -900, y: 200), windows: [covering, game]), 9294)
        XCTAssertNil(MacWorkflowIO.topWindow(at: CGPoint(x: 0, y: 200), windows: [covering, game]))
        let transparent = window(43, CGRect(x: -1200, y: 0, width: 1000, height: 800), alpha: 0)
        XCTAssertEqual(MacWorkflowIO.topWindow(at: CGPoint(x: -900, y: 200), windows: [transparent, game]), 9294)
    }
}

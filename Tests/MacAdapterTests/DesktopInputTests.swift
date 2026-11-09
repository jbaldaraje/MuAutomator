import AppKit
import XCTest
import AutomationCore
@testable import MUAutomator

final class DesktopInputTests: XCTestCase {
    private let layout = ScreenLayout(displays: [.init(x: 0, y: 0, width: 1000, height: 700)])

    @MainActor func testAbsoluteDesktopPositionsDragsOtherButtonsAndCleanup() async throws {
        var events: [CGEvent] = []
        let io = DesktopInput(post: { events.append($0) }, displays: { self.layout }, permitted: { true })
        try io.validate(layout: layout)
        try io.perform(.init(time: 0, action: .mouseDown(button: 3, point: .init(x: 100, y: 200), clicks: 2)))
        try io.perform(.init(time: 0.1, action: .move(.init(x: 300, y: 400))))
        try io.perform(.init(time: 0.2, action: .keyDown(code: 12, repeatKey: false)))
        io.releaseAll()
        XCTAssertEqual(events.map(\.type), [.otherMouseDown, .otherMouseDragged, .keyDown, .otherMouseUp, .keyUp])
        XCTAssertEqual(events[0].location.x, 100)
        XCTAssertEqual(events[0].location.y, 200)
        XCTAssertEqual(events[1].location.x, 300)
        XCTAssertEqual(events[0].getIntegerValueField(.mouseEventButtonNumber), 3)
        XCTAssertEqual(events[0].getIntegerValueField(.mouseEventClickState), 2)
        XCTAssertTrue(events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == DesktopInput.eventTag })
        let count = events.count; io.releaseAll(); XCTAssertEqual(events.count, count)
    }
    @MainActor func testCleanupReleasesOnlyStillInjectedKeysAndModifierGroups() async throws {
        var events: [CGEvent] = []
        let io = DesktopInput(post: { events.append($0) }, displays: { self.layout }, permitted: { true })
        try io.perform(.init(time: 0, action: .flagsChanged(code: 55), modifiers: 1 << 20))
        try io.perform(.init(time: 0.1, action: .flagsChanged(code: 56), modifiers: (1 << 20) | (1 << 17)))
        try io.perform(.init(time: 0.2, action: .flagsChanged(code: 55), modifiers: 1 << 17))
        try io.perform(.init(time: 0.3, action: .keyDown(code: 12, repeatKey: false)))
        try io.perform(.init(time: 0.4, action: .keyUp(code: 12)))
        let count = events.count; io.releaseAll()
        XCTAssertEqual(events.count, count + 1)
        XCTAssertEqual(events.last?.type, .flagsChanged)
        XCTAssertEqual(events.last?.getIntegerValueField(.keyboardEventKeycode), 56)
        XCTAssertEqual(events.last?.flags.rawValue, 0)
    }
    @MainActor func testPermissionAndDisplayFailuresPrecedeInput() async throws {
        var posts = 0
        let denied = DesktopInput(post: { _ in posts += 1 }, displays: { self.layout }, permitted: { false })
        XCTAssertThrowsError(try denied.validate(layout: layout))
        let changed = DesktopInput(post: { _ in posts += 1 }, displays: { .init(displays: []) }, permitted: { true })
        XCTAssertThrowsError(try changed.validate(layout: layout))
        XCTAssertEqual(posts, 0)
    }
    @MainActor func testNativeConversionPreservesDesktopCoordinatesAndIgnoresInjectedEvents() async throws {
        let cg = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                                      mouseCursorPosition: CGPoint(x: 200, y: 300), mouseButton: .left))
        let native = try XCTUnwrap(NSEvent(cgEvent: cg))
        let converted = try XCTUnwrap(DesktopEventCapture.convert(native, since: native.timestamp))
        XCTAssertEqual(converted.action, .move(.init(x: 200, y: 300)))
        XCTAssertEqual(converted.time, 0)
        cg.setIntegerValueField(.eventSourceUserData, value: DesktopInput.eventTag)
        XCTAssertNil(DesktopEventCapture.convert(try XCTUnwrap(NSEvent(cgEvent: cg)), since: native.timestamp))
    }
}

final class MacroWindowTests: XCTestCase {
    @MainActor func testClosingWindowHidesItInsteadOfClosingAndCanReopen() async {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 410),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let host = MacroWindowHost(); window.contentView?.addSubview(host)
        defer {
            window.delegate = nil; window.isReleasedWhenClosed = false; window.close()
            MacroAppDelegate.mainWindow = nil
            NSApplication.shared.setActivationPolicy(.regular)
        }
        window.makeKeyAndOrderFront(nil)
        MacroAppDelegate.hide()
        XCTAssertFalse(window.isVisible)
        MacroAppDelegate.show()
        XCTAssertTrue(window.isVisible)
        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(MacroAppDelegate.mainWindow === window)
        MacroAppDelegate.show()
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(MacroAppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }
}

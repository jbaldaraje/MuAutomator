import AppKit
import XCTest
@testable import MUAutomator

final class WindowCloseObservationTests: XCTestCase {
    @MainActor func testOnlyOwningWindowCloseRunsShutdown() {
        let owner = makeWindow()
        let other = makeWindow()
        var stops = 0
        let observer = WindowCloseObservationView { stops += 1 }
        owner.contentView?.addSubview(observer)

        XCTAssertEqual(stops, 0, "Mounting the screen must not stop automation")
        other.close()
        XCTAssertEqual(stops, 0, "Closing a different window must not stop automation")
        owner.close()
        XCTAssertEqual(stops, 1, "Closing the owning window must stop automation synchronously")
        observer.stopObserving()
    }

    @MainActor func testMovingViewTracksNewWindowWithoutStopping() {
        let original = makeWindow()
        let replacement = makeWindow()
        var stops = 0
        let observer = WindowCloseObservationView { stops += 1 }
        original.contentView?.addSubview(observer)
        observer.removeFromSuperview()
        replacement.contentView?.addSubview(observer)

        XCTAssertEqual(stops, 0, "Hierarchy changes must not stop automation")
        original.close()
        XCTAssertEqual(stops, 0, "The detached window must no longer own shutdown")
        replacement.close()
        XCTAssertEqual(stops, 1)
        observer.stopObserving()
    }

    @MainActor func testDismantledObserverDoesNotRunOldShutdownClosure() {
        let owner = makeWindow()
        var stops = 0
        let observer = WindowCloseObservationView { stops += 1 }
        owner.contentView?.addSubview(observer)
        observer.stopObserving()
        owner.close()
        XCTAssertEqual(stops, 0)
    }

    @MainActor private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}

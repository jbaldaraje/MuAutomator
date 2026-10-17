import XCTest
import Combine
@testable import MUAutomator

final class PermissionStatusTests: XCTestCase {
    @MainActor func testBlockedPermissionQueryKeepsMainActorAvailableAndDoesNotOverlap() async {
        let entered = expectation(description: "Background query started")
        entered.assertForOverFulfill = true
        let release = DispatchSemaphore(value: 0)
        let monitor = PermissionStatusModel {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 2)
            return (true, false)
        }
        let first = Task { await monitor.refresh() }
        await fulfillment(of: [entered], timeout: 1)
        // The main actor must remain usable while the permission service is blocked.
        XCTAssertNil(monitor.screenRecordingAllowed)
        await monitor.refresh() // Must not enter the same query a second time.
        release.signal()
        await first.value
        XCTAssertEqual(monitor.screenRecordingAllowed, true)
        XCTAssertEqual(monitor.accessibilityAllowed, false)
    }

    @MainActor func testCancelledRefreshDoesNotPublishIntoDisappearedDashboard() async {
        let entered = expectation(description: "Background query started")
        let release = DispatchSemaphore(value: 0)
        let monitor = PermissionStatusModel {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 2)
            return (true, true)
        }
        let refresh = Task { await monitor.refresh() }
        await fulfillment(of: [entered], timeout: 1)
        refresh.cancel()
        release.signal()
        await refresh.value
        XCTAssertNil(monitor.screenRecordingAllowed)
        XCTAssertNil(monitor.accessibilityAllowed)
    }

    @MainActor func testUnchangedPermissionsDoNotInvalidateViewsAgain() async {
        let monitor = PermissionStatusModel { (true, true) }
        var changes = 0
        let subscription = monitor.objectWillChange.sink { changes += 1 }
        await monitor.refresh()
        let firstRefreshChanges = changes
        XCTAssertGreaterThan(firstRefreshChanges, 0)
        await monitor.refresh()
        XCTAssertEqual(changes, firstRefreshChanges)
        withExtendedLifetime(subscription) {}
    }
}

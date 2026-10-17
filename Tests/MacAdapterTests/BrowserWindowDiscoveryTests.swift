import XCTest
import ApplicationServices
import AutomationCore
@testable import MUAutomator

final class BrowserWindowDiscoveryTests: XCTestCase {
    private let frame = CGRect(x: 100, y: 100, width: 1000, height: 700)

    func testUniqueGeometryDoesNotRequireMatchingWindowTitles() throws {
        let window = BrowserWindowCandidate(id: 1, processID: 10, title: "Loading…", bounds: frame)
        let match = try XCTUnwrap(BrowserWindowDiscovery.matchingCandidate([window], bounds: frame))
        XCTAssertEqual(match.id, 1)
    }

    func testOverlappingWindowsAreNotGuessedFromTheirTitles() {
        let game = BrowserWindowCandidate(id: 1, processID: 10, title: "open.mu", bounds: frame)
        let other = BrowserWindowCandidate(id: 2, processID: 10, title: "Another page", bounds: frame)
        XCTAssertNil(BrowserWindowDiscovery.matchingCandidate([game, other], bounds: frame))
        XCTAssertNil(BrowserWindowDiscovery.matchingCandidate([game], bounds: frame.offsetBy(dx: 5, dy: 0)))
    }

    func testColdChromeTreeIsRetriedAfterRoleRead() {
        let window = AXUIElementCreateApplication(900001)
        let web = AXUIElementCreateApplication(900002)
        var passes = 0
        let lookup = BrowserWindowDiscovery.activeDocumentURL(window, until: Date().addingTimeInterval(2), read: { node, name in
            if CFEqual(node, window) {
                if name as String == kAXRoleAttribute { passes += 1; return "AXWindow" as CFString }
                if name as String == kAXChildrenAttribute, passes >= 2 { return [web] as CFArray }
            } else if CFEqual(node, web) {
                if name as String == kAXRoleAttribute { return "AXWebArea" as CFString }
                if name as String == kAXURLAttribute { return "https://open.mu/game" as CFString }
            }
            return nil
        }, pause: {})
        XCTAssertTrue(GamePagePolicy.allows(lookup.url))
        XCTAssertEqual(passes, 2)
        XCTAssertTrue(lookup.element.map { CFEqual($0, web) } ?? false)
    }

    func testOuterDocumentWinsOverEmbeddedGameOrLink() {
        let window = AXUIElementCreateApplication(900001)
        let outer = AXUIElementCreateApplication(900002)
        let embeddedGame = AXUIElementCreateApplication(900003)
        var embeddedReads = 0
        let lookup = BrowserWindowDiscovery.activeDocumentURL(window, until: Date().addingTimeInterval(2), read: { node, name in
            if CFEqual(node, window) {
                if name as String == kAXRoleAttribute { return "AXWindow" as CFString }
                if name as String == kAXChildrenAttribute { return [outer] as CFArray }
            } else if CFEqual(node, outer) {
                if name as String == kAXRoleAttribute { return "AXWebArea" as CFString }
                if name as String == kAXURLAttribute { return "https://example.com/" as CFString }
                if name as String == kAXChildrenAttribute { return [embeddedGame] as CFArray }
            } else { embeddedReads += 1 }
            return nil
        }, pause: {})
        XCTAssertEqual(lookup.url, "https://example.com/")
        XCTAssertFalse(GamePagePolicy.allows(lookup.url))
        XCTAssertEqual(embeddedReads, 0)
    }

    func testAddressBarAndHiddenGameContentDoNotCountAsActiveDocument() {
        let window = AXUIElementCreateApplication(900001)
        let toolbar = AXUIElementCreateApplication(900002)
        let hidden = AXUIElementCreateApplication(900003)
        let addressBar = AXUIElementCreateApplication(900004)
        var addressReads = 0
        let lookup = BrowserWindowDiscovery.activeDocumentURL(window, until: Date().addingTimeInterval(2), read: { node, name in
            if CFEqual(node, window) {
                if name as String == kAXRoleAttribute { return "AXWindow" as CFString }
                if name as String == kAXChildrenAttribute { return [toolbar, hidden] as CFArray }
            } else if CFEqual(node, toolbar) {
                if name as String == kAXRoleAttribute { return "AXToolbar" as CFString }
                if name as String == kAXChildrenAttribute { return [addressBar] as CFArray }
            } else if CFEqual(node, hidden) {
                if name as String == kAXRoleAttribute { return "AXWebArea" as CFString }
                if name as String == "AXHidden" { return kCFBooleanTrue }
                if name as String == kAXURLAttribute { return "https://open.mu/" as CFString }
            } else { addressReads += 1 }
            return nil
        }, pause: {})
        XCTAssertNil(lookup.url)
        XCTAssertEqual(addressReads, 0)
    }

    func testUnreadableURLIsExcludedWithDiagnosticAndBoundedRetry() {
        let window = AXUIElementCreateApplication(900001)
        var attempts = 0
        let lookup = BrowserWindowDiscovery.activeDocumentURL(window, until: Date().addingTimeInterval(2), read: { _, name in
            if name as String == kAXRoleAttribute { attempts += 1; return "AXWebArea" as CFString }
            return nil
        }, pause: {})
        XCTAssertNil(lookup.url)
        XCTAssertEqual(attempts, 3)
        XCTAssertTrue(lookup.reason.contains("without its URL"))
    }
}

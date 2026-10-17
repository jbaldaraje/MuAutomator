import XCTest
import ApplicationServices
@testable import MUAutomator

final class BrowserWindowBindingTests: XCTestCase {
    func testThreeSameProcessGameWindowsBindSelectedIdentityWithoutReadingTitles() throws {
        // Mock AX references; no real browser, focus change or input is used.
        let windows = (0..<3).map { AXUIElementCreateApplication(pid_t(900001 + $0)) }
        let candidates = (0..<3).map {
            BrowserWindowCandidate(id: UInt32($0 + 1), processID: 7, title: "MU Online",
                                   bounds: CGRect(x: CGFloat(100 + $0 * 50), y: 100, width: 1000, height: 700))
        }
        var focusedIndex = 1
        var titleReads = 0
        let read: (AXUIElement, CFString) -> CFTypeRef? = { node, name in
            let key = name as String
            if key == kAXTitleAttribute { titleReads += 1; return "MU Online — Google Chrome" as CFString }
            if key == kAXWindowsAttribute { return windows as CFArray }
            if key == kAXFocusedWindowAttribute { return windows[focusedIndex] }
            guard let index = windows.firstIndex(where: { CFEqual($0, node) }) else { return nil }
            if key == kAXPositionAttribute {
                var point = candidates[index].bounds.origin
                return AXValueCreate(.cgPoint, &point)
            }
            if key == kAXSizeAttribute {
                var size = candidates[index].bounds.size
                return AXValueCreate(.cgSize, &size)
            }
            if key == kAXDocumentAttribute { return "https://open.mu/game" as CFString }
            return nil
        }
        let binding = try BrowserWindowDiscovery.bind(candidates[1], among: candidates, isTrusted: { true }, read: read)
        XCTAssertEqual(binding.windowID, 2)
        XCTAssertNoThrow(try BrowserWindowDiscovery.verify(binding, isTrusted: { true }, read: read))
        for other in [0, 2] {
            focusedIndex = other
            XCTAssertThrowsError(try BrowserWindowDiscovery.verify(binding, isTrusted: { true }, read: read))
        }
        XCTAssertEqual(titleReads, 0, "Display titles must not determine identity")
    }

    func testSelectedDocumentRetainsIdentityAcrossEquivalentAddressSpelling() {
        let window = AXUIElementCreateApplication(900001)
        let page = AXUIElementCreateApplication(900002)
        let binding = BrowserWindowBinding(windowID: 2, processID: 7, windowElement: window,
                                           documentElement: page, documentURL: "https://open.mu/game")
        XCTAssertNoThrow(try binding.requireFocusedWindow(window))
        XCTAssertNoThrow(try binding.requireSameDocument(url: "https://OPEN.MU:443/game", element: page))
        XCTAssertThrowsError(try binding.requireSameDocument(url: "https://open.mu/another", element: page))
    }

    func testAnotherTabOrReloadWithIdenticalURLDoesNotReplaceSelectedDocument() {
        let page = AXUIElementCreateApplication(900002)
        let replacement = AXUIElementCreateApplication(900003)
        let binding = BrowserWindowBinding(windowID: 2, processID: 7,
                                           windowElement: AXUIElementCreateApplication(900001),
                                           documentElement: page, documentURL: "https://open.mu/game")
        XCTAssertThrowsError(try binding.requireSameDocument(url: "https://open.mu/game", element: replacement))
        XCTAssertThrowsError(try binding.requireSameDocument(url: "https://open.mu/game", element: nil))
    }

    func testWindowDocumentFallbackStillRejectsMissingURLAndOtherOrigins() {
        let binding = BrowserWindowBinding(windowID: 2, processID: 7,
                                           windowElement: AXUIElementCreateApplication(900001),
                                           documentElement: nil, documentURL: "https://open.mu/game")
        XCTAssertNoThrow(try binding.requireSameDocument(url: "https://open.mu/game", element: nil))
        XCTAssertThrowsError(try binding.requireSameDocument(url: nil, element: nil))
        XCTAssertThrowsError(try binding.requireSameDocument(url: "https://example.com/game", element: nil))
    }

    func testPinnedWebAreaIsNotReplacedByNewlyAvailableWindowMetadata() {
        let window = AXUIElementCreateApplication(900001)
        let page = AXUIElementCreateApplication(900002)
        let binding = BrowserWindowBinding(windowID: 2, processID: 7, windowElement: window,
                                           documentElement: page, documentURL: "https://open.mu/game")
        let read: (AXUIElement, CFString) -> CFTypeRef? = { node, name in
            let key = name as String
            if key == kAXFocusedWindowAttribute { return window }
            if CFEqual(node, window) {
                if key == kAXDocumentAttribute { return "https://open.mu/game" as CFString }
                if key == kAXRoleAttribute { return "AXWindow" as CFString }
                if key == kAXChildrenAttribute { return [page] as CFArray }
            }
            if CFEqual(node, page) {
                if key == kAXRoleAttribute { return "AXWebArea" as CFString }
                if key == kAXURLAttribute { return "https://open.mu/game" as CFString }
            }
            return nil
        }
        XCTAssertNoThrow(try BrowserWindowDiscovery.verify(binding, isTrusted: { true }, read: read))
    }
}

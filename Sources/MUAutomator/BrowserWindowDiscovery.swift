import AppKit
import ApplicationServices
import ScreenCaptureKit
import AutomationCore

struct BrowserWindowCandidate: Sendable {
    let id: UInt32
    let processID: Int32
    let title: String?
    let bounds: CGRect

    init?(_ window: SCWindow) {
        guard let app = window.owningApplication,
              BrowserWindowDiscovery.browserBundleIDs.contains(app.bundleIdentifier) else { return nil }
        id = window.windowID; processID = app.processID
        title = window.title; bounds = window.frame
    }
}

enum BrowserWindowDiscovery {
    static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi", "org.mozilla.firefox"
    ]

    /// Public Accessibility metadata only. Never reads address-bar text or page
    /// links, which can contain open.mu without being the active document.
    static func matchingWindowIDs(_ candidates: [BrowserWindowCandidate]) -> Set<UInt32> {
        guard AXIsProcessTrusted() else { return [] }
        var result: Set<UInt32> = []
        for (pid, group) in Dictionary(grouping: candidates, by: \.processID) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.15)
            guard let accessibleWindows = attribute(app, kAXWindowsAttribute as CFString) as? [AXUIElement] else { continue }
            let until = Date().addingTimeInterval(2)
            for window in accessibleWindows {
                guard Date() < until else { break }
                AXUIElementSetMessagingTimeout(window, 0.15)
                guard let frame = bounds(window) else { continue }
                let title = attribute(window, kAXTitleAttribute as CFString) as? String
                let matches = group.filter { candidate in
                    sameBounds(candidate.bounds, frame)
                        && (candidate.title?.isEmpty != false || candidate.title == title)
                }
                // Overlapping indistinguishable windows cannot be mapped safely.
                guard matches.count == 1, let candidate = matches.first,
                      let url = activeDocumentURL(window, until: until), GamePagePolicy.allows(url) else { continue }
                result.insert(candidate.id)
            }
        }
        return result
    }

    static func focusedWindowIsGame(_ candidate: BrowserWindowCandidate) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(candidate.processID)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let value = attribute(app, kAXFocusedWindowAttribute as CFString), CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        let window = value as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.15)
        guard let frame = bounds(window), sameBounds(frame, candidate.bounds),
              candidate.title?.isEmpty != false || candidate.title == (attribute(window, kAXTitleAttribute as CFString) as? String),
              let url = activeDocumentURL(window, until: Date().addingTimeInterval(1)) else { return false }
        return GamePagePolicy.allows(url)
    }

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private static func address(_ value: CFTypeRef?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? URL { return value.absoluteString }
        return nil
    }

    private static func activeDocumentURL(_ window: AXUIElement, until: Date) -> String? {
        // AXDocument is window-scoped and provided by browsers such as Safari.
        if let document = address(attribute(window, kAXDocumentAttribute as CFString)), URL(string: document)?.scheme != nil {
            return document
        }
        var queue: [AXUIElement] = [window]
        var cursor = 0
        while cursor < queue.count && cursor < 300 && Date() < until {
            let element = queue[cursor]; cursor += 1
            AXUIElementSetMessagingTimeout(element, 0.15)
            if (attribute(element, kAXRoleAttribute as CFString) as? String) == "AXWebArea" {
                // Do not descend into links or embedded frames within the page.
                return address(attribute(element, kAXURLAttribute as CFString))
            }
            if let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(max(0, 300 - queue.count)))
            }
        }
        return nil
    }

    private static func bounds(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute as CFString), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute as CFString), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        // CF types are checked above before bridging.
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func sameBounds(_ left: CGRect, _ right: CGRect) -> Bool {
        abs(left.minX - right.minX) < 2 && abs(left.minY - right.minY) < 2
            && abs(left.width - right.width) < 2 && abs(left.height - right.height) < 2
    }
}

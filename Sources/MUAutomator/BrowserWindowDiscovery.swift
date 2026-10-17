import AppKit
import ApplicationServices
import ScreenCaptureKit
import AutomationCore

struct BrowserWindowCandidate: Sendable {
    let id: UInt32
    let processID: Int32
    let title: String?
    let bounds: CGRect

    init(id: UInt32, processID: Int32, title: String?, bounds: CGRect) {
        self.id = id; self.processID = processID; self.title = title; self.bounds = bounds
    }

    init?(_ window: SCWindow) {
        guard let app = window.owningApplication,
              BrowserWindowDiscovery.browserBundleIDs.contains(app.bundleIdentifier) else { return nil }
        id = window.windowID; processID = app.processID
        title = window.title; bounds = window.frame
    }
}

/// AX references are immutable identities; public AX functions may query them
/// from the background verifier or main-actor input gate. No mutable UI state
/// is shared through this value.
struct BrowserWindowBinding: @unchecked Sendable {
    let windowID: UInt32
    let processID: Int32
    let windowElement: AXUIElement
    let documentElement: AXUIElement?
    let documentURL: String

    func requireFocusedWindow(_ focused: AXUIElement) throws {
        guard CFEqual(windowElement, focused) else {
            throw WorkflowFailure.unsafe("Another browser window has focus. Focus selected game window \(windowID), then start/resume again.")
        }
    }

    func requireSameDocument(url: String?, element: AXUIElement?) throws {
        guard GamePagePolicy.sameDocument(documentURL, url) else {
            throw WorkflowFailure.unsafe("Selected game page changed or its URL is unreadable. Restore the selected game tab and start again.")
        }
        if let documentElement {
            guard let element, CFEqual(documentElement, element) else {
                throw WorkflowFailure.unsafe("Selected game tab changed or reloaded. Review detection and start again.")
            }
        }
    }
}

enum BrowserWindowDiscovery {
    static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi", "org.mozilla.firefox"
    ]

    struct Report: Sendable {
        var windowIDs: Set<UInt32> = []
        var details: [String] = []
    }

    /// Public Accessibility metadata only. Never reads address-bar text or page
    /// links, which can contain open.mu without being the active document.
    static func matchingWindowIDs(_ candidates: [BrowserWindowCandidate]) -> Set<UInt32> {
        inspect(candidates).windowIDs
    }

    static func inspect(_ candidates: [BrowserWindowCandidate]) -> Report {
        var report = Report()
        guard AXIsProcessTrusted() else {
            report.details.append("Accessibility access is missing for this copy of MU Automator.")
            return report
        }
        if candidates.isEmpty {
            report.details.append("ScreenCaptureKit reported no supported browser windows.")
        }
        for (pid, group) in Dictionary(grouping: candidates, by: \.processID).sorted(by: { $0.key < $1.key }) {
            let app = AXUIElementCreateApplication(pid)
            // Chromium activates native accessibility when its application role
            // is read. Querying only AXWindows can leave its web tree dormant.
            _ = attribute(app, kAXRoleAttribute as CFString)
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            guard error == .success, let accessibleWindows = value as? [AXUIElement] else {
                report.details.append("Browser PID \(pid): cannot read AXWindows (AX error \(error.rawValue)).")
                continue
            }
            let appDeadline = Date().addingTimeInterval(8)
            let frames = accessibleWindows.map { Date() < appDeadline ? bounds($0) : nil }
            var inspected: Set<UInt32> = []
            for (index, window) in accessibleWindows.enumerated() {
                guard Date() < appDeadline else { break }
                guard let frame = frames[index],
                      let candidate = matchingCandidate(group, bounds: frame) else { continue }
                // A unique SCWindow must also have exactly one AX window at its
                // bounds. Never guess between overlapping browser windows.
                guard frames.compactMap({ $0 }).filter({ sameBounds($0, frame) }).count == 1 else { continue }
                inspected.insert(candidate.id)
                let lookup = activeDocumentURL(window, until: min(appDeadline, Date().addingTimeInterval(2)))
                if GamePagePolicy.allows(lookup.url) {
                    report.windowIDs.insert(candidate.id)
                    report.details.append("Window \(candidate.id): verified active https://open.mu document.")
                } else {
                    report.details.append("Window \(candidate.id): \(lookup.reason)")
                }
            }
            for candidate in group where !inspected.contains(candidate.id) {
                let matches = frames.compactMap { $0 }.filter { sameBounds($0, candidate.bounds) }
                let reason: String
                if Date() >= appDeadline {
                    reason = "Browser lookup timed out before this window was inspected. Restore the game window and refresh."
                } else if matches.isEmpty {
                    reason = "No matching Accessibility window bounds among \(accessibleWindows.count) browser windows. Restore the game window and refresh."
                } else {
                    reason = "Browser windows have indistinguishable bounds. Move overlapping windows apart, then refresh."
                }
                report.details.append("Window \(candidate.id): \(reason)")
            }
        }
        return report
    }

    // Titles can differ between ScreenCaptureKit and AX, or change while the
    // page loads. Same-process, unique geometry identifies the discovery window.
    // URL verification is still required before admitting it to the picker.
    static func matchingCandidate(_ candidates: [BrowserWindowCandidate], bounds: CGRect) -> BrowserWindowCandidate? {
        let matches = candidates.filter { sameBounds($0.bounds, bounds) }
        return matches.count == 1 ? matches.first : nil
    }

    static func bind(_ candidate: BrowserWindowCandidate, among candidates: [BrowserWindowCandidate],
                     isTrusted: () -> Bool = { AXIsProcessTrusted() },
                     read: (AXUIElement, CFString) -> CFTypeRef? = attribute) throws -> BrowserWindowBinding {
        guard isTrusted() else { throw WorkflowFailure.prerequisite("Accessibility access is missing") }
        let group = candidates.filter { $0.processID == candidate.processID }
        guard matchingCandidate(group, bounds: candidate.bounds)?.id == candidate.id else {
            throw WorkflowFailure.prerequisite("Cannot uniquely identify selected game window \(candidate.id). Move overlapping Chrome windows apart, then refresh selection.")
        }
        let app = AXUIElementCreateApplication(candidate.processID)
        _ = read(app, kAXRoleAttribute as CFString)
        guard let windows = read(app, kAXWindowsAttribute as CFString) as? [AXUIElement] else {
            throw WorkflowFailure.prerequisite("Cannot read browser windows through Accessibility")
        }
        let matches = windows.filter { window in
            guard let frame = bounds(window, read: read) else { return false }
            return sameBounds(frame, candidate.bounds)
        }
        guard matches.count == 1, let selected = matches.first else {
            throw WorkflowFailure.prerequisite("Cannot uniquely match selected game window \(candidate.id) to Chrome. Restore it and move overlapping windows apart, then refresh.")
        }
        let document = activeDocumentURL(selected, until: Date().addingTimeInterval(2), read: read)
        guard GamePagePolicy.allows(document.url), let url = document.url else {
            throw WorkflowFailure.prerequisite("Selected window \(candidate.id): \(document.reason)")
        }
        return BrowserWindowBinding(windowID: candidate.id, processID: candidate.processID,
                                    windowElement: selected, documentElement: document.element, documentURL: url)
    }

    static func verify(_ binding: BrowserWindowBinding, isTrusted: () -> Bool = { AXIsProcessTrusted() },
                       read: (AXUIElement, CFString) -> CFTypeRef? = attribute) throws {
        guard isTrusted() else { throw WorkflowFailure.unsafe("Accessibility access was revoked") }
        let app = AXUIElementCreateApplication(binding.processID)
        guard let value = read(app, kAXFocusedWindowAttribute as CFString),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw WorkflowFailure.unsafe("Cannot verify focused browser window")
        }
        let focused = value as! AXUIElement
        try binding.requireFocusedWindow(focused)
        let document = activeDocumentURL(focused, until: Date().addingTimeInterval(1),
                                         requireWebArea: binding.documentElement != nil, read: read)
        try binding.requireSameDocument(url: document.url, element: document.element)
    }

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private static func address(_ value: CFTypeRef?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? URL { return value.absoluteString }
        return nil
    }

    struct DocumentLookup {
        let url: String?
        let reason: String
        let element: AXUIElement?

        init(url: String?, reason: String, element: AXUIElement? = nil) {
            self.url = url; self.reason = reason; self.element = element
        }
    }

    static func activeDocumentURL(
        _ window: AXUIElement, until: Date, requireWebArea: Bool = false,
        read: (AXUIElement, CFString) -> CFTypeRef? = attribute,
        pause: () -> Void = { Thread.sleep(forTimeInterval: 0.15) }
    ) -> DocumentLookup {
        var reason = "Active document URL is unavailable. Keep the game tab active and refresh after Chrome finishes loading."
        // Reading the web-content container's role can start Chromium's renderer
        // accessibility tree asynchronously. Retry a cold tree, within the same
        // deadline, instead of silently dropping the window on its first read.
        for attempt in 0..<3 {
            guard Date() < until else { break }
            // Once a web-area identity is pinned, consistently read that tree.
            // Newly available window metadata must not look like a tab change.
            if !requireWebArea, let document = address(read(window, kAXDocumentAttribute as CFString)),
               URL(string: document)?.scheme != nil {
                return documentLookup(document)
            }
            var queue: [AXUIElement] = [window]
            var cursor = 0
            while cursor < queue.count && cursor < 500 && Date() < until {
                let element = queue[cursor]; cursor += 1
                let role = read(element, kAXRoleAttribute as CFString) as? String
                if (read(element, "AXHidden" as CFString) as? Bool) == true { continue }
                if role == "AXWebArea" {
                    // Stop at the outer document, even for another site or a
                    // missing URL. Never accept an open.mu iframe or page link.
                    if let url = address(read(element, kAXURLAttribute as CFString)),
                       URL(string: url)?.scheme != nil {
                        return documentLookup(url, element: element)
                    }
                    reason = "Chrome exposed the active web area without its URL. Wait for the game to load, then refresh."
                    break
                }
                // Browser toolbars can contain hundreds of tab/address controls.
                // They are not document evidence and can exhaust the walk budget.
                if ["AXToolbar", "AXMenuBar", "AXMenu", "AXTextField", "AXComboBox", "AXLink", "AXButton"].contains(role ?? "") { continue }
                if let children = read(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
                    queue.append(contentsOf: children.prefix(max(0, 500 - queue.count)))
                }
            }
            if Date() >= until || cursor >= 500 {
                reason = "Accessibility document search reached its time/node limit. Restore the game window and refresh."
            }
            if attempt < 2, Date().addingTimeInterval(0.15) < until { pause() }
        }
        return DocumentLookup(url: nil, reason: reason)
    }

    private static func documentLookup(_ url: String, element: AXUIElement? = nil) -> DocumentLookup {
        DocumentLookup(url: url, reason: GamePagePolicy.allows(url)
            ? "Verified active https://open.mu document."
            : "Active document is not the allowed https://open.mu origin. Activate the game tab, then refresh.", element: element)
    }

    private static func bounds(_ element: AXUIElement,
                               read: (AXUIElement, CFString) -> CFTypeRef? = attribute) -> CGRect? {
        guard let position = read(element, kAXPositionAttribute as CFString), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = read(element, kAXSizeAttribute as CFString), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
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

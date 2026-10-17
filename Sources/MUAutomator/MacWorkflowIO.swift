import AppKit
import ApplicationServices
import ScreenCaptureKit
import AutomationCore

@MainActor
final class MacWorkflowIO: WorkflowIO {
    let window: SCWindow
    let profile: CalibrationProfile
    private var currentWindow: SCWindow
    private var lastObservation: Observation?
    private let title: String?
    private let aspect: Double

    init(window: SCWindow, profile: CalibrationProfile) throws {
        try profile.validate()
        self.window = window; self.currentWindow = window; self.profile = profile
        title = window.title
        aspect = Double(window.frame.width / window.frame.height)
        if let calibrated = profile.windowAspectRatio, abs(calibrated - aspect) > 0.005 {
            throw WorkflowFailure.prerequisite("Window aspect ratio differs from calibration; calibrate again")
        }
    }

    static func requireTargets(_ roles: Set<TargetRole>, in profile: CalibrationProfile) throws {
        for role in roles.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let target = profile.targets.first(where: { $0.role == role }),
                  role == .gameViewport || target.template != nil || !(target.expectedText ?? "").isEmpty else {
                throw WorkflowFailure.prerequisite("Calibrate and dry-run detect \(role.rawValue) first")
            }
        }
        if roles.contains(.transferButton) {
            guard let transfer = profile.targets.first(where: { $0.role == .transferButton }),
                  let withdraw = profile.targets.first(where: { $0.role == .withdrawExcluded }),
                  !transfer.region.overlaps(withdraw.region) else {
                throw WorkflowFailure.prerequisite("Transfer and excluded Withdraw regions must be separate")
            }
        }
    }

    func checkSafety() throws {
        try Task.checkCancellation()
        guard CGPreflightScreenCaptureAccess(), AXIsProcessTrusted() else {
            throw WorkflowFailure.unsafe("Screen Recording or Accessibility permission is missing")
        }
        guard let app = window.owningApplication,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processID else {
            throw WorkflowFailure.unsafe("Selected game's application lost focus")
        }
        // Public AX bounds/title checks distinguish windows of the same browser process.
        let appElement = AXUIElementCreateApplication(app.processID)
        var element: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &element) == .success,
           let element, CFGetTypeID(element) == AXUIElementGetTypeID() {
            var role: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXRoleAttribute as CFString, &role)
            if let role = role as? String, [kAXTextFieldRole, kAXTextAreaRole].contains(role) {
                throw WorkflowFailure.unsafe("A text field has keyboard focus")
            }
        }
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            throw WorkflowFailure.unsafe("Cannot verify focused browser window")
        }
        let focused = focusedValue as! AXUIElement
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?, titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(focused, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            throw WorkflowFailure.unsafe("Cannot verify browser bounds")
        }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              abs(point.x - currentWindow.frame.minX) < 2, abs(point.y - currentWindow.frame.minY) < 2,
              abs(size.width - currentWindow.frame.width) < 2, abs(size.height - currentWindow.frame.height) < 2 else {
            throw WorkflowFailure.unsafe("Window moved, resized, or another browser window has focus; refresh selection")
        }
        _ = AXUIElementCopyAttributeValue(focused, kAXTitleAttribute as CFString, &titleValue)
        if let title, !title.isEmpty, (titleValue as? String) != title {
            throw WorkflowFailure.unsafe("Browser title/tab changed; select and calibrate the game again")
        }
    }

    func observe() async throws -> Observation {
        try checkSafety()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let fresh = content.windows.first(where: { $0.windowID == window.windowID }),
              fresh.title == title, abs(Double(fresh.frame.width / fresh.frame.height) - aspect) < 0.005 else {
            throw WorkflowFailure.unsafe("Selected window disappeared or changed layout")
        }
        currentWindow = fresh
        let filter = SCContentFilter(desktopIndependentWindow: fresh)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(fresh.frame.width * 2)); config.height = max(1, Int(fresh.frame.height * 2))
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let time = Date()
        try checkSafety()
        let profile = self.profile
        let result = try await Task.detached(priority: .userInitiated) {
            try VisionService.detect(image: image, profile: profile, timestamp: time)
        }.value
        try checkSafety()
        lastObservation = result
        return result
    }

    func perform(_ action: GameAction) async throws {
        try checkSafety()
        guard CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else {
            throw WorkflowFailure.unsafe("Release modifier keys before automated input")
        }
        guard let observation = lastObservation, abs(observation.timestamp.timeIntervalSinceNow) < 2 else {
            throw WorkflowFailure.unsafe("Input requires fresh visual evidence")
        }
        guard !observation.blocksInput || observation.state == .respawnScreen else {
            throw WorkflowFailure.unsafe("Input blocked by \(observation.state.rawValue)")
        }
        let source = CGEventSource(stateID: .hidSystemState)
        switch action {
        case .click(let role):
            guard role != .withdrawExcluded, observation.has(role),
                  let target = profile.targets.first(where: { $0.role == role }) else {
                throw WorkflowFailure.unsafe("Unverified or excluded click target")
            }
            if role == .transferButton, let excluded = profile.targets.first(where: { $0.role == .withdrawExcluded }),
               target.region.overlaps(excluded.region) { throw WorkflowFailure.unsafe("Transfer overlaps Withdraw") }
            try click(x: target.region.x + target.region.width / 2,
                      y: target.region.y + target.region.height / 2, source: source)
        case .point(let x, let y): try click(x: x, y: y, source: source)
        case .key(let code):
            guard code < 128, !observation.blocksInput else { throw WorkflowFailure.unsafe("Unsafe keyboard event") }
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
                throw WorkflowFailure.unsafe("Could not create keyboard events")
            }
            try checkSafety()
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        }
    }

    private func click(x: Double, y: Double, source: CGEventSource?) throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw WorkflowFailure.unsafe("Click outside selected window")
        }
        guard let viewport = profile.targets.first(where: { $0.role == .gameViewport }),
              viewport.region.contains(x: x, y: y) else {
            throw WorkflowFailure.unsafe("Click outside calibrated game viewport")
        }
        if let excluded = profile.targets.first(where: { $0.role == .withdrawExcluded }),
           x >= excluded.region.x, x <= excluded.region.x + excluded.region.width,
           y >= excluded.region.y, y <= excluded.region.y + excluded.region.height {
            throw WorkflowFailure.unsafe("Click falls inside excluded Withdraw region")
        }
        let point = CGPoint(x: currentWindow.frame.minX + x * currentWindow.frame.width,
                            y: currentWindow.frame.minY + y * currentWindow.frame.height)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw WorkflowFailure.unsafe("Could not create mouse events")
        }
        try checkSafety()
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
}

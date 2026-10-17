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
    private var binding: BrowserWindowBinding?
    private let aspect: Double
    private let strictGameplayRecognition: Bool
    private var lastFrame: CGImage?
    var onFrame: ((CGImage, Observation) -> Void)?
    var onClick: ((String, CGImage?) -> Void)?
    private var clickDescription: String?
    private let recordedWindow: InputRecording?

    func describeAction(_ action: GameAction) -> String {
        switch action {
        case .click, .point: return clickDescription ?? String(describing: action)
        case .key: return String(describing: action)
        }
    }

    init(window: SCWindow, profile: CalibrationProfile, strictGameplayRecognition: Bool = false,
         recordedWindow: InputRecording? = nil) throws {
        try profile.validate()
        self.window = window; self.currentWindow = window; self.profile = profile
        self.strictGameplayRecognition = strictGameplayRecognition
        self.recordedWindow = recordedWindow
        if let recordedWindow {
            try recordedWindow.validate()
            guard recordedWindow.matchesWindow(width: window.frame.width, height: window.frame.height) else {
                throw WorkflowFailure.prerequisite("Restore the browser size used for this recording (\(Int(recordedWindow.windowWidth)) × \(Int(recordedWindow.windowHeight)) points), or record again")
            }
        }
        aspect = Double(window.frame.width / window.frame.height)
        if recordedWindow == nil, let calibrated = profile.windowAspectRatio, abs(calibrated - aspect) > 0.005 {
            throw WorkflowFailure.prerequisite("Window aspect ratio differs from calibration; calibrate again")
        }
    }

    /// Run after the focus countdown, before any workflow or recording input.
    func prepareSelectedWindow() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let fresh = content.windows.first(where: { $0.windowID == window.windowID }),
              fresh.owningApplication?.processID == window.owningApplication?.processID,
              abs(Double(fresh.frame.width / fresh.frame.height) - aspect) < 0.005,
              let candidate = BrowserWindowCandidate(fresh) else {
            throw WorkflowFailure.prerequisite("Selected window disappeared or changed layout. Refresh selection and review detection.")
        }
        let candidates = content.windows.compactMap(BrowserWindowCandidate.init)
        let verified = try await Task.detached(priority: .userInitiated) {
            try BrowserWindowDiscovery.bind(candidate, among: candidates)
        }.value
        try Task.checkCancellation()
        currentWindow = fresh
        binding = verified
        try checkSafety()
    }

    var captureBounds: CGRect { currentWindow.frame }

    static func requireTargets(_ roles: Set<TargetRole>, in profile: CalibrationProfile,
                               strictGameplayRecognition: Bool = true) throws {
        for role in roles.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let target = profile.targets.first(where: { $0.role == role }),
                  role == .gameViewport || (!strictGameplayRecognition && role.isClickControl)
                    || target.template != nil || !(target.expectedText ?? "").isEmpty else {
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

    func hasCalibratedTarget(_ role: TargetRole) -> Bool {
        role != .withdrawExcluded && profile.targets.contains { $0.role == role }
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
        guard let binding else { throw WorkflowFailure.unsafe("Selected window has not been verified; start again") }
        // Retained AX identity distinguishes same-title windows of one browser.
        // Titles are presentation text, not a window or tab identifier.
        let appElement = AXUIElementCreateApplication(app.processID)
        AXUIElementSetMessagingTimeout(appElement, 0.15)
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
        try binding.requireFocusedWindow(focused)
        AXUIElementSetMessagingTimeout(focused, 0.15)
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
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
        if let recordedWindow, !recordedWindow.matchesWindow(width: size.width, height: size.height) {
            throw WorkflowFailure.unsafe("Browser size differs from the input recording")
        }
    }

    func observe() async throws -> Observation {
        try checkSafety()
        try await verifyGamePage()
        try checkSafety()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let fresh = content.windows.first(where: { $0.windowID == window.windowID }),
              fresh.owningApplication?.processID == window.owningApplication?.processID,
              abs(Double(fresh.frame.width / fresh.frame.height) - aspect) < 0.005 else {
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
        let strict = strictGameplayRecognition
        let result = try await Task.detached(priority: .userInitiated) {
            try VisionService.detect(image: image, profile: profile, timestamp: time,
                                     strictRecognition: strict, includeOCRDiagnostics: false)
        }.value
        try checkSafety()
        lastObservation = result
        lastFrame = image
        onFrame?(image, result)
        return result
    }

    func perform(_ action: GameAction) async throws {
        try await perform(action, holdSeconds: 0.05, recorded: false)
    }

    func performRecorded(_ step: RecordedInputStep) async throws {
        guard recordedWindow != nil else { throw WorkflowFailure.prerequisite("No recording is bound to this window") }
        try await perform(step.action, holdSeconds: step.holdSeconds, recorded: true)
    }

    private func perform(_ action: GameAction, holdSeconds: Double, recorded: Bool) async throws {
        try checkSafety()
        try await verifyGamePage()
        try checkSafety()
        guard CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else {
            throw WorkflowFailure.unsafe("Release modifier keys before automated input")
        }
        guard let observation = lastObservation, abs(observation.timestamp.timeIntervalSinceNow) < 2 else {
            throw WorkflowFailure.unsafe("Input requires fresh visual evidence")
        }
        guard observation.permitsInput(strictGameplayRecognition: strictGameplayRecognition, allowRespawn: true) else {
            throw WorkflowFailure.unsafe("Input blocked by \(observation.state.rawValue)")
        }
        let source = CGEventSource(stateID: .hidSystemState)
        switch action {
        case .click(let role):
            guard role != .withdrawExcluded, (!strictGameplayRecognition || observation.has(role)),
                  let target = profile.targets.first(where: { $0.role == role }) else {
                throw WorkflowFailure.unsafe("Unverified or excluded click target")
            }
            if role == .transferButton, let excluded = profile.targets.first(where: { $0.role == .withdrawExcluded }),
               target.region.overlaps(excluded.region) { throw WorkflowFailure.unsafe("Transfer overlaps Withdraw") }
            let position = try target.effectiveClickPoint
            try await click(x: position.x, y: position.y, source: source, label: role.rawValue)
        case .point(let x, let y):
            try await click(x: x, y: y, source: source, label: recorded ? "recorded point" : "route point",
                            holdSeconds: holdSeconds, recorded: recorded)
        case .key(let code):
            guard code < 128, observation.permitsInput(strictGameplayRecognition: strictGameplayRecognition, allowRespawn: recorded) else {
                throw WorkflowFailure.unsafe("Unsafe keyboard event")
            }
            try await MacMouseInput.key(code: code, source: source,
                                        whileHeld: { try await self.hold(holdSeconds) }, check: { try self.checkSafety() })
        }
    }

    private func verifyGamePage() async throws {
        guard let binding else { throw WorkflowFailure.unsafe("Selected window has not been verified; start again") }
        try await Task.detached(priority: .utility) {
            try BrowserWindowDiscovery.verify(binding)
        }.value
        try Task.checkCancellation()
    }

    private func click(x: Double, y: Double, source: CGEventSource?, label: String,
                       holdSeconds: Double = 0.05, recorded: Bool = false) async throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw WorkflowFailure.unsafe("Click outside selected window")
        }
        if !recorded {
            guard let viewport = profile.targets.first(where: { $0.role == .gameViewport }),
                  viewport.region.contains(x: x, y: y) else {
                throw WorkflowFailure.unsafe("Click outside calibrated game viewport")
            }
        }
        if !recorded, let excluded = profile.targets.first(where: { $0.role == .withdrawExcluded }),
           x >= excluded.region.x, x <= excluded.region.x + excluded.region.width,
           y >= excluded.region.y, y <= excluded.region.y + excluded.region.height {
            throw WorkflowFailure.unsafe("Click falls inside excluded Withdraw region")
        }
        let point = CGPoint(x: currentWindow.frame.minX + x * currentWindow.frame.width,
                            y: currentWindow.frame.minY + y * currentWindow.frame.height)
        let description = String(format: "%@ → window %u, window position %.4f, %.4f; screen point %.1f, %.1f",
                                 label, window.windowID, x, y, point.x, point.y)
        clickDescription = description
        onClick?(description, lastFrame)
        try await MacMouseInput.click(at: point, source: source, holdNanoseconds: UInt64(holdSeconds * 1_000_000_000),
                                     whileHeld: { try await self.hold(holdSeconds) }) {
            try self.checkSafety()
            guard Self.topWindow(at: point) == self.window.windowID else {
                throw WorkflowFailure.unsafe("The click point is covered by another window; bring the selected game to the front")
            }
        }
    }

    private func hold(_ seconds: Double) async throws {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            try checkSafety()
            try await Task.sleep(nanoseconds: UInt64(min(0.05, max(0, until.timeIntervalSinceNow)) * 1_000_000_000))
        }
        try checkSafety()
    }

    static func topWindow(at point: CGPoint) -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        return topWindow(at: point, windows: windows)
    }

    static func topWindow(at point: CGPoint, windows: [[String: Any]]) -> CGWindowID? {
        // Core Graphics returns front-to-back order and uses the same global,
        // top-left coordinate space as CGEvent. Negative display origins are valid.
        for info in windows {
            guard (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue != 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(point),
                  let id = info[kCGWindowNumber as String] as? NSNumber else { continue }
            return id.uint32Value
        }
        return nil
    }
}

@MainActor
enum MacMouseInput {
    static func key(code: UInt16, source: CGEventSource?,
                    post: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
                    whileHeld: () async throws -> Void, check: () throws -> Void) async throws {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw WorkflowFailure.unsafe("Could not create keyboard events")
        }
        try Task.checkCancellation(); try check()
        post(down)
        do {
            defer { post(up) }
            try await whileHeld()
        }
        try Task.checkCancellation(); try check()
    }

    static func click(at point: CGPoint, source: CGEventSource?,
                      settleNanoseconds: UInt64 = 60_000_000, holdNanoseconds: UInt64 = 50_000_000,
                      post: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
                      whileHeld: (() async throws -> Void)? = nil,
                      check: () throws -> Void) async throws {
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw WorkflowFailure.unsafe("Could not create mouse events")
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        try Task.checkCancellation(); try check()
        post(move)
        // Browser canvas games may consume the position from mousemove and
        // sample button state on a later render tick. A down/up pair alone can
        // use the previous pointer location or disappear between game frames.
        try await Task.sleep(nanoseconds: settleNanoseconds)
        try Task.checkCancellation(); try check()
        post(down)
        // Always release a delivered press, including cancellation/focus loss.
        do {
            defer { post(up) }
            if let whileHeld { try await whileHeld() }
            else { try await Task.sleep(nanoseconds: holdNanoseconds) }
        }
        try Task.checkCancellation(); try check()
    }
}

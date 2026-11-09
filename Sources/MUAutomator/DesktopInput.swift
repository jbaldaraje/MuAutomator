import AppKit
import ApplicationServices
import AutomationCore

/// Native desktop input only: no capture, browser lookup, window binding, or cursor/focus checks.
@MainActor
final class DesktopInput: ScreenMacroIO {
    static let eventTag: Int64 = 0x4D554D4143524F
    private let post: (CGEvent) -> Void
    private let displays: () throws -> ScreenLayout
    private let permitted: () -> Bool
    private var keys: Set<UInt16> = []
    private var buttons: Set<Int> = []
    private var modifierKeys: Set<UInt16> = []
    private var pointer = ScreenPoint(x: 0, y: 0)
    private let source = CGEventSource(stateID: .privateState)
    private var nextCheck = 0.0
    private var expectedLayout: ScreenLayout?

    init(post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
         displays: @escaping () throws -> ScreenLayout = DesktopInput.currentLayout,
         permitted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.post = post; self.displays = displays; self.permitted = permitted
    }
    nonisolated static func currentLayout() throws -> ScreenLayout {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0, count <= 32 else {
            throw ScreenMacroError.invalid("Could not read the desktop displays.")
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            throw ScreenMacroError.invalid("Could not read the desktop displays.")
        }
        let layout = ScreenLayout(displays: ids.prefix(Int(count)).map { id in
            let bounds = CGDisplayBounds(id)
            return ScreenBounds(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height)
        })
        try layout.validate(); return layout
    }
    func validate(layout: ScreenLayout) throws {
        try Task.checkCancellation()
        let now = ProcessInfo.processInfo.systemUptime
        if expectedLayout == layout && now < nextCheck { return }
        guard permitted() else { throw ScreenMacroError.invalid("Accessibility permission is required for playback.") }
        guard try layout.matches(displays()) else {
            throw ScreenMacroError.invalid("Display arrangement changed. Restore the recorded displays or record a new macro.")
        }
        expectedLayout = layout; nextCheck = now + 0.25
    }
    func perform(_ event: ScreenEvent) throws {
        try Task.checkCancellation()
        let native: CGEvent?
        switch event.action {
        case .move(let point):
            let type: CGEventType = buttons.contains(0) ? .leftMouseDragged
                : buttons.contains(1) ? .rightMouseDragged : buttons.isEmpty ? .mouseMoved : .otherMouseDragged
            native = mouse(type, point: point, button: buttons.sorted().first ?? 0, clicks: 1)
        case .mouseDown(let button, let point, let clicks):
            native = mouse(button == 0 ? .leftMouseDown : button == 1 ? .rightMouseDown : .otherMouseDown,
                           point: point, button: button, clicks: clicks)
        case .mouseUp(let button, let point, let clicks):
            guard buttons.contains(button) else { return }
            native = mouse(button == 0 ? .leftMouseUp : button == 1 ? .rightMouseUp : .otherMouseUp,
                           point: point, button: button, clicks: clicks)
        case .keyDown(let code, let repeating):
            native = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
            native?.setIntegerValueField(.keyboardEventAutorepeat, value: repeating ? 1 : 0)
        case .keyUp(let code):
            guard keys.contains(code) else { return }
            native = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        case .flagsChanged(let code):
            native = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
            native?.type = .flagsChanged
        case .scroll(let x, let y, let pixels):
            native = CGEvent(scrollWheelEvent2Source: source, units: pixels ? .pixel : .line,
                             wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)
        }
        guard let native else { throw ScreenMacroError.invalid("macOS could not create an input event.") }
        switch event.action {
        case .move(let point): pointer = point
        case .mouseDown(let button, let point, _): buttons.insert(button); pointer = point
        case .mouseUp(let button, let point, _): buttons.remove(button); pointer = point
        case .keyDown(let code, _): keys.insert(code)
        case .keyUp(let code): keys.remove(code)
        case .flagsChanged(let code):
            let mask = Self.modifierMask(code)
            modifierKeys = modifierKeys.filter { event.modifiers & Self.modifierMask($0) != 0 }
            if event.modifiers & mask != 0 { modifierKeys.insert(code) }
        case .scroll: break
        }
        native.flags = CGEventFlags(rawValue: event.modifiers)
        send(native)
    }
    private static func modifierMask(_ code: UInt16) -> UInt64 {
        switch code {
        case 54, 55: return 1 << 20
        case 56, 60: return 1 << 17
        case 58, 61: return 1 << 19
        case 59, 62: return 1 << 18
        case 57: return 1 << 16
        case 63: return 1 << 23
        default: return 0
        }
    }
    private func mouse(_ type: CGEventType, point: ScreenPoint, button: Int, clicks: Int) -> CGEvent? {
        let event = CGEvent(mouseEventSource: source, mouseType: type,
                            mouseCursorPosition: CGPoint(x: point.x, y: point.y),
                            mouseButton: button == 0 ? .left : button == 1 ? .right : .center)
        event?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        return event
    }
    private func send(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        post(event)
    }
    func releaseAll() {
        for button in buttons.sorted() {
            if let event = mouse(button == 0 ? .leftMouseUp : button == 1 ? .rightMouseUp : .otherMouseUp,
                                 point: pointer, button: button, clicks: 1) { event.flags = []; send(event) }
        }
        for code in keys.sorted() {
            if let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) {
                event.flags = []; send(event)
            }
        }
        for code in modifierKeys.sorted() {
            if let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) {
                event.type = .flagsChanged; event.flags = []; send(event)
            }
        }
        buttons.removeAll(); keys.removeAll(); modifierKeys.removeAll()
    }
}

@MainActor
enum DesktopEventCapture {
    static let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        .keyDown, .keyUp, .flagsChanged, .scrollWheel]
    static func isInjected(_ event: NSEvent) -> Bool { event.cgEvent?.getIntegerValueField(.eventSourceUserData) == DesktopInput.eventTag }
    static func isControl(_ event: NSEvent, key: UInt16) -> Bool {
        event.keyCode == key && event.modifierFlags.intersection([.control, .option, .command]) == [.control, .option, .command]
    }
    static func convert(_ event: NSEvent, since start: Double) -> ScreenEvent? {
        guard !isInjected(event) else { return nil }
        let modifiers = UInt64(event.modifierFlags.rawValue) & ScreenEvent.allowedModifiers
        let point = event.cgEvent.map { ScreenPoint(x: $0.location.x, y: $0.location.y) }
        let action: ScreenAction
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard let point else { return nil }; action = .move(point)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard let point else { return nil }
            action = .mouseDown(button: event.buttonNumber, point: point, clicks: max(1, min(10, event.clickCount)))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard let point else { return nil }
            action = .mouseUp(button: event.buttonNumber, point: point, clicks: max(1, min(10, event.clickCount)))
        case .keyDown: action = .keyDown(code: event.keyCode, repeatKey: event.isARepeat)
        case .keyUp: action = .keyUp(code: event.keyCode)
        case .flagsChanged: action = .flagsChanged(code: event.keyCode)
        case .scrollWheel:
            guard let cg = event.cgEvent else { return nil }
            let pixels = cg.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            let x = cg.getIntegerValueField(pixels ? .scrollWheelEventPointDeltaAxis2 : .scrollWheelEventDeltaAxis2)
            let y = cg.getIntegerValueField(pixels ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventDeltaAxis1)
            action = .scroll(x: Int32(clamping: x), y: Int32(clamping: y), pixels: pixels)
        default: return nil
        }
        return ScreenEvent(time: max(0, event.timestamp - start), action: action, modifiers: modifiers)
    }
}

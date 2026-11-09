import Foundation

public enum ScreenMacroError: Error, LocalizedError {
    case invalid(String), recordingLimit
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .recordingLimit: return "Recording limit reached (one hour or 250,000 events)."
        }
    }
}

public struct ScreenPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct ScreenBounds: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public func contains(_ point: ScreenPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && point.x >= x && point.y >= y
            && point.x < x + width && point.y < y + height
    }
}

/// Quartz desktop coordinates, including displays above or left of the main screen.
public struct ScreenLayout: Codable, Equatable, Sendable {
    public var displays: [ScreenBounds]
    public init(displays: [ScreenBounds]) { self.displays = displays }
    public func validate() throws {
        guard !displays.isEmpty, displays.count <= 32 else { throw ScreenMacroError.invalid("No usable display layout.") }
        for display in displays {
            guard [display.x, display.y, display.width, display.height].allSatisfy(\.isFinite),
                  abs(display.x) <= 1_000_000, abs(display.y) <= 1_000_000,
                  display.width > 0, display.height > 0, display.width <= 100_000, display.height <= 100_000 else {
                throw ScreenMacroError.invalid("The recording contains an invalid display layout.")
            }
        }
    }
    public func contains(_ point: ScreenPoint) -> Bool { displays.contains { $0.contains(point) } }
    public func matches(_ other: ScreenLayout) -> Bool {
        func ordered(_ displays: [ScreenBounds]) -> [ScreenBounds] {
            displays.sorted { a, b in
                if a.x != b.x { return a.x < b.x }
                if a.y != b.y { return a.y < b.y }
                if a.width != b.width { return a.width < b.width }
                return a.height < b.height
            }
        }
        guard displays.count == other.displays.count else { return false }
        return zip(ordered(displays), ordered(other.displays)).allSatisfy { a, b in
            abs(a.x - b.x) < 1 && abs(a.y - b.y) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
        }
    }
}

public enum ScreenAction: Codable, Equatable, Sendable {
    case move(ScreenPoint)
    case mouseDown(button: Int, point: ScreenPoint, clicks: Int)
    case mouseUp(button: Int, point: ScreenPoint, clicks: Int)
    case keyDown(code: UInt16, repeatKey: Bool)
    case keyUp(code: UInt16)
    case flagsChanged(code: UInt16)
    case scroll(x: Int32, y: Int32, pixels: Bool)

    public var point: ScreenPoint? {
        switch self {
        case .move(let point), .mouseDown(_, let point, _), .mouseUp(_, let point, _): return point
        default: return nil
        }
    }
}

public struct ScreenEvent: Codable, Equatable, Sendable {
    public static let allowedModifiers: UInt64 = 0x00FF0000
    public static let modifierCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    public var time: Double
    public var action: ScreenAction
    public var modifiers: UInt64
    public init(time: Double, action: ScreenAction, modifiers: UInt64 = 0) {
        self.time = time; self.action = action; self.modifiers = modifiers
    }
}

public struct ScreenMacro: Codable, Equatable, Sendable {
    public static let maximumDuration: Double = 3600
    public static let maximumEvents = 250_000
    public var version = 1
    public var layout: ScreenLayout
    public var events: [ScreenEvent]
    public var duration: Double
    public init(layout: ScreenLayout, events: [ScreenEvent], duration: Double) {
        self.layout = layout; self.events = events; self.duration = duration
    }
    public func validate() throws {
        try layout.validate()
        guard version == 1, !events.isEmpty, events.count <= Self.maximumEvents,
              duration.isFinite, duration > 0, duration <= Self.maximumDuration else {
            throw ScreenMacroError.invalid("Record at least one action, up to one hour per macro.")
        }
        var previous = 0.0
        var keys: Set<UInt16> = []
        var buttons: Set<Int> = []
        for event in events {
            guard event.time.isFinite, event.time >= previous, event.time <= duration,
                  event.modifiers & ~ScreenEvent.allowedModifiers == 0 else {
                throw ScreenMacroError.invalid("The recording contains invalid event timing or modifiers.")
            }
            previous = event.time
            if let point = event.action.point, !layout.contains(point) {
                throw ScreenMacroError.invalid("A recorded pointer position is outside the recorded displays.")
            }
            switch event.action {
            case .mouseDown(let button, _, let clicks):
                guard (0...31).contains(button), (1...10).contains(clicks), buttons.insert(button).inserted else {
                    throw ScreenMacroError.invalid("Invalid mouse press in the recording.")
                }
            case .mouseUp(let button, _, let clicks):
                guard (1...10).contains(clicks), buttons.remove(button) != nil else {
                    throw ScreenMacroError.invalid("A mouse release has no matching press.")
                }
            case .keyDown(let code, let repeating):
                guard code < 128, !ScreenEvent.modifierCodes.contains(code),
                      repeating ? keys.contains(code) : keys.insert(code).inserted else {
                    throw ScreenMacroError.invalid("Invalid keyboard press in the recording.")
                }
            case .keyUp(let code):
                guard keys.remove(code) != nil else { throw ScreenMacroError.invalid("A key release has no matching press.") }
            case .flagsChanged(let code):
                guard ScreenEvent.modifierCodes.contains(code) else { throw ScreenMacroError.invalid("Invalid modifier key.") }
            case .scroll(let x, let y, _):
                guard abs(Int64(x)) <= 1_000_000, abs(Int64(y)) <= 1_000_000 else {
                    throw ScreenMacroError.invalid("Invalid scroll amount.")
                }
            case .move: break
            }
        }
        guard keys.isEmpty, buttons.isEmpty else { throw ScreenMacroError.invalid("The recording ends with held input.") }
    }
}

/// Collects desktop events. It never injects input or depends on a window/focus/cursor position.
public struct ScreenMacroBuffer {
    public let layout: ScreenLayout
    public private(set) var events: [ScreenEvent] = []
    private var keys: Set<UInt16> = []
    private var buttons: Set<Int> = []
    private var lastMove = -Double.infinity
    private var lastPoint: ScreenPoint?
    private var lastTime = 0.0
    public init(layout: ScreenLayout) { self.layout = layout }

    public mutating func append(_ event: ScreenEvent) throws {
        guard event.time.isFinite, event.time >= lastTime else {
            throw ScreenMacroError.invalid("An input event arrived with invalid timing.")
        }
        guard event.time <= ScreenMacro.maximumDuration, events.count < ScreenMacro.maximumEvents - 200 else {
            throw ScreenMacroError.recordingLimit
        }
        lastTime = event.time
        if let point = event.action.point {
            guard layout.contains(point) else { throw ScreenMacroError.invalid("Pointer is outside the recorded display arrangement.") }
            lastPoint = point
        }
        switch event.action {
        case .move:
            guard event.time - lastMove >= 1.0 / 60 else { return }
            lastMove = event.time
        case .mouseDown(let button, _, _):
            guard buttons.insert(button).inserted else { return }
        case .mouseUp(let button, _, _):
            guard buttons.remove(button) != nil else { return }
        case .keyDown(let code, let repeating):
            if repeating { guard keys.contains(code) else { return } }
            else { guard keys.insert(code).inserted else { return } }
        case .keyUp(let code): guard keys.remove(code) != nil else { return }
        default: break
        }
        events.append(event)
    }

    public func finish(at time: Double, trimmingStopShortcut: Bool = false) throws -> ScreenMacro {
        guard time.isFinite, time >= lastTime else { throw ScreenMacroError.invalid("Invalid recording end time.") }
        var result = events
        var end = min(ScreenMacro.maximumDuration, time)
        if trimmingStopShortcut {
            // Exclude the trailing Control–Option–Command chord used to stop recording.
            let suffix = result.reversed().prefix { event in
                switch event.action { case .flagsChanged, .move: return true; default: return false }
            }.count
            let start = result.count - suffix
            if let index = result.indices.dropFirst(start).first(where: {
                guard result[$0].time >= end - 1 else { return false }
                if case .flagsChanged = result[$0].action {
                    let stopMask: UInt64 = (1 << 18) | (1 << 19) | (1 << 20)
                    let before = $0 > 0 ? result[$0 - 1].modifiers : 0
                    return result[$0].modifiers & stopMask & ~(before & stopMask) != 0
                }
                return false
            }) {
                end = result[index].time
                result.removeSubrange(index...)
            }
        }
        var heldKeys: Set<UInt16> = []
        var heldButtons: Set<Int> = []
        var point = lastPoint
        for event in result {
            if let current = event.action.point { point = current }
            switch event.action {
            case .keyDown(let code, _): heldKeys.insert(code)
            case .keyUp(let code): heldKeys.remove(code)
            case .mouseDown(let button, _, _): heldButtons.insert(button)
            case .mouseUp(let button, _, _): heldButtons.remove(button)
            default: break
            }
        }
        let finalModifiers = result.last?.modifiers ?? 0
        for code in heldKeys.sorted() { result.append(.init(time: end, action: .keyUp(code: code), modifiers: finalModifiers)) }
        if let point {
            for button in heldButtons.sorted() { result.append(.init(time: end, action: .mouseUp(button: button, point: point, clicks: 1), modifiers: finalModifiers)) }
        }
        if finalModifiers != 0 && !result.isEmpty {
            result.append(.init(time: end, action: .flagsChanged(code: 56)))
        }
        let macro = ScreenMacro(layout: layout, events: result, duration: max(0.01, end))
        try macro.validate()
        return macro
    }
}

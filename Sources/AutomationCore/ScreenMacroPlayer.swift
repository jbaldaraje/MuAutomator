import Foundation

@MainActor
public protocol ScreenMacroIO: AnyObject {
    func validate(layout: ScreenLayout) throws
    func perform(_ event: ScreenEvent) throws
    func releaseAll()
}

public enum ScreenMacroPhase: String, Sendable {
    case idle, countdown, playing, waiting, completed, stopped, failed
}

/// Replays absolute desktop events. There is deliberately no window, focus, or physical-cursor gate.
@MainActor
public final class ScreenMacroPlayer {
    public private(set) var phase: ScreenMacroPhase = .idle
    public private(set) var completedCycles = 0
    public private(set) var error: String?
    public var onChange: (() -> Void)?
    private var task: Task<Void, Never>?
    private var io: (any ScreenMacroIO)?
    private var startedAt: Double?
    private var countdownEnd = 0.0
    private var intervalEnd = 0.0
    private var budget = 0.0
    private var finalElapsed = 0.0
    public init() {}
    public var active: Bool { task != nil }
    public var elapsed: Double {
        if phase == .playing || phase == .waiting, let startedAt { return max(0, ProcessInfo.processInfo.systemUptime - startedAt) }
        return finalElapsed
    }
    public var remaining: Double { max(0, budget - elapsed) }
    public var intervalRemaining: Double {
        phase == .waiting ? max(0, intervalEnd - ProcessInfo.processInfo.systemUptime) : 0
    }
    public var countdownRemaining: Int { max(0, Int(ceil(countdownEnd - ProcessInfo.processInfo.systemUptime))) }

    public func start(_ macro: ScreenMacro, hours: Double, intervalSeconds: Double = 0, io: any ScreenMacroIO, countdown: Double = 5) throws {
        guard !active else { throw ScreenMacroError.invalid("Stop the current playback first.") }
        try macro.validate()
        try ScreenMacroSettings(hours: hours, intervalSeconds: intervalSeconds).validate()
        guard countdown.isFinite, (0...60).contains(countdown) else { throw ScreenMacroError.invalid("Invalid countdown.") }
        try io.validate(layout: macro.layout)
        self.io = io; budget = hours * 3600; completedCycles = 0; error = nil; startedAt = nil; finalElapsed = 0
        intervalEnd = 0
        countdownEnd = ProcessInfo.processInfo.systemUptime + countdown
        phase = .countdown
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                io.releaseAll(); self.io = nil; task = nil; onChange?()
            }
            do {
                try await wait(until: countdownEnd, layout: macro.layout, io: io)
                startedAt = ProcessInfo.processInfo.systemUptime
                phase = .playing; onChange?()
                let stopAt = startedAt! + budget
                while ProcessInfo.processInfo.systemUptime < stopAt {
                    try Task.checkCancellation()
                    try io.validate(layout: macro.layout)
                    let cycleStart = ProcessInfo.processInfo.systemUptime
                    for (index, event) in macro.events.enumerated() {
                        try await wait(until: cycleStart + event.time, layout: macro.layout, io: io)
                        try Task.checkCancellation()
                        try io.perform(event)
                        if index % 32 == 31 { await Task.yield() }
                    }
                    try await wait(until: cycleStart + macro.duration, layout: macro.layout, io: io)
                    io.releaseAll()
                    completedCycles += 1; onChange?()
                    let now = ProcessInfo.processInfo.systemUptime
                    if intervalSeconds > 0 && now < stopAt {
                        intervalEnd = min(now + intervalSeconds, stopAt)
                        phase = .waiting; onChange?()
                        try await wait(until: intervalEnd, layout: macro.layout, io: io)
                        if ProcessInfo.processInfo.systemUptime < stopAt {
                            phase = .playing; onChange?()
                        }
                    }
                }
                finalElapsed = elapsed; phase = .completed
            } catch is CancellationError {
                finalElapsed = elapsed; phase = .stopped
            } catch {
                finalElapsed = elapsed; self.error = error.localizedDescription; phase = .failed
            }
        }
        onChange?()
    }
    public func stop() {
        task?.cancel()
        io?.releaseAll()
    }
    private func wait(until deadline: Double, layout: ScreenLayout, io: any ScreenMacroIO) async throws {
        while true {
            try Task.checkCancellation()
            try io.validate(layout: layout)
            let delay = deadline - ProcessInfo.processInfo.systemUptime
            guard delay > 0 else { return }
            try await Task.sleep(nanoseconds: UInt64(min(delay, 0.05) * 1_000_000_000))
        }
    }
}

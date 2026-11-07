import Foundation

/// Persistent macro/calibration data. Window identities and live consent are never persisted.
public struct WindowMacroProfile: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var configuration: AutomationConfiguration
    public var settings: WorkflowSettings
    public var calibration: CalibrationProfile

    public init(id: UUID = UUID(), name: String, configuration: AutomationConfiguration,
                settings: WorkflowSettings, calibration: CalibrationProfile) {
        self.id = id; self.name = name; self.configuration = configuration
        self.settings = settings; self.calibration = calibration
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80 else {
            throw WorkflowFailure.prerequisite("Give each window macro a name of 1–80 characters.")
        }
        try configuration.validate(); try settings.validate(); try calibration.validate()
        guard configuration.mode == .jewelsOnly, settings.bankingEnabled,
              settings.bankingInputMode == .recordedInput,
              let recording = settings.bankingRecording, !recording.steps.isEmpty else {
            throw WorkflowFailure.prerequisite("Window queues require a recorded jewel macro. Full automation stays on Dashboard.")
        }
    }
}

public struct WindowMacroProfileStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    private struct Document: Codable { var version = 1; var profiles: [WindowMacroProfile] }
    public static func validate(_ profiles: [WindowMacroProfile]) throws {
        guard profiles.count <= 8, Set(profiles.map(\.id)).count == profiles.count,
              Set(profiles.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }).count == profiles.count else {
            throw WorkflowFailure.prerequisite("Use at most eight profiles with distinct names and identities.")
        }
        for profile in profiles { try profile.validate() }
    }
    public func load() throws -> [WindowMacroProfile] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.version == 1 else { throw ConfigurationError.unsupportedVersion }
        try Self.validate(document.profiles)
        return document.profiles
    }
    public func save(_ profiles: [WindowMacroProfile]) throws {
        try Self.validate(profiles)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Document(profiles: profiles)).write(to: url, options: .atomic)
    }
}

@MainActor
public struct WindowMacroQueueEntry {
    public let profile: WindowMacroProfile
    public let windowID: UInt32
    public let io: any WorkflowIO
    public init(profile: WindowMacroProfile, windowID: UInt32, io: any WorkflowIO) {
        self.profile = profile; self.windowID = windowID; self.io = io
    }
}

@MainActor
public final class WindowMacroRuntime: Identifiable {
    public nonisolated let id: UUID
    public let entry: WindowMacroQueueEntry
    public let runner = AutomationCoordinator()
    public fileprivate(set) var completedRuns = 0
    public fileprivate(set) var paused = false
    public fileprivate(set) var stopped = false
    public fileprivate(set) var finished = false
    public fileprivate(set) var error: String?
    fileprivate var startedAt: Double?
    fileprivate var pausedAt: Double?
    fileprivate var nextRunAt: Double = 0
    fileprivate init(_ entry: WindowMacroQueueEntry) { self.entry = entry; id = entry.profile.id }
    public var status: String {
        if let error { return "Needs attention: \(error)" }
        if stopped { return "Stopped" }
        if finished { return "Completed" }
        if paused || runner.stage == .paused && runner.active { return "Paused" }
        if runner.active { return runner.isWaitingForFocus ? "Waiting for game focus" : runner.stage.rawValue }
        return "Queued"
    }
}

public enum WindowMacroQueuePhase: String, Sendable {
    case idle, switching, running, waiting, paused, completed, stopped, failed
}

/// Runs one complete macro per turn. A runner must release all input and finish
/// before another retained window identity is focused. A failed turn stops the queue.
@MainActor
public final class WindowMacroQueue {
    public private(set) var items: [WindowMacroRuntime] = []
    public private(set) var currentID: UUID?
    public private(set) var phase: WindowMacroQueuePhase = .idle
    public private(set) var paused = false
    public private(set) var lastError: String?
    public var onChange: (() -> Void)?
    private var task: Task<Void, Never>?
    private var suspendedAt: Double?
    private var suspendedSeconds = 0.0
    public init() {}
    public var active: Bool { task != nil }
    public var current: WindowMacroRuntime? { items.first { $0.id == currentID } }

    public func start(_ entries: [WindowMacroQueueEntry], inputConsent: Bool) throws {
        guard !active else { throw CoordinatorError.invalidTransition }
        guard inputConsent else { throw WorkflowFailure.prerequisite("Allow queued input and window switching before starting.") }
        guard !entries.isEmpty, entries.allSatisfy({ $0.windowID != 0 }),
              Set(entries.map(\.windowID)).count == entries.count,
              Set(entries.map { ObjectIdentifier($0.io) }).count == entries.count else {
            throw WorkflowFailure.prerequisite("Assign each macro to a different game window.")
        }
        try WindowMacroProfileStore.validate(entries.map(\.profile))
        for entry in entries where entry.profile.configuration.dryRun {
            throw WorkflowFailure.prerequisite("Turn Dry run off in \(entry.profile.name) and update its saved profile.")
        }
        items = entries.map(WindowMacroRuntime.init)
        for item in items {
            item.runner.onChange = { [weak self] in self?.refreshClock(); self?.onChange?() }
        }
        currentID = nil; paused = false; lastError = nil; suspendedAt = nil; suspendedSeconds = 0
        phase = .waiting
        task = Task { [weak self] in
            guard let self else { return }
            defer { currentID = nil; task = nil; refreshClock(); onChange?() }
            do { try await run(); phase = .completed }
            catch is CancellationError {
                stopRunners(); await drainRunners(); phase = .stopped
            } catch {
                lastError = error.localizedDescription
                current?.error = error.localizedDescription
                stopRunners(); await drainRunners(); phase = .failed
            }
        }
        onChange?()
    }

    public func pause() {
        guard active else { return }
        paused = true
        current?.runner.pause()
        phase = .paused; refreshClock(); onChange?()
    }
    public func resume() throws {
        guard active else { return }
        if let current, !current.paused, current.runner.active, current.runner.stage == .paused {
            try current.runner.resume()
        }
        paused = false; phase = .waiting; refreshClock(); onChange?()
    }
    public func pauseEntry(_ id: UUID) {
        guard active, let item = items.first(where: { $0.id == id }), !item.finished, !item.stopped, !item.paused else { return }
        item.paused = true; item.pausedAt = clockTime()
        if id == currentID { item.runner.pause() }
        refreshClock(); onChange?()
    }
    public func resumeEntry(_ id: UUID) throws {
        guard active, let item = items.first(where: { $0.id == id }), item.paused else { return }
        if !paused, item.runner.active, item.runner.stage == .paused { try item.runner.resume() }
        if let start = item.pausedAt {
            let delay = clockTime() - start
            if item.startedAt != nil { item.startedAt! += delay }
            item.nextRunAt += delay
        }
        item.pausedAt = nil; item.paused = false
        refreshClock(); onChange?()
    }
    public func stopEntry(_ id: UUID) {
        guard active, let item = items.first(where: { $0.id == id }) else { return }
        item.stopped = true; item.paused = false
        if item.runner.active { item.runner.stop() }
        refreshClock(); onChange?()
    }
    public func stop() {
        guard active else { return }
        task?.cancel(); stopRunners(); onChange?()
    }
    private func stopRunners() {
        for item in items {
            if !item.finished { item.stopped = true }
            if item.runner.active { item.runner.stop() }
        }
    }
    private func drainRunners() async {
        // Yield even in this cancelled task so a child's input-release cleanup can finish.
        while items.contains(where: { $0.runner.active }) { await Task.yield() }
    }
    private func refreshClock() {
        let pending = items.filter { !$0.finished && !$0.stopped }
        let suspend = active && (paused || current?.runner.isWaitingForFocus == true
            || (current?.runner.active == true && current?.runner.stage == .paused)
            || (!pending.isEmpty && pending.allSatisfy(\.paused)))
        let now = ProcessInfo.processInfo.systemUptime
        if suspend && suspendedAt == nil { suspendedAt = now }
        if !suspend, let start = suspendedAt { suspendedSeconds += now - start; suspendedAt = nil }
    }
    private func clockTime() -> Double {
        let now = ProcessInfo.processInfo.systemUptime
        return now - suspendedSeconds - (suspendedAt.map { now - $0 } ?? 0)
    }
    private func checkpoint(_ item: WindowMacroRuntime? = nil) async throws {
        try Task.checkCancellation()
        while paused || item?.paused == true {
            try Task.checkCancellation()
            if item?.stopped == true { return }
            refreshClock()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    private func allowsAnotherTurn(_ item: WindowMacroRuntime) -> Bool {
        let elapsed = item.startedAt.map { max(0, clockTime() - $0) } ?? 0
        return item.entry.profile.settings.macroRepeat.allowsNextRun(completedRuns: item.completedRuns, elapsedSeconds: elapsed)
    }
    private func run() async throws {
        var cursor = 0
        while true {
            try await checkpoint()
            for item in items where !item.stopped && !item.finished && !item.paused {
                if !allowsAnotherTurn(item) { item.finished = true }
            }
            guard items.contains(where: { !$0.stopped && !$0.finished }) else { return }
            let order = (0..<items.count).map { (cursor + $0) % items.count }
            guard let index = order.first(where: {
                let item = items[$0]
                return !item.stopped && !item.finished && !item.paused && item.nextRunAt <= clockTime()
            }) else {
                if phase != .waiting { phase = .waiting; onChange?() }
                refreshClock()
                try await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            let item = items[index]
            currentID = item.id; phase = .switching; onChange?()
            try await checkpoint(item)
            if item.stopped { cursor = (index + 1) % items.count; currentID = nil; continue }
            try await item.entry.io.refocusSelectedWindow()
            try await checkpoint(item)
            if item.stopped { cursor = (index + 1) % items.count; currentID = nil; continue }
            var settings = item.entry.profile.settings
            settings.macroRepeat = MacroRepeatSettings() // Exactly one complete cycle in this turn.
            settings.autoRefocus.enabled = false // Only the queue owns automatic window switching.
            if item.startedAt == nil { item.startedAt = clockTime() }
            try item.runner.start(configuration: item.entry.profile.configuration, settings: settings, io: item.entry.io)
            phase = .running; onChange?()
            while item.runner.active { try await Task.sleep(nanoseconds: 20_000_000) }
            try Task.checkCancellation()
            if !item.stopped {
                guard item.runner.stage == .completed else {
                    throw WorkflowFailure.uncertain(item.runner.lastError ?? "\(item.entry.profile.name) did not complete; queue stopped without retrying it.")
                }
                item.completedRuns += 1
                item.nextRunAt = clockTime() + item.entry.profile.settings.macroRepeat.delayBetweenRunsSeconds
                item.finished = !allowsAnotherTurn(item)
            }
            currentID = nil; cursor = (index + 1) % items.count
            refreshClock(); onChange?()
        }
    }
}

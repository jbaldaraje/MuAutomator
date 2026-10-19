import Foundation

public enum BankingInputMode: String, Codable, CaseIterable, Sendable {
    case visualWorkflow, recordedInput
    public var title: String { self == .recordedInput ? "Recorded inputs" : "Calibrated image workflow" }
}

public enum MacroRepeatMode: String, Codable, CaseIterable, Sendable {
    case once, count, duration
    public var title: String {
        switch self {
        case .once: return "Once"
        case .count: return "Number of times"
        case .duration: return "For hours"
        }
    }
}

public struct MacroRepeatSettings: Codable, Equatable, Sendable {
    public var mode: MacroRepeatMode = .once
    /// Total runs, including the first playback.
    public var count = 1
    public var durationSeconds: Double = 3600
    public var delayBetweenRunsSeconds: Double = 0
    public init() {}

    private enum CodingKeys: String, CodingKey { case mode, count, durationSeconds, delayBetweenRunsSeconds }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(MacroRepeatMode.self, forKey: .mode) ?? mode
        count = try values.decodeIfPresent(Int.self, forKey: .count) ?? count
        durationSeconds = try values.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? durationSeconds
        delayBetweenRunsSeconds = try values.decodeIfPresent(Double.self, forKey: .delayBetweenRunsSeconds) ?? delayBetweenRunsSeconds
    }
    public func validate() throws {
        guard (1...1_000_000).contains(count) else {
            throw WorkflowFailure.prerequisite("Macro run count must be between 1 and 1,000,000")
        }
        guard durationSeconds.isFinite, durationSeconds > 0, durationSeconds <= 31_536_000 else {
            throw WorkflowFailure.prerequisite("Macro hours must be greater than zero and no more than 8,760")
        }
        guard delayBetweenRunsSeconds.isFinite, (0...86400).contains(delayBetweenRunsSeconds) else {
            throw WorkflowFailure.prerequisite("Delay between macro runs must be between 0 and 86,400 seconds")
        }
    }
    public func allowsNextRun(completedRuns: Int, elapsedSeconds: Double) -> Bool {
        switch mode {
        case .once: return completedRuns == 0
        case .count: return completedRuns < count
        case .duration: return elapsedSeconds < durationSeconds
        }
    }
    public var summary: String {
        switch mode {
        case .once: return "Run once"
        case .count: return "Run \(count) times total"
        case .duration: return String(format: "Repeat for %.4g hours, then finish the current cycle", durationSeconds / 3600)
        }
    }
}

public struct RecordedInputStep: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var action: GameAction
    public var delayBeforeSeconds: Double
    public var holdSeconds: Double
    public init(action: GameAction, delayBeforeSeconds: Double = 0, holdSeconds: Double = 0.05) {
        self.action = action; self.delayBeforeSeconds = delayBeforeSeconds; self.holdSeconds = holdSeconds
    }
}

public struct InputRecording: Codable, Equatable, Sendable {
    public var steps: [RecordedInputStep] = []
    public var windowWidth: Double
    public var windowHeight: Double
    public var tailDelaySeconds: Double = 0
    public init(windowWidth: Double, windowHeight: Double) {
        self.windowWidth = windowWidth; self.windowHeight = windowHeight
    }
    public var duration: Double {
        steps.reduce(tailDelaySeconds) { $0 + $1.delayBeforeSeconds + $1.holdSeconds }
    }
    public func validate() throws {
        guard windowWidth.isFinite, windowHeight.isFinite, windowWidth > 0, windowHeight > 0,
              steps.count <= 200, Set(steps.map(\.id)).count == steps.count,
              tailDelaySeconds.isFinite, (0...120).contains(tailDelaySeconds), duration <= 600 else {
            throw ConfigurationError.invalidLimits
        }
        for step in steps {
            guard step.delayBeforeSeconds.isFinite, (0...120).contains(step.delayBeforeSeconds),
                  step.holdSeconds.isFinite, (0.01...30).contains(step.holdSeconds) else {
                throw ConfigurationError.invalidLimits
            }
            switch step.action {
            case .point(let x, let y): _ = try CalibratedClickPoint(x: x, y: y)
            case .key(let code):
                guard code < 128 else { throw ConfigurationError.invalidLimits }
            case .click: throw CalibrationError.invalidProfile
            }
        }
    }
    public func matchesWindow(width: Double, height: Double) -> Bool {
        abs(width - windowWidth) < 2 && abs(height - windowHeight) < 2
    }
}

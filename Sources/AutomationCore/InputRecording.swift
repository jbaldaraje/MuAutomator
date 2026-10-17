import Foundation

public enum BankingInputMode: String, Codable, CaseIterable, Sendable {
    case visualWorkflow, recordedInput
    public var title: String { self == .recordedInput ? "Recorded inputs" : "Calibrated image workflow" }
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

import Foundation

public enum CoordinatorError: Error { case invalidTransition }

public enum GameAction: Codable, Equatable, Sendable {
    case click(TargetRole)
    case key(UInt16)
    case point(x: Double, y: Double)
}

public struct SkillAction: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var keyCode: UInt16 = 0
    public var delaySeconds: Double = 1
    public var cooldownSeconds: Double = 1
    public var verification: TargetRole?
    public init() {}
}

public struct RouteStep: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var action: GameAction
    public var before: TargetRole
    public var after: TargetRole
    public init(action: GameAction, before: TargetRole, after: TargetRole) {
        self.action = action; self.before = before; self.after = after
    }
}

public struct RecoveryRoute: Codable, Sendable {
    public var name = "My farming route"
    public var steps: [RouteStep] = []
    public var validated = false
    public var recording: InputRecording?
    public var hasActions: Bool { !(recording?.steps.isEmpty ?? steps.isEmpty) }
    public init() {}
}

public struct WorkflowSettings: Codable, Sendable {
    public var schemaVersion = 1
    public var bankingEnabled = true
    public var bankingInputMode: BankingInputMode = .visualWorkflow
    public var bankingRecording: InputRecording?
    public var macroRepeat = MacroRepeatSettings()
    public var bankingVerification: BankingVerificationMode = .newSuccessIndicator
    public var countFormat: CountFormat = .digitsOnly
    public var inventoryMonitoringEnabled = true
    public var bankingCooldownSeconds: Double = 120
    public var actionTimeoutSeconds: Double = 10
    public var workflowTimeoutSeconds: Double = 3600
    public var recoveryTimeoutSeconds: Double = 60
    public var routeTimeoutSeconds: Double = 120
    public var maximumRecoveries = 3
    public var pollSeconds: Double = 0.5
    public var detectionRetries = 2
    public var skills: [SkillAction] = []
    public var repeatSkills = true
    public var route = RecoveryRoute()
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, bankingEnabled, bankingInputMode, bankingRecording, macroRepeat, bankingVerification, countFormat, inventoryMonitoringEnabled, bankingCooldownSeconds
        case actionTimeoutSeconds, workflowTimeoutSeconds, recoveryTimeoutSeconds, routeTimeoutSeconds
        case maximumRecoveries, pollSeconds, detectionRetries, skills, repeatSkills, route
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try values.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        schemaVersion = try read(.schemaVersion, schemaVersion)
        bankingEnabled = try read(.bankingEnabled, bankingEnabled)
        bankingInputMode = try read(.bankingInputMode, bankingInputMode)
        bankingRecording = try values.decodeIfPresent(InputRecording.self, forKey: .bankingRecording)
        macroRepeat = try read(.macroRepeat, macroRepeat)
        bankingVerification = try read(.bankingVerification, bankingVerification)
        countFormat = try read(.countFormat, countFormat)
        inventoryMonitoringEnabled = try read(.inventoryMonitoringEnabled, inventoryMonitoringEnabled)
        bankingCooldownSeconds = try read(.bankingCooldownSeconds, bankingCooldownSeconds)
        actionTimeoutSeconds = try read(.actionTimeoutSeconds, actionTimeoutSeconds)
        workflowTimeoutSeconds = try read(.workflowTimeoutSeconds, workflowTimeoutSeconds)
        recoveryTimeoutSeconds = try read(.recoveryTimeoutSeconds, recoveryTimeoutSeconds)
        routeTimeoutSeconds = try read(.routeTimeoutSeconds, routeTimeoutSeconds)
        maximumRecoveries = try read(.maximumRecoveries, maximumRecoveries)
        pollSeconds = try read(.pollSeconds, pollSeconds)
        detectionRetries = try read(.detectionRetries, detectionRetries)
        skills = try read(.skills, skills)
        repeatSkills = try read(.repeatSkills, repeatSkills)
        route = try read(.route, route)
    }

    public func validate() throws {
        try bankingRecording?.validate()
        try route.recording?.validate()
        try macroRepeat.validate()
        guard schemaVersion == 1,
              actionTimeoutSeconds.isFinite, (0.1...120).contains(actionTimeoutSeconds),
              workflowTimeoutSeconds.isFinite, (1...86400).contains(workflowTimeoutSeconds),
              recoveryTimeoutSeconds.isFinite, (0.1...300).contains(recoveryTimeoutSeconds),
              routeTimeoutSeconds.isFinite, (0.1...600).contains(routeTimeoutSeconds),
              pollSeconds.isFinite, (0.01...5).contains(pollSeconds),
              bankingCooldownSeconds.isFinite, (1...86400).contains(bankingCooldownSeconds),
              (0...10).contains(detectionRetries), (1...10).contains(maximumRecoveries),
              skills.count <= 100, route.steps.count <= 200,
              Set(skills.map(\.id)).count == skills.count,
              Set(route.steps.map(\.id)).count == route.steps.count else { throw ConfigurationError.invalidLimits }
        for skill in skills {
            guard skill.keyCode < 128, skill.delaySeconds.isFinite, (0.1...120).contains(skill.delaySeconds),
                  skill.cooldownSeconds.isFinite, (0...3600).contains(skill.cooldownSeconds) else {
                throw ConfigurationError.invalidLimits
            }
        }
        for step in route.steps {
            if case let .point(x, y) = step.action {
                guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { throw CalibrationError.invalidRegion }
            }
            if case let .key(code) = step.action, code >= 128 { throw ConfigurationError.invalidLimits }
            if case let .click(role) = step.action, role == .withdrawExcluded { throw CalibrationError.invalidProfile }
        }
    }
}

public enum WorkflowStage: String, Sendable {
    case idle, initializing, preparingInventory, openingJewelBank, transferringJewels, verifyingBanking
    case closingInventory, openingHelper, startingHelper, verifyingHelper, farming
    case possibleDeath, waitingForRespawn, returningToSpot, verifyingLocation
    case paused, waitingForManualIntervention, completed, cancelled
}

public struct WorkflowEvent: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp = Date()
    public let previous: WorkflowStage
    public let stage: WorkflowStage
    public let message: String
    public let observation: Observation?
    public let elapsed: TimeInterval
}

public enum WorkflowFailure: Error, Equatable, LocalizedError {
    case prerequisite(String), uncertain(String), timeout(String), unsafe(String)
    public var errorDescription: String? {
        switch self {
        case .prerequisite(let value), .uncertain(let value), .timeout(let value), .unsafe(let value): return value
        }
    }
}

@MainActor
public protocol WorkflowIO: AnyObject {
    func observe() async throws -> Observation
    func perform(_ action: GameAction) async throws
    func checkSafety() throws
    func hasCalibratedTarget(_ role: TargetRole) -> Bool
    func describeAction(_ action: GameAction) -> String
    func performRecorded(_ step: RecordedInputStep) async throws
}

public extension WorkflowIO {
    func hasCalibratedTarget(_ role: TargetRole) -> Bool { false }
    func describeAction(_ action: GameAction) -> String { String(describing: action) }
    func performRecorded(_ step: RecordedInputStep) async throws {
        throw WorkflowFailure.prerequisite("This input adapter does not support recorded holds")
    }
}

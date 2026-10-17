import Foundation

/// One task owns input. Every action is evidence-gated; uncertain results never trigger an automatic second click.
@MainActor
public final class AutomationCoordinator {
    public private(set) var stage: WorkflowStage = .idle
    public private(set) var events: [WorkflowEvent] = []
    public private(set) var lastObservation: Observation?
    public private(set) var lastError: String?
    public private(set) var lastVerifiedAction: String?
    public var onChange: (() -> Void)?
    private var task: Task<Void, Never>?
    private var paused = false
    private var started = Date()
    private var deadline = Date()
    private var settings = WorkflowSettings()
    private var config = AutomationConfiguration()
    private var io: (any WorkflowIO)?
    private var resumeStage: WorkflowStage = .idle
    private var skillTimes: [UUID: Date] = [:]
    private var routeTest = false

    public init() {}
    public var active: Bool { task != nil }

    public func start(configuration: AutomationConfiguration, settings: WorkflowSettings,
                      io: any WorkflowIO, routeTest: Bool = false) throws {
        guard task == nil else { throw CoordinatorError.invalidTransition }
        try configuration.validate(); try settings.validate()
        guard !configuration.dryRun else { throw WorkflowFailure.prerequisite("Use Detect only for dry runs. Live workflows require explicit live consent.") }
        guard !routeTest || configuration.mode == .fullAutomation else {
            throw WorkflowFailure.prerequisite("Route replay is available only in full automation mode")
        }
        guard routeTest || configuration.mode == .fullAutomation || settings.bankingEnabled else {
            throw WorkflowFailure.prerequisite("Enable jewel banking for jewels-only mode.")
        }
        try io.checkSafety()
        self.io = io; self.config = configuration; self.settings = settings
        self.routeTest = routeTest
        started = Date(); deadline = started.addingTimeInterval(settings.workflowTimeoutSeconds)
        skillTimes = [:]; paused = false
        lastError = nil; lastVerifiedAction = nil
        transition(.initializing, "Workflow started: \(configuration.mode.title)")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await run()
                transition(.completed, "Workflow completed with required visual checks")
            } catch is CancellationError {
                transition(.cancelled, "Cancelled; no future input will be scheduled")
            } catch {
                lastError = error.localizedDescription
                transition(.waitingForManualIntervention, error.localizedDescription)
            }
            task = nil; self.io = nil; onChange?()
        }
    }

    public func pause() {
        guard task != nil, !paused else { return }
        paused = true; resumeStage = stage
        transition(.paused, "Paused by user")
    }
    public func resume() throws {
        guard paused, let io else { throw CoordinatorError.invalidTransition }
        try io.checkSafety()
        paused = false
        transition(resumeStage, "Resumed; next action requires fresh visual evidence")
    }
    public func stop() {
        task?.cancel(); paused = false
        transition(.cancelled, "Emergency stop requested")
    }

    private func transition(_ value: WorkflowStage, _ message: String) {
        events.append(.init(previous: stage, stage: value, message: message,
                            observation: lastObservation, elapsed: Date().timeIntervalSince(started)))
        if events.count > 1000 { events.removeFirst(events.count - 1000) }
        stage = value; onChange?()
    }

    private func gate() async throws {
        try Task.checkCancellation()
        while paused {
            try await Task.sleep(nanoseconds: 100_000_000)
            try Task.checkCancellation()
        }
        guard Date() < deadline else { throw WorkflowFailure.timeout("Maximum workflow duration reached") }
        guard let io else { throw CancellationError() }
        try io.checkSafety()
    }

    private func observe() async throws -> Observation {
        try await gate()
        guard let io else { throw CancellationError() }
        let value = try await io.observe()
        try await gate()
        guard abs(value.timestamp.timeIntervalSinceNow) < 2 else { throw WorkflowFailure.unsafe("Stale screenshot") }
        lastObservation = value; onChange?()
        if [.disconnected, .loginScreen, .characterSelection].contains(value.state) {
            throw WorkflowFailure.unsafe("\(value.state.rawValue): manual intervention required")
        }
        return value
    }

    private func wait(_ label: String, timeout: Double? = nil, requiredVisible: TargetRole? = nil,
                      inputPrecondition: Bool = false,
                      condition: (Observation) -> Bool) async throws -> Observation {
        let until = Date().addingTimeInterval(timeout ?? settings.actionTimeoutSeconds)
        var attempt = 0
        while Date() < until {
            let frame = try await observe()
            if inputPrecondition && !frame.permitsInput(strictGameplayRecognition: config.strictGameplayRecognition) {
                throw WorkflowFailure.unsafe("Input blocked by detected interruption state: \(frame.state.rawValue)")
            }
            if config.strictGameplayRecognition, let requiredVisible, !frame.has(requiredVisible) {
                throw WorkflowFailure.uncertain("\(requiredVisible.rawValue) disappeared while waiting for \(label)")
            }
            if config.strictGameplayRecognition && frame.state == .unknown {
                throw WorkflowFailure.uncertain("Ambiguous state while waiting for \(label)")
            }
            if condition(frame) {
                lastVerifiedAction = label
                transition(stage, "Verified \(label)")
                return frame
            }
            attempt += 1
            if attempt <= settings.detectionRetries + 1 {
                transition(stage, "Detection poll \(attempt): waiting for \(label), state \(frame.state.rawValue)")
            }
            try await Task.sleep(nanoseconds: UInt64(settings.pollSeconds * 1_000_000_000))
        }
        throw WorkflowFailure.timeout("Unverified \(label); no action will be repeated automatically")
    }

    @discardableResult
    private func action(_ action: GameAction, requiring role: TargetRole) async throws -> Observation {
        var frame = try await observe()
        guard frame.permitsInput(strictGameplayRecognition: config.strictGameplayRecognition) else {
            throw WorkflowFailure.unsafe("Input blocked by detected interruption state: \(frame.state.rawValue)")
        }
        if !config.strictGameplayRecognition, role != .normalGameplay, !frame.has(role) {
            frame = try await wait("\(role.rawValue) before action", inputPrecondition: true) { $0.has(role) }
        }
        guard (role == .normalGameplay && !config.strictGameplayRecognition) || frame.has(role) else {
            throw WorkflowFailure.unsafe("Missing precondition target: \(role.rawValue)")
        }
        if case let .click(target) = action {
            let savedPosition = !config.strictGameplayRecognition && io?.hasCalibratedTarget(target) == true
            guard target != .withdrawExcluded, frame.has(target) || savedPosition else {
                throw WorkflowFailure.unsafe("Click target is missing or unrecognized: \(target.rawValue)")
            }
            if target == .transferButton && ((settings.bankingVerification == .newSuccessIndicator && frame.has(.transferSuccess)) || frame.has(.processingIndicator)) {
                throw WorkflowFailure.uncertain("Transfer precondition changed; existing success or processing evidence")
            }
            if target == .transferButton, settings.bankingVerification != .newSuccessIndicator,
               BankingVerifier.count(in: frame, mode: settings.bankingVerification, format: settings.countFormat) == nil {
                throw WorkflowFailure.uncertain("Fresh before-transfer count is unreadable")
            }
        }
        try await gate()
        guard let io else { throw CancellationError() }
        try await io.perform(action)
        transition(stage, "Delivered \(action); result pending visual verification")
        return frame
    }

    private func run() async throws {
        if routeTest { try await executeRoute(requireValidated: false); return }
        if settings.bankingEnabled { try await bank() }
        guard config.mode == .fullAutomation else { return }
        if config.helperEnabled { try await helper() }
        transition(.farming, "Monitoring configured farming indicators")
        var recoveries = 0
        var lastBank = Date()
        var skillsCompleted = false
        while true {
            let frame = try await observe()
            if frame.state == .possibleDeath || frame.state == .respawnScreen {
                guard config.recoveryEnabled, recoveries < settings.maximumRecoveries else {
                    throw WorkflowFailure.unsafe("Recovery disabled or maximum recoveries reached")
                }
                try await recover(initial: frame)
                recoveries += 1
            } else {
                guard [.normalGameplay, .helperRunning, .inventoryOpen].contains(frame.state)
                    || (!config.strictGameplayRecognition && frame.state == .unknown
                        && frame.permitsInput(strictGameplayRecognition: false)) else {
                    throw WorkflowFailure.uncertain("Unknown or unexpected farming state: \(frame.state.rawValue)")
                }
                if settings.inventoryMonitoringEnabled && settings.bankingEnabled && frame.has(.bankingTrigger)
                    && Date().timeIntervalSince(lastBank) >= settings.bankingCooldownSeconds {
                    try await bank(); lastBank = Date()
                    if config.helperEnabled { try await helper() }
                }
                if config.skillsEnabled && (!skillsCompleted || settings.repeatSkills) {
                    try await rotateSkills(); skillsCompleted = true
                }
            }
            transition(.farming, "Monitoring: \(lastObservation?.state.rawValue ?? "unknown")")
            try await Task.sleep(nanoseconds: UInt64(settings.pollSeconds * 1_000_000_000))
        }
    }

    private func bank() async throws {
        transition(.preparingInventory, "Checking inventory")
        var frame = try await observe()
        if !frame.has(.inventoryPanel) {
            try await action(.click(.inventoryControl), requiring: .normalGameplay)
            frame = try await wait("inventory panel") { $0.has(.inventoryPanel) }
        }
        if !frame.has(.bankTitle) {
            transition(.openingJewelBank, "Opening calibrated Jewel bank control once")
            try await action(.click(.bankControl), requiring: .inventoryPanel)
            frame = try await wait("Jewel bank") { $0.has(.bankTitle) }
        }
        // Existing success/processing evidence cannot be attributed to our new transfer.
        guard !frame.has(.processingIndicator), settings.bankingVerification != .newSuccessIndicator || !frame.has(.transferSuccess) else {
            throw WorkflowFailure.uncertain("Bank is already processing or shows stale success evidence")
        }
        if settings.bankingVerification != .newSuccessIndicator,
           BankingVerifier.count(in: frame, mode: settings.bankingVerification, format: settings.countFormat) == nil {
            throw WorkflowFailure.uncertain("Calibrated before-transfer count is unreadable or low confidence")
        }
        transition(.transferringJewels, "Transfer once; Withdraw is excluded")
        let before = try await action(.click(.transferButton), requiring: .bankTitle)
        transition(.verifyingBanking, "Waiting for a newly visible, calibrated success indicator")
        _ = try await wait("jewel transfer", requiredVisible: .bankTitle) {
            BankingVerifier.verified(before: before, after: $0, mode: self.settings.bankingVerification, format: self.settings.countFormat)
        }
        transition(.closingInventory, "Transfer verified; closing bank and inventory")
        try await action(.click(.bankClose), requiring: .bankTitle)
        _ = try await wait("bank closure") { !$0.has(.bankTitle) && $0.has(.inventoryPanel) }
        try await action(.click(.inventoryClose), requiring: .inventoryPanel)
        _ = try await wait("inventory closure") {
            !$0.has(.inventoryPanel) && ($0.has(.normalGameplay)
                || (!self.config.strictGameplayRecognition && $0.permitsInput(strictGameplayRecognition: false)))
        }
    }

    private func helper() async throws {
        let frame = try await observe()
        if frame.has(.helperRunning) { transition(.verifyingHelper, "Helper already running; no toggle sent"); return }
        transition(.openingHelper, "Opening helper")
        if !frame.has(.helperPanel) {
            try await action(.click(.helperControl), requiring: .normalGameplay)
            _ = try await wait("helper settings") { $0.has(.helperPanel) }
        }
        // Recheck active indicator immediately before considering Start.
        if try await observe().has(.helperRunning) { return }
        transition(.startingHelper, "Starting helper once")
        try await action(.click(.helperStart), requiring: .helperPanel)
        transition(.verifyingHelper, "Verifying helper active indicator")
        _ = try await wait("helper running") { $0.has(.helperRunning) && !$0.has(.helperPanel) }
    }

    private func rotateSkills() async throws {
        for skill in settings.skills {
            if let last = skillTimes[skill.id], Date().timeIntervalSince(last) < skill.cooldownSeconds { continue }
            let frame = try await observe()
            guard [.normalGameplay, .helperRunning].contains(frame.state)
                || (!config.strictGameplayRecognition && frame.state == .unknown
                    && frame.permitsInput(strictGameplayRecognition: false)) else { return }
            try await action(.key(skill.keyCode), requiring: .normalGameplay)
            skillTimes[skill.id] = Date()
            if let target = skill.verification { _ = try await wait("skill evidence") { $0.has(target) } }
            try await Task.sleep(nanoseconds: UInt64(skill.delaySeconds * 1_000_000_000))
        }
    }

    private func recover(initial: Observation) async throws {
        transition(.possibleDeath, "Gathering independent and temporally stable death/respawn evidence")
        if initial.state == .possibleDeath {
            var previous = initial.timestamp
            for _ in 0..<2 {
                try await Task.sleep(nanoseconds: UInt64(settings.pollSeconds * 1_000_000_000))
                let frame = try await observe()
                guard frame.timestamp > previous, frame.has(.deathIndicator), frame.has(.deathConfirmation) else {
                    throw WorkflowFailure.uncertain("Death evidence did not remain confirmed")
                }
                previous = frame.timestamp
            }
        }
        transition(.waitingForRespawn, "Waiting for stable respawn evidence")
        _ = try await wait("respawn", timeout: settings.recoveryTimeoutSeconds) { $0.has(.respawnIndicator) && !$0.has(.deathIndicator) }
        try await Task.sleep(nanoseconds: UInt64(settings.pollSeconds * 1_000_000_000))
        let stableRespawn = try await observe()
        guard stableRespawn.has(.respawnIndicator), !stableRespawn.has(.deathIndicator) else {
            throw WorkflowFailure.uncertain("Respawn was not stable across fresh captures")
        }
        try await executeRoute(requireValidated: true)
        if config.helperEnabled { try await helper() }
    }

    private func executeRoute(requireValidated: Bool) async throws {
        guard (!requireValidated || settings.route.validated), !settings.route.steps.isEmpty else {
            throw WorkflowFailure.prerequisite("Recovery route is empty or has not passed replay validation")
        }
        let routeDeadline = Date().addingTimeInterval(settings.routeTimeoutSeconds)
        func remaining() throws -> Double {
            let seconds = routeDeadline.timeIntervalSinceNow
            guard seconds > 0 else { throw WorkflowFailure.timeout("Maximum route duration reached") }
            return min(seconds, settings.actionTimeoutSeconds)
        }
        transition(.returningToSpot, "Executing \(settings.route.name) with verified checkpoints")
        for step in settings.route.steps {
            _ = try await wait("route checkpoint \(step.before.rawValue)", timeout: remaining()) { $0.has(step.before) }
            // Respawn is allowed only for a calibrated route precondition; never for banking/skills.
            let frame = try await observe()
            guard frame.has(step.before), !frame.has(.deathIndicator),
                  ([.normalGameplay, .helperRunning, .warpWindowOpen, .respawnScreen].contains(frame.state)
                   || (!config.strictGameplayRecognition && frame.state == .unknown
                       && frame.permitsInput(strictGameplayRecognition: false))) else {
                throw WorkflowFailure.unsafe("Route checkpoint lost or unsafe route state")
            }
            try await gate()
            guard let io else { throw CancellationError() }
            try await io.perform(step.action)
            _ = try await wait("route checkpoint \(step.after.rawValue)", timeout: remaining()) { $0.has(step.after) }
        }
        transition(.verifyingLocation, "Verifying destination and gameplay")
        _ = try await wait("farming destination", timeout: remaining()) {
            $0.has(.destinationLandmark) && ($0.has(.normalGameplay)
                || (!self.config.strictGameplayRecognition && $0.permitsInput(strictGameplayRecognition: false)))
        }
    }
}

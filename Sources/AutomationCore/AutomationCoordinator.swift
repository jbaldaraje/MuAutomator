import Foundation

/// One task owns input. Every action is evidence-gated; uncertain results never trigger an automatic second click.
@MainActor
public final class AutomationCoordinator {
    public private(set) var stage: WorkflowStage = .idle
    public private(set) var events: [WorkflowEvent] = []
    public private(set) var lastObservation: Observation?
    public private(set) var lastError: String?
    public private(set) var lastVerifiedAction: String?
    public private(set) var macroRunsCompleted = 0
    public private(set) var bankBalanceReading: BankBalanceReading?
    public private(set) var bankBalanceStatus = "Calibrate bankTitle and each jewel’s number under Named jewel balances."
    private var balanceTracker: BankBalanceTracker?
    public private(set) var namedBankBalanceReadings: [UUID: NamedBankBalanceReading] = [:]
    public private(set) var updatedBankBalanceIDs: Set<UUID> = []
    private var namedBalanceTracker: NamedBankBalanceTracker?
    public var onChange: (() -> Void)?
    private var task: Task<Void, Never>?
    private var paused = false
    public private(set) var isWaitingForFocus = false
    private var suspensionStarted: Date?
    private var suspendedSeconds = 0.0
    private var suspensionRevision = 0
    private var focusResumeStage: WorkflowStage = .idle
    private var started = Date()
    private var deadline = 0.0
    private var settings = WorkflowSettings()
    private var config = AutomationConfiguration()
    private var io: (any WorkflowIO)?
    private var resumeStage: WorkflowStage = .idle
    private var skillTimes: [UUID: Double] = [:]
    private var routeTest = false
    private var macroUsesOwnLimit = false
    private var refocusTimerStarted = Date()

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
        if !routeTest, settings.bankingEnabled, settings.bankingInputMode == .recordedInput {
            guard let recording = settings.bankingRecording, !recording.steps.isEmpty else {
                throw WorkflowFailure.prerequisite("Record the jewel workflow first")
            }
        }
        do { try io.checkSafety() } catch WorkflowFailure.focusUnavailable { }
        self.io = io; self.config = configuration; self.settings = settings
        self.routeTest = routeTest
        started = Date(); skillTimes = [:]; paused = false; isWaitingForFocus = false
        refocusTimerStarted = Date()
        suspensionStarted = nil; suspendedSeconds = 0; suspensionRevision = 0
        deadline = activeTime() + settings.workflowTimeoutSeconds
        lastError = nil; lastVerifiedAction = nil; macroRunsCompleted = 0; macroUsesOwnLimit = false
        transition(.initializing, "Workflow started: \(configuration.mode.title)")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await run()
                let message = settings.bankingInputMode == .recordedInput && configuration.mode == .jewelsOnly
                    ? "Recorded inputs finished; jewel transfer result was not visually verified"
                    : "Workflow completed with required visual checks"
                transition(.completed, message)
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
        resumeStage = isWaitingForFocus ? focusResumeStage : stage
        paused = true; suspensionRevision += 1; updateSuspensionClock()
        refocusTimerStarted = Date()
        transition(.paused, "Paused by user")
    }
    public func resume() throws {
        guard paused, let io else { throw CoordinatorError.invalidTransition }
        do { try io.checkSafety() } catch WorkflowFailure.focusUnavailable { }
        paused = false; updateSuspensionClock()
        transition(isWaitingForFocus ? .waitingForFocus : resumeStage, "Resumed; waiting for the selected game if it is not focused")
    }
    public func stop() {
        task?.cancel(); paused = false; updateSuspensionClock()
        transition(.cancelled, "Emergency stop requested")
    }

    private func transition(_ value: WorkflowStage, _ message: String) {
        events.append(.init(previous: stage, stage: value, message: message,
                            observation: lastObservation, elapsed: Date().timeIntervalSince(started)))
        if events.count > 1000 { events.removeFirst(events.count - 1000) }
        stage = value; onChange?()
    }

    private func updateSuspensionClock() {
        if paused || isWaitingForFocus {
            if suspensionStarted == nil { suspensionStarted = Date() }
        } else if let suspensionStarted {
            suspendedSeconds += Date().timeIntervalSince(suspensionStarted)
            self.suspensionStarted = nil
        }
    }

    private func waitForFocus(_ reason: String) async throws {
        guard let io else { throw CancellationError() }
        focusResumeStage = paused ? resumeStage : stage
        isWaitingForFocus = true; suspensionRevision += 1; updateSuspensionClock()
        if !paused { refocusTimerStarted = Date() }
        transition(paused ? .paused : .waitingForFocus, "Waiting for game focus: \(reason). No new presses will be sent.")
        var ready = false
        defer {
            isWaitingForFocus = false; updateSuspensionClock()
            if ready {
                transition(paused ? .paused : focusResumeStage,
                           paused ? "Game focus restored; still paused by user" : "Game focus restored; continuing with fresh evidence")
            }
        }
        while true {
            try Task.checkCancellation()
            _ = try await autoRefocusIfDue()
            do {
                try io.checkSafety()
                // Let the user's focus click/keyboard shortcut settle before input resumes.
                try await Task.sleep(nanoseconds: 250_000_000)
                try await io.prepareToResumeAfterFocus()
                try Task.checkCancellation()
                ready = true
                return
            } catch WorkflowFailure.focusUnavailable {
                try await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    private func gate() async throws {
        while true {
            try Task.checkCancellation()
            _ = try await autoRefocusIfDue()
            if paused {
                try await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            guard let io else { throw CancellationError() }
            do { try io.checkSafety() }
            catch WorkflowFailure.focusUnavailable(let reason) {
                try await waitForFocus(reason)
                continue
            }
            guard macroUsesOwnLimit || activeTime() < deadline else {
                throw WorkflowFailure.timeout("Maximum workflow duration reached")
            }
            return
        }
    }

    @discardableResult
    private func autoRefocusIfDue() async throws -> Bool {
        guard settings.autoRefocus.enabled,
              Date().timeIntervalSince(refocusTimerStarted) >= settings.autoRefocus.delaySeconds,
              let io else { return false }
        refocusTimerStarted = Date()
        defer { refocusTimerStarted = Date() }
        let revision = suspensionRevision
        do {
            try await io.refocusSelectedWindow()
            try Task.checkCancellation()
            // A new manual Pause during activation gets its own full interval.
            let canResumePause = revision == suspensionRevision
            suspensionRevision += 1
            if paused && canResumePause { paused = false; updateSuspensionClock() }
            transition(paused ? .paused : (isWaitingForFocus ? .waitingForFocus : (stage == .paused ? resumeStage : stage)),
                       paused ? "Auto-refocus restored the selected window; a newer manual Pause remains active"
                              : "Auto-refocus timer restored the selected game window; continuing the active session")
            return true
        } catch WorkflowFailure.focusUnavailable(let reason) {
            transition(stage, "Auto-refocus could not restore game input yet: \(reason). Will try again after the configured interval.")
            return false
        }
    }

    private func observe() async throws -> Observation {
        while true {
            try await gate()
            guard let io else { throw CancellationError() }
            let revision = suspensionRevision
            let value: Observation
            do { value = try await io.observe() }
            catch WorkflowFailure.focusUnavailable(let reason) {
                try await waitForFocus(reason)
                continue
            }
            try await gate()
            // A captured frame must not survive an intervening background/manual pause.
            guard revision == suspensionRevision else { continue }
            guard abs(value.timestamp.timeIntervalSinceNow) < 2 else { throw WorkflowFailure.unsafe("Stale screenshot") }
            balanceTracker?.observe(value, format: settings.countFormat)
            namedBalanceTracker?.observe(value)
            lastObservation = value; onChange?()
            if [.disconnected, .loginScreen, .characterSelection].contains(value.state) {
                throw WorkflowFailure.unsafe("\(value.state.rawValue): manual intervention required")
            }
            return value
        }
    }

    private func sessionDelay(_ seconds: Double) async throws {
        let until = activeTime() + seconds
        while true {
            try await gate()
            let remaining = until - activeTime()
            guard remaining > 0 else { return }
            try await Task.sleep(nanoseconds: UInt64(min(remaining, 0.1) * 1_000_000_000))
        }
    }

    private func wait(_ label: String, timeout: Double? = nil, requiredVisible: TargetRole? = nil,
                      target: TargetRole? = nil,
                      inputPrecondition: Bool = false,
                      condition: (Observation) -> Bool) async throws -> Observation {
        let until = activeTime() + (timeout ?? settings.actionTimeoutSeconds)
        var attempt = 0
        while true {
            try await gate()
            guard activeTime() < until else { break }
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
            try await sessionDelay(settings.pollSeconds)
        }
        let detail: String
        if let target {
            let score = lastObservation?.scores[target].map { String(format: "%.3f", $0) } ?? "unavailable"
            detail = " (\(target.rawValue) score: \(score))"
        } else { detail = "" }
        throw WorkflowFailure.timeout("Unverified \(label)\(detail); no action will be repeated automatically")
    }

    @discardableResult
    private func action(_ action: GameAction, requiring role: TargetRole) async throws -> Observation {
        while true {
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
            let revision = suspensionRevision
            try await gate()
            guard revision == suspensionRevision else { continue }
            guard let io else { throw CancellationError() }
            do {
                try await io.perform(action)
                refocusTimerStarted = Date()
                transition(stage, "Delivered \(io.describeAction(action)); result pending visual verification")
                return frame
            } catch WorkflowFailure.focusUnavailable(let reason) {
                try await waitForFocus(reason)
            } catch WorkflowFailure.focusLostAfterInput(let reason) {
                refocusTimerStarted = Date()
                transition(stage, "Input was delivered and released during focus loss; it will not be repeated")
                try await waitForFocus(reason)
                return frame
            }
        }
    }

    private func run() async throws {
        if routeTest { try await executeRoute(requireValidated: false); return }
        if settings.bankingEnabled { try await bank() }
        guard config.mode == .fullAutomation else { return }
        if config.helperEnabled { try await helper() }
        transition(.farming, "Monitoring configured farming indicators")
        var recoveries = 0
        var lastBank = activeTime()
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
                    && (activeTime() - lastBank) >= settings.bankingCooldownSeconds {
                    try await bank(); lastBank = activeTime()
                    if config.helperEnabled { try await helper() }
                }
                if config.skillsEnabled && (!skillsCompleted || settings.repeatSkills) {
                    try await rotateSkills(); skillsCompleted = true
                }
            }
            transition(.farming, "Monitoring: \(lastObservation?.state.rawValue ?? "unknown")")
            try await sessionDelay(settings.pollSeconds)
        }
    }

    private func bank() async throws {
        if settings.bankingInputMode == .recordedInput {
            guard let recording = settings.bankingRecording else {
                throw WorkflowFailure.prerequisite("Record the jewel workflow first")
            }
            let repetition = settings.macroRepeat
            let activeStart = activeTime()
            macroUsesOwnLimit = repetition.mode != .once
            defer {
                // Explicit macro count/hours owns this phase's limit. Other
                // workflow modules keep their remaining session time afterward.
                if macroUsesOwnLimit { deadline += activeTime() - activeStart }
                macroUsesOwnLimit = false
            }
            macroRunsCompleted = 0
            while repetition.allowsNextRun(completedRuns: macroRunsCompleted, elapsedSeconds: activeTime() - activeStart) {
                if macroRunsCompleted > 0 {
                    let stopAt = repetition.mode == .duration ? activeStart + repetition.durationSeconds : nil
                    try await recordedDelay(repetition.delayBetweenRunsSeconds, allowRespawn: false, stopAtActiveTime: stopAt)
                }
                try await gate()
                guard repetition.allowsNextRun(completedRuns: macroRunsCompleted, elapsedSeconds: activeTime() - activeStart) else { break }
                let progress = repetition.mode == .count ? "\(macroRunsCompleted + 1)/\(repetition.count)" : "\(macroRunsCompleted + 1)"
                transition(.preparingInventory, "Macro run \(progress): \(repetition.summary)")
                beginBalanceCollection()
                do { try await playback(recording, allowRespawn: false) }
                catch { finishBalanceCollection(completed: false); throw error }
                finishBalanceCollection(completed: true)
                macroRunsCompleted += 1
                transition(stage, "Completed macro run \(macroRunsCompleted); transfer result not visually verified")
            }
            transition(stage, "Recorded macro finished after \(macroRunsCompleted) runs; transfer result not verified")
            return
        }
        beginBalanceCollection()
        var collectionCompleted = false
        defer { finishBalanceCollection(completed: collectionCompleted) }
        transition(.preparingInventory, "Checking inventory")
        var frame = try await observe()
        if !frame.has(.inventoryPanel) {
            try await action(.click(.inventoryControl), requiring: .normalGameplay)
            frame = try await wait("inventory panel", target: .inventoryPanel) { $0.has(.inventoryPanel) }
        }
        if !frame.has(.bankTitle) {
            transition(.openingJewelBank, "Opening calibrated Jewel bank control once")
            try await action(.click(.bankControl), requiring: .inventoryPanel)
            frame = try await wait("Jewel bank", target: .bankTitle) { $0.has(.bankTitle) }
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
        collectionCompleted = true
    }

    private func beginBalanceCollection() {
        balanceTracker = BankBalanceTracker()
        namedBalanceTracker = NamedBankBalanceTracker()
        updatedBankBalanceIDs = []
        bankBalanceStatus = "Reading bank balance during collection…"
        onChange?()
    }

    private func finishBalanceCollection(completed: Bool) {
        defer { balanceTracker = nil; namedBalanceTracker = nil; onChange?() }
        guard completed else {
            bankBalanceStatus = "Collection interrupted; previous balances retained."
            return
        }
        let named = namedBalanceTracker?.readings ?? [:]
        for (id, value) in named {
            namedBankBalanceReadings[id] = value
            updatedBankBalanceIDs.insert(id)
            let amount = value.reading.added.map { "+\($0)" } ?? "not confirmed"
            transition(stage, "\(value.name) bank balance: \(value.reading.balance); amount added: \(amount)")
        }
        if let reading = balanceTracker?.reading {
            bankBalanceReading = reading
            bankBalanceStatus = reading.added == nil
                ? "Balance read, but the amount added could not be confirmed."
                : "Balance change observed in this collection; OCR does not independently prove a deposit."
            let amount = reading.added.map { "+\($0)" } ?? "not confirmed"
            transition(stage, "Bank balance: \(reading.balance); amount added: \(amount)")
        } else {
            bankBalanceStatus = "Couldn’t confirm this collection’s balance. Keep the bank open before and after depositing for two OCR reads. Check bankTitle, numeric regions and formats."
        }
        if !named.isEmpty {
            bankBalanceStatus = "Updated \(named.count) jewel balances. Rows marked Previous reading were not refreshed. Amounts are observed increases, not independent deposit proof."
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
            if let last = skillTimes[skill.id], (activeTime() - last) < skill.cooldownSeconds { continue }
            let frame = try await observe()
            guard [.normalGameplay, .helperRunning].contains(frame.state)
                || (!config.strictGameplayRecognition && frame.state == .unknown
                    && frame.permitsInput(strictGameplayRecognition: false)) else { return }
            try await action(.key(skill.keyCode), requiring: .normalGameplay)
            skillTimes[skill.id] = activeTime()
            if let target = skill.verification { _ = try await wait("skill evidence") { $0.has(target) } }
            try await sessionDelay(skill.delaySeconds)
        }
    }

    private func recover(initial: Observation) async throws {
        transition(.possibleDeath, "Gathering independent and temporally stable death/respawn evidence")
        if initial.state == .possibleDeath {
            var previous = initial.timestamp
            for _ in 0..<2 {
                try await sessionDelay(settings.pollSeconds)
                let frame = try await observe()
                guard frame.timestamp > previous, frame.has(.deathIndicator), frame.has(.deathConfirmation) else {
                    throw WorkflowFailure.uncertain("Death evidence did not remain confirmed")
                }
                previous = frame.timestamp
            }
        }
        transition(.waitingForRespawn, "Waiting for stable respawn evidence")
        _ = try await wait("respawn", timeout: settings.recoveryTimeoutSeconds) { $0.has(.respawnIndicator) && !$0.has(.deathIndicator) }
        try await sessionDelay(settings.pollSeconds)
        let stableRespawn = try await observe()
        guard stableRespawn.has(.respawnIndicator), !stableRespawn.has(.deathIndicator) else {
            throw WorkflowFailure.uncertain("Respawn was not stable across fresh captures")
        }
        try await executeRoute(requireValidated: true)
        if config.helperEnabled { try await helper() }
    }

    private func executeRoute(requireValidated: Bool) async throws {
        guard (!requireValidated || settings.route.validated), settings.route.hasActions else {
            throw WorkflowFailure.prerequisite("Recovery route is empty or has not passed replay validation")
        }
        let routeDeadline = activeTime() + settings.routeTimeoutSeconds
        func remaining() throws -> Double {
            let seconds = routeDeadline - activeTime()
            guard seconds > 0 else { throw WorkflowFailure.timeout("Maximum route duration reached") }
            return min(seconds, settings.actionTimeoutSeconds)
        }
        transition(.returningToSpot, "Executing \(settings.route.name) with verified checkpoints")
        if let recording = settings.route.recording {
            try await playback(recording, allowRespawn: true, deadline: routeDeadline)
        }
        for step in settings.route.recording == nil ? settings.route.steps : [] {
            _ = try await wait("route checkpoint \(step.before.rawValue)", timeout: remaining()) { $0.has(step.before) }
            // Respawn is allowed only for a calibrated route precondition; never for banking/skills.
            let frame = try await observe()
            guard frame.has(step.before), !frame.has(.deathIndicator),
                  ([.normalGameplay, .helperRunning, .warpWindowOpen, .respawnScreen].contains(frame.state)
                   || (!config.strictGameplayRecognition && frame.state == .unknown
                       && frame.permitsInput(strictGameplayRecognition: false))) else {
                throw WorkflowFailure.unsafe("Route checkpoint lost or unsafe route state")
            }
            try await deliverInput(step.action, allowRespawn: true, requiring: step.before, routeDeadline: routeDeadline)
            _ = try await wait("route checkpoint \(step.after.rawValue)", timeout: remaining()) { $0.has(step.after) }
        }
        transition(.verifyingLocation, "Verifying destination and gameplay")
        _ = try await wait("farming destination", timeout: remaining()) {
            $0.has(.destinationLandmark) && ($0.has(.normalGameplay)
                || (!self.config.strictGameplayRecognition && $0.permitsInput(strictGameplayRecognition: false)))
        }
    }

    private func playback(_ recording: InputRecording, allowRespawn: Bool, deadline playbackDeadline: Double? = nil) async throws {
        try recording.validate()
        guard !recording.steps.isEmpty else { throw WorkflowFailure.prerequisite("Input recording is empty") }
        func checkDeadline() throws {
            if let playbackDeadline, activeTime() >= playbackDeadline { throw WorkflowFailure.timeout("Maximum route duration reached") }
        }
        func checkFrame() async throws {
            try checkDeadline()
            let frame = try await observe()
            guard frame.permitsInput(strictGameplayRecognition: config.strictGameplayRecognition, allowRespawn: allowRespawn) else {
                throw WorkflowFailure.unsafe("Recorded playback stopped by \(frame.state.rawValue)")
            }
        }
        for (index, step) in recording.steps.enumerated() {
            try await recordedDelay(step.delayBeforeSeconds, allowRespawn: allowRespawn, routeDeadline: playbackDeadline)
            try await deliverInput(step.action, recorded: step, allowRespawn: allowRespawn, routeDeadline: playbackDeadline)
            transition(stage, "Replayed input \(index + 1)/\(recording.steps.count): \(io?.describeAction(step.action) ?? String(describing: step.action))")
        }
        try await recordedDelay(recording.tailDelaySeconds, allowRespawn: allowRespawn, routeDeadline: playbackDeadline)
        try await checkFrame()
    }

    private func deliverInput(_ action: GameAction, recorded: RecordedInputStep? = nil,
                              allowRespawn: Bool, requiring role: TargetRole? = nil,
                              routeDeadline: Double? = nil) async throws {
        while true {
            let frame = try await observe()
            let revision = suspensionRevision
            guard frame.permitsInput(strictGameplayRecognition: config.strictGameplayRecognition, allowRespawn: allowRespawn) else {
                throw WorkflowFailure.unsafe("Input blocked by \(frame.state.rawValue)")
            }
            if let role {
                guard frame.has(role), [.normalGameplay, .helperRunning, .warpWindowOpen, .respawnScreen].contains(frame.state)
                    || (!config.strictGameplayRecognition && frame.state == .unknown) else {
                    throw WorkflowFailure.unsafe("Route checkpoint lost or unsafe route state")
                }
            }
            try await gate()
            guard revision == suspensionRevision else { continue }
            if let routeDeadline, activeTime() >= routeDeadline { throw WorkflowFailure.timeout("Maximum route duration reached") }
            guard let io else { throw CancellationError() }
            do {
                if let recorded { try await io.performRecorded(recorded) }
                else { try await io.perform(action) }
                refocusTimerStarted = Date()
                return
            } catch WorkflowFailure.focusUnavailable(let reason) {
                try await waitForFocus(reason)
            } catch WorkflowFailure.focusLostAfterInput(let reason) {
                refocusTimerStarted = Date()
                transition(stage, "Input was delivered and released during focus loss; continuing at the next input after focus returns")
                try await waitForFocus(reason)
                return
            }
        }
    }

    private func activeTime() -> Double {
        Date().timeIntervalSinceReferenceDate - suspendedSeconds
            - (suspensionStarted.map { Date().timeIntervalSince($0) } ?? 0)
    }

    private func recordedDelay(_ seconds: Double, allowRespawn: Bool, routeDeadline: Double? = nil,
                               stopAtActiveTime: Double? = nil) async throws {
        var remaining = seconds
        while remaining > 0 {
            try await gate()
            let start = activeTime()
            if let stopAtActiveTime, start >= stopAtActiveTime { return }
            if let routeDeadline, activeTime() >= routeDeadline { throw WorkflowFailure.timeout("Maximum route duration reached") }
            let frame = try await observe()
            guard frame.permitsInput(strictGameplayRecognition: config.strictGameplayRecognition, allowRespawn: allowRespawn) else {
                throw WorkflowFailure.unsafe("Recorded playback stopped by \(frame.state.rawValue)")
            }
            var sleep = min(max(0, remaining - (activeTime() - start)), settings.pollSeconds, 0.25)
            if let stopAtActiveTime { sleep = min(sleep, max(0, stopAtActiveTime - activeTime())) }
            if sleep > 0 { try await Task.sleep(nanoseconds: UInt64(sleep * 1_000_000_000)) }
            remaining -= activeTime() - start
        }
    }
}

import AppKit
import ApplicationServices
import SwiftUI
import AutomationCore

@MainActor
final class SessionModel: ObservableObject {
    @Published var configuration = AutomationConfiguration()
    @Published var settings = WorkflowSettings()
    @Published var error: String?
    @Published var liveConsent = false
    @Published var failureReviewed = false
    @Published private(set) var arming = false
    @Published private(set) var reviewed = false
    @Published private(set) var lastClick: String?
    @Published private(set) var beforeClickFrame: CGImage?
    @Published private(set) var lastRunFrame: CGImage?
    @Published private(set) var lastRunObservation: Observation?
    @Published private(set) var lastRunProfile = CalibrationProfile()
    @Published private(set) var checkingBankRead = false
    @Published private(set) var bankReadCheckMessage: String?
    @Published private(set) var bestBankFrame: CGImage?
    @Published private(set) var bestBankObservation: Observation?
    private var bestBankScore = -Double.infinity
    let permissions = PermissionStatusModel()
    let capture = CaptureModel()
    let runner = AutomationCoordinator()
    let recorder = RouteRecorder()
    let windowQueue = WindowMacroQueue()
    @Published private(set) var windowProfiles: [WindowMacroProfile] = []
    @Published var windowProfileName = ""
    @Published private(set) var editingWindowProfileID: UUID?
    @Published var queueWindowAssignments: [UUID: CGWindowID] = [:]
    @Published var includedQueueProfiles: Set<UUID> = []
    @Published var queueInputConsent = false
    @Published var queueFailureReviewed = false
    @Published private(set) var queuePreparing = false
    private var queueReviewedProfiles: Set<UUID> = []
    private var queueHistory: [UUID: WindowMacroRuntime] = [:]
    private var windowProfilesLoadFailed = false
    private let directory: URL
    private var armTask: Task<Void, Never>?
    private var reviewedData: Data?
    private var globalStop: Any?
    private var localStop: Any?

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MUAutomator")
        do {
            configuration = try ConfigurationStore(url: directory.appendingPathComponent("configuration.json")).load()
            let file = directory.appendingPathComponent("workflow.json")
            if FileManager.default.fileExists(atPath: file.path) {
                settings = try JSONDecoder().decode(WorkflowSettings.self, from: Data(contentsOf: file))
                try settings.validate()
            }
        } catch { self.error = "Settings load failed: \(error.localizedDescription). Review before saving." }
        do {
            windowProfiles = try WindowMacroProfileStore(url: directory.appendingPathComponent("window-macros.json")).load()
            includedQueueProfiles = Set(windowProfiles.map(\.id))
        } catch {
            windowProfilesLoadFailed = true
            self.error = "Window macro profiles could not be loaded: \(error.localizedDescription)"
        }
        windowQueue.onChange = { [weak self] in
            guard let self else { return }
            for item in windowQueue.items { queueHistory[item.id] = item }
            objectWillChange.send()
        }
        runner.onChange = { [weak self] in self?.objectWillChange.send() }
        recorder.onChange = { [weak self] in self?.objectWillChange.send() }
        recorder.onRecorded = { [weak self] purpose, recording in
            guard let self else { return }
            if purpose == .jewelBanking {
                settings.bankingRecording = recording
                settings.bankingInputMode = .recordedInput
            } else {
                settings.route.recording = recording
                settings.route.validated = false
            }
        }
        globalStop = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.isStop(event) { Task { @MainActor [weak self] in self?.stop() } }
            else if Self.isRecordingStop(event) { Task { @MainActor [weak self] in self?.recorder.stop() } }
            else if Self.isPause(event) { Task { @MainActor [weak self] in self?.pauseFromHotkey() } }
        }
        localStop = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.isStop(event) { Task { @MainActor [weak self] in self?.stop() }; return nil }
            if Self.isRecordingStop(event) { Task { @MainActor [weak self] in self?.recorder.stop() }; return nil }
            if Self.isPause(event) { Task { @MainActor [weak self] in self?.pauseOrResume() }; return nil }
            return event
        }
    }

    nonisolated private static func isStop(_ event: NSEvent) -> Bool {
        event.keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option, .command]
    }

    nonisolated private static func isPause(_ event: NSEvent) -> Bool {
        event.keyCode == 35 && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option, .command]
    }
    nonisolated private static func isRecordingStop(_ event: NSEvent) -> Bool {
        event.keyCode == 15 && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option, .command]
    }

    var locked: Bool { runner.active || arming || recorder.active || checkingBankRead || queuePreparing || windowQueue.active }

    func save() {
        guard !locked else { return }
        do {
            try settings.validate()
            try ConfigurationStore(url: directory.appendingPathComponent("configuration.json")).save(configuration)
            try JSONEncoder().encode(settings).write(to: directory.appendingPathComponent("workflow.json"), options: .atomic)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func requestInputPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func reviewDetection() {
        guard capture.detection != nil else { error = "Run Detect only and inspect the results first"; return }
        do { reviewedData = try fingerprint(); reviewed = true; error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func fingerprint() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(capture.profile) + Data(String(capture.selectedID ?? 0).utf8)
    }

    private func requiredTargets(routeTest: Bool = false) -> Set<TargetRole> {
        CalibrationRequirements.roles(configuration: configuration, settings: settings, routeTest: routeTest)
    }
    var needsDetectionReview: Bool { !requiredTargets().isEmpty }

    func arm(routeTest: Bool = false) {
        guard !locked, !capture.busy else { return }
        do {
            try configuration.validate(); try settings.validate()
            if runner.stage == .waitingForManualIntervention && !failureReviewed {
                throw WorkflowFailure.prerequisite("Inspect the game and log, then acknowledge the unresolved previous attempt before starting a new workflow")
            }
            if windowQueue.lastError != nil && !queueFailureReviewed {
                throw WorkflowFailure.prerequisite("Resolve and acknowledge the failed Window queue before starting new input.")
            }
            guard liveConsent, !configuration.dryRun else { throw WorkflowFailure.prerequisite("Enable live mode and explicitly allow game input") }
            if !requiredTargets(routeTest: routeTest).isEmpty {
                guard reviewed, reviewedData == (try fingerprint()) else { throw WorkflowFailure.prerequisite("Calibration or window changed. Repeat dry-run review") }
            }
            guard let window = capture.windows.first(where: { $0.windowID == capture.selectedID }) else {
                throw WorkflowFailure.prerequisite("Select the game window first")
            }
            try MacWorkflowIO.requireTargets(requiredTargets(routeTest: routeTest), in: capture.profile,
                                             strictGameplayRecognition: configuration.strictGameplayRecognition)
            if !routeTest && configuration.mode == .fullAutomation && configuration.recoveryEnabled {
                guard settings.route.validated, settings.route.hasActions else {
                    throw WorkflowFailure.prerequisite("Configure and manually validate the recovery route first")
                }
            }
            let recordings = [
                !routeTest && settings.bankingEnabled && settings.bankingInputMode == .recordedInput ? settings.bankingRecording : nil,
                routeTest || (configuration.mode == .fullAutomation && configuration.recoveryEnabled) ? settings.route.recording : nil
            ].compactMap { $0 }
            for recording in recordings where !recording.matchesWindow(width: window.frame.width, height: window.frame.height) {
                throw WorkflowFailure.prerequisite("Restore the browser size used by the recording (\(Int(recording.windowWidth)) × \(Int(recording.windowHeight)) points), or record again")
            }
            let io = try MacWorkflowIO(window: window, profile: capture.profile,
                                       strictGameplayRecognition: configuration.strictGameplayRecognition,
                                       recordedWindow: recordings.first)
            configureDiagnostics(io)
            capture.stopPreview()
            save()
            failureReviewed = false
            arming = true; error = "Starting in 5 seconds. Focus the selected game window."
            let config = configuration, settings = self.settings
            armTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    try Task.checkCancellation()
                    error = "Verifying selected game window…"
                    try await io.prepareSelectedWindow()
                    try runner.start(configuration: config, settings: settings, io: io, routeTest: routeTest)
                    error = nil
                } catch is CancellationError { error = "Start cancelled" }
                catch { self.error = error.localizedDescription }
                arming = false; armTask = nil
            }
        } catch { self.error = error.localizedDescription }
    }

    private func configureDiagnostics(_ io: MacWorkflowIO) {
        lastClick = nil; beforeClickFrame = nil; lastRunFrame = nil; lastRunObservation = nil
        lastRunProfile = io.profile
        bestBankFrame = nil; bestBankObservation = nil; bestBankScore = -Double.infinity
        io.onFrame = { [weak self] image, observation in
            guard let self else { return }
            lastRunFrame = image; lastRunObservation = observation
            let score = observation.scores[.bankTitle] ?? -1
            if bestBankFrame == nil || score > bestBankScore {
                bestBankScore = score; bestBankFrame = image; bestBankObservation = observation
            }
        }
        io.onClick = { [weak self] description, image in
            self?.lastClick = description; self?.beforeClickFrame = image
        }
    }

    /// Exercise the same focused capture and recognition as playback, with no input delivery.
    func testLiveBankRead() {
        guard !locked, !capture.busy else { return }
        do {
            guard let window = capture.windows.first(where: { $0.windowID == capture.selectedID }) else {
                throw WorkflowFailure.prerequisite("Select your open.mu window in Calibration first.")
            }
            try MacWorkflowIO.requireTargets([.bankTitle], in: capture.profile,
                                             strictGameplayRecognition: configuration.strictGameplayRecognition)
            let recording = settings.bankingInputMode == .recordedInput ? settings.bankingRecording : nil
            let io = try MacWorkflowIO(window: window, profile: capture.profile,
                                       strictGameplayRecognition: configuration.strictGameplayRecognition,
                                       recordedWindow: recording)
            configureDiagnostics(io)
            capture.stopPreview()
            checkingBankRead = true
            bankReadCheckMessage = "Reading in 5 seconds. Focus the selected game and keep the Jewel Bank open. No clicks or keys will be sent."
            armTask = Task { [weak self] in
                guard let self else { return }
                defer { checkingBankRead = false; armTask = nil }
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    try Task.checkCancellation()
                    try await io.prepareSelectedWindow()
                    var recognized = false
                    for _ in 0..<3 {
                        let frame = try await io.observe()
                        recognized = recognized || frame.has(.bankTitle)
                        try await Task.sleep(nanoseconds: 250_000_000)
                    }
                    bankReadCheckMessage = recognized
                        ? "Live bank header matched. Inspect the focused-game reading below. This check does not change collection totals."
                        : "Live bank header did not match. Inspect its captured region and score below; compare them with Calibration."
                } catch is CancellationError {
                    bankReadCheckMessage = "Live bank reading cancelled."
                } catch {
                    bankReadCheckMessage = "Live bank reading failed: \(error.localizedDescription)"
                }
            }
        } catch { bankReadCheckMessage = error.localizedDescription }
    }

    func testInventoryClick() {
        guard !locked, !capture.busy else { return }
        do {
            guard liveConsent, !configuration.dryRun,
                  let window = capture.windows.first(where: { $0.windowID == capture.selectedID }),
                  capture.profile.targets.contains(where: { $0.role == .inventoryControl }) else {
                throw WorkflowFailure.prerequisite("Select the game, label inventoryControl, and allow live input first")
            }
            let io = try MacWorkflowIO(window: window, profile: capture.profile,
                                       strictGameplayRecognition: configuration.strictGameplayRecognition)
            configureDiagnostics(io)
            capture.stopPreview(); arming = true
            error = "Inventory click test in 5 seconds: focus the selected game. Sends one click; it may open or close inventory."
            armTask = Task { [weak self] in
                guard let self else { return }
                defer { arming = false; armTask = nil }
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    try await io.prepareSelectedWindow()
                    _ = try await io.observe()
                    try await io.perform(.click(.inventoryControl))
                    try await Task.sleep(nanoseconds: 500_000_000)
                    let result = try await io.observe()
                    error = result.has(.inventoryPanel)
                        ? "Single-click test: inventoryPanel recognized. No banking actions were sent."
                        : "Single-click test finished. inventoryPanel was not recognized. Compare the before/after frames below; no banking actions were sent."
                } catch is CancellationError { error = "Click test cancelled" }
                catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }

    func pauseOrResume() {
        if windowQueue.active {
            if windowQueue.paused { resumeWindowQueue() } else { windowQueue.pause() }
            return
        }
        guard !arming else { return }
        guard runner.stage == .paused else { runner.pause(); return }
        arming = true; error = "Resuming in 5 seconds. Focus the selected game window."
        armTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                try Task.checkCancellation()
                // The optional refocus timer can resume during this countdown.
                if runner.stage == .paused { try runner.resume() }
                error = nil
            } catch is CancellationError { error = "Resume cancelled" }
            catch { self.error = error.localizedDescription }
            arming = false; armTask = nil
        }
    }

    private func pauseFromHotkey() {
        if windowQueue.active {
            do { if windowQueue.paused { try windowQueue.resume() } else { windowQueue.pause() } }
            catch { self.error = error.localizedDescription }
            return
        }
        guard !arming else { return }
        do {
            if runner.stage == .paused { try runner.resume() } else { runner.pause() }
        } catch { self.error = error.localizedDescription }
    }

    func stop() {
        armTask?.cancel(); windowQueue.stop(); runner.stop(); liveConsent = false; queueInputConsent = false
        recorder.stop(saveRecording: false)
        objectWillChange.send()
    }

    func exportLog() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "MUAutomator-activity.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = runner.events.map { event in
                let balances = (event.observation?.namedBankBalances ?? [:]).values.sorted { $0.name < $1.name }.map { sample in
                    "\(sample.name): OCR=\(sample.text), count=\(sample.count.map { String($0) } ?? "unreadable"), confidence=\(sample.confidence), issue=\(sample.failureReason ?? "none")"
                }.joined(separator: "; ")
                return "\(event.timestamp.ISO8601Format()) | \(event.previous.rawValue) → \(event.stage.rawValue) | \(String(format: "%.2f", event.elapsed))s | \(event.message) | \(event.observation?.state.rawValue ?? "unknown") | matches: \(event.observation?.matches.description ?? "") | scores: \(event.observation?.scores.description ?? "") | OCR: \(event.observation?.text.description ?? "") | jewel OCR: \(balances)"
            }.joined(separator: "\n")
            let best = bestBankObservation
            let score = best?.scores[.bankTitle].map { String(format: "%.3f", $0) } ?? "unavailable"
            let threshold = lastRunProfile.targets.first { $0.role == .bankTitle }?.threshold
            let header = "Best live bankTitle score: \(score); saved threshold: \(threshold.map { String($0) } ?? "not calibrated"); matched: \(best?.has(.bankTitle) ?? false)\n"
            let queueLogs = queueHistory.values.sorted { $0.entry.profile.name < $1.entry.profile.name }.map { item in
                let events = item.runner.events.map { event in
                    let numbers = (event.observation?.namedBankBalances ?? [:]).values.sorted { $0.name < $1.name }.map {
                        "\($0.name): OCR=\($0.text), count=\($0.count.map { String($0) } ?? "unreadable"), confidence=\($0.confidence), issue=\($0.failureReason ?? "none")"
                    }.joined(separator: "; ")
                    return "\(event.timestamp.ISO8601Format()) | \(event.stage.rawValue) | \(event.message) | scores: \(event.observation?.scores.description ?? "") | jewel OCR: \(numbers)"
                }.joined(separator: "\n")
                return "Window macro: \(item.entry.profile.name) | window \(item.entry.windowID) | completed runs: \(item.completedRuns)\n" + events
            }.joined(separator: "\n\n")
            let report = "Last attempted click: \(lastClick ?? "none")\n" + header + text + "\n\n" + queueLogs
            try report.write(to: url, atomically: true, encoding: .utf8)
        } catch { self.error = error.localizedDescription }
    }
}

/// Display-only status. Live input still checks current permissions independently.
@MainActor
final class PermissionStatusModel: ObservableObject {
    typealias Reader = @Sendable () -> (screenRecording: Bool, accessibility: Bool)
    @Published private(set) var screenRecordingAllowed: Bool?
    @Published private(set) var accessibilityAllowed: Bool?
    private var refreshInFlight = false
    private let read: Reader

    init(read: @escaping Reader = { (CGPreflightScreenCaptureAccess(), AXIsProcessTrusted()) }) {
        self.read = read
    }

    func refresh() async {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        // Privacy-service queries must never block SwiftUI's rendering/main actor.
        let reader = read
        let status = await Task.detached(priority: .utility) { reader() }.value
        guard !Task.isCancelled else { return }
        if screenRecordingAllowed != status.screenRecording { screenRecordingAllowed = status.screenRecording }
        if accessibilityAllowed != status.accessibility { accessibilityAllowed = status.accessibility }
    }
}


@MainActor
extension SessionModel {
    func windowRuntime(_ id: UUID) -> WindowMacroRuntime? {
        windowQueue.items.first { $0.id == id } ?? queueHistory[id]
    }
    private func persistWindowProfiles(_ profiles: [WindowMacroProfile]) throws {
        guard !windowProfilesLoadFailed else {
            throw WorkflowFailure.prerequisite("The existing window-macros.json could not be read. Recover that file before saving new profiles; it has been left unchanged.")
        }
        try WindowMacroProfileStore(url: directory.appendingPathComponent("window-macros.json")).save(profiles)
        windowProfiles = profiles
    }
    func saveWindowProfile(replacing id: UUID? = nil) {
        guard !locked, !capture.busy else { return }
        do {
            if let id {
                guard editingWindowProfileID == id else { throw WorkflowFailure.prerequisite("Load this profile before updating it.") }
                if let assigned = queueWindowAssignments[id], capture.selectedID != assigned {
                    throw WorkflowFailure.prerequisite("Select this profile’s assigned game window before updating it.")
                }
            }
            var config = configuration
            config.mode = .jewelsOnly; config.helperEnabled = false; config.recoveryEnabled = false; config.skillsEnabled = false
            let profile = WindowMacroProfile(id: id ?? UUID(), name: windowProfileName.trimmingCharacters(in: .whitespacesAndNewlines),
                                             configuration: config, settings: settings, calibration: capture.profile)
            try profile.validate()
            var profiles = windowProfiles
            if let id {
                guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
                profiles[index] = profile
            } else { profiles.append(profile) }
            try persistWindowProfiles(profiles)
            editingWindowProfileID = profile.id
            if let windowID = capture.selectedID { queueWindowAssignments[profile.id] = windowID }
            includedQueueProfiles.insert(profile.id)
            queueReviewedProfiles.remove(profile.id)
            if reviewed, reviewedData == (try fingerprint()) { queueReviewedProfiles.insert(profile.id) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func removeWindowProfile(_ id: UUID) {
        guard !locked else { return }
        do {
            try persistWindowProfiles(windowProfiles.filter { $0.id != id })
            queueWindowAssignments.removeValue(forKey: id); includedQueueProfiles.remove(id)
            queueReviewedProfiles.remove(id); queueHistory.removeValue(forKey: id)
            if editingWindowProfileID == id { editingWindowProfileID = nil }
        } catch { self.error = error.localizedDescription }
    }
    func assignQueueWindow(_ id: UUID, windowID: CGWindowID?) {
        guard !locked else { return }
        queueWindowAssignments[id] = windowID; queueReviewedProfiles.remove(id)
    }
    func loadWindowProfile(_ id: UUID) {
        guard !locked, !capture.busy, let profile = windowProfiles.first(where: { $0.id == id }) else { return }
        do {
            try capture.applyWindowProfile(profile.calibration, windowID: queueWindowAssignments[id])
            settings = profile.settings; configuration = profile.configuration; windowProfileName = profile.name
            editingWindowProfileID = id
            reviewed = false; reviewedData = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func startWindowQueue(only id: UUID? = nil) {
        guard !locked, !capture.busy else { return }
        do {
            if runner.stage == .waitingForManualIntervention && !failureReviewed {
                throw WorkflowFailure.prerequisite("Resolve and acknowledge the previous Dashboard workflow before starting a queue.")
            }
            guard queueInputConsent else { throw WorkflowFailure.prerequisite("Allow queued input and automatic window switching first.") }
            if windowQueue.lastError != nil && !queueFailureReviewed {
                throw WorkflowFailure.prerequisite("Inspect the stopped queue and resolve the failed macro before restarting.")
            }
            let profiles = windowProfiles.filter { profile in
                if let id { return profile.id == id }
                return includedQueueProfiles.contains(profile.id)
            }
            // Validate every entry before binding or focusing any window.
            guard !profiles.isEmpty else { throw WorkflowFailure.prerequisite("Include at least one saved window macro.") }
            let assigned = profiles.compactMap { queueWindowAssignments[$0.id] }
            guard assigned.count == profiles.count, Set(assigned).count == assigned.count else {
                throw WorkflowFailure.prerequisite("Assign a different current game window to each included macro.")
            }
            var entries: [WindowMacroQueueEntry] = []
            var adapters: [MacWorkflowIO] = []
            for profile in profiles {
                try profile.validate()
                guard !profile.configuration.dryRun else {
                    throw WorkflowFailure.prerequisite("Load \(profile.name), turn Dry run off on Dashboard, then update that profile.")
                }
                guard let window = capture.windows.first(where: { $0.windowID == queueWindowAssignments[profile.id] }) else {
                    throw WorkflowFailure.prerequisite("Refresh windows and assign the current window for \(profile.name).")
                }
                let roles = CalibrationRequirements.roles(configuration: profile.configuration, settings: profile.settings)
                if !roles.isEmpty && !queueReviewedProfiles.contains(profile.id) {
                    throw WorkflowFailure.prerequisite("Load \(profile.name), run Detect only, confirm review on Dashboard, then update the profile for this window.")
                }
                try MacWorkflowIO.requireTargets(roles, in: profile.calibration,
                                                 strictGameplayRecognition: profile.configuration.strictGameplayRecognition)
                let io = try MacWorkflowIO(window: window, profile: profile.calibration,
                                           strictGameplayRecognition: profile.configuration.strictGameplayRecognition,
                                           recordedWindow: profile.settings.bankingRecording)
                entries.append(.init(profile: profile, windowID: window.windowID, io: io)); adapters.append(io)
            }
            capture.stopPreview(); queuePreparing = true; queueFailureReviewed = false
            error = "Queue starts in 5 seconds. It will bring each assigned game window to the front."
            armTask = Task { [weak self] in
                guard let self else { return }
                defer { queuePreparing = false; armTask = nil }
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    for io in adapters { try Task.checkCancellation(); try await io.prepareSelectedWindow() }
                    try Task.checkCancellation()
                    try windowQueue.start(entries, inputConsent: queueInputConsent)
                    error = nil
                } catch is CancellationError { error = "Window queue start cancelled." }
                catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    func resumeWindowQueue(entryID: UUID? = nil) {
        guard windowQueue.active, !arming else { return }
        arming = true; error = "Resuming in 5 seconds. Focus the active queue window."
        armTask = Task { [weak self] in
            guard let self else { return }
            defer { arming = false; armTask = nil }
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                try Task.checkCancellation()
                if let entryID { try windowQueue.resumeEntry(entryID) } else { try windowQueue.resume() }
                error = nil
            } catch is CancellationError { error = "Queue resume cancelled." }
            catch { self.error = error.localizedDescription }
        }
    }
}

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
    let permissions = PermissionStatusModel()
    let capture = CaptureModel()
    let runner = AutomationCoordinator()
    let recorder = RouteRecorder()
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

    var locked: Bool { runner.active || arming || recorder.active }

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
        io.onFrame = { [weak self] image, observation in
            self?.lastRunFrame = image; self?.lastRunObservation = observation
        }
        io.onClick = { [weak self] description, image in
            self?.lastClick = description; self?.beforeClickFrame = image
        }
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
        guard !arming else { return }
        guard runner.stage == .paused else { runner.pause(); return }
        arming = true; error = "Resuming in 5 seconds. Focus the selected game window."
        armTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                try Task.checkCancellation()
                try runner.resume(); error = nil
            } catch is CancellationError { error = "Resume cancelled" }
            catch { self.error = error.localizedDescription }
            arming = false; armTask = nil
        }
    }

    private func pauseFromHotkey() {
        guard !arming else { return }
        do {
            if runner.stage == .paused { try runner.resume() } else { runner.pause() }
        } catch { self.error = error.localizedDescription }
    }

    func stop() {
        armTask?.cancel(); runner.stop(); liveConsent = false
        recorder.stop(saveRecording: false)
        objectWillChange.send()
    }

    func exportLog() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "MUAutomator-activity.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = runner.events.map { event in
                "\(event.timestamp.ISO8601Format()) | \(event.previous.rawValue) → \(event.stage.rawValue) | \(String(format: "%.2f", event.elapsed))s | \(event.message) | \(event.observation?.state.rawValue ?? "unknown") | matches: \(event.observation?.matches.description ?? "") | scores: \(event.observation?.scores.description ?? "") | OCR: \(event.observation?.text.description ?? "")"
            }.joined(separator: "\n")
            let report = "Last attempted click: \(lastClick ?? "none")\n" + text
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

import SwiftUI
import AppKit
import ApplicationServices
import UniformTypeIdentifiers
import AutomationCore

@MainActor
final class ScreenMacroModel: ObservableObject {
    @Published private(set) var recording: ScreenMacro?
    @Published private(set) var recordingActive = false
    @Published private(set) var recordCountdown = false
    @Published private(set) var capturedEvents = 0
    @Published private(set) var message = "Record once. Replay across your desktop for the hours you choose."
    @Published private(set) var accessibilityAllowed = false
    @Published var hours = 1.0
    @Published var intervalSeconds = 0.0
    let player = ScreenMacroPlayer()
    private let store: ScreenMacroStore
    private var buffer: ScreenMacroBuffer?
    private var recordTask: Task<Void, Never>?
    private var recordingStarted = 0.0
    private var monitor: Any?
    private var globalKeys: Any?
    private var localKeys: Any?
    var busy: Bool { recordingActive || player.active }

    init(directory: URL? = nil) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MUAutomator")
        store = ScreenMacroStore(directory: directory)
        do { recording = try store.load() }
        catch { message = "Saved macro could not be read; the file was left unchanged. \(error.localizedDescription)" }
        do {
            let settings = try store.loadSettings()
            hours = settings.hours; intervalSeconds = settings.intervalSeconds
        }
        catch { message = "Saved hours could not be read; the file was left unchanged. \(error.localizedDescription)" }
        player.onChange = { [weak self] in
            guard let self else { return }
            if let error = player.error { message = error }
            else if player.phase == .completed { message = "Finished \(player.completedCycles) complete replays." }
            else if player.phase == .stopped { message = "Playback stopped. Injected keys and mouse buttons released." }
            else if player.phase == .waiting { message = "Waiting between complete replays. Stop remains available." }
            else if player.phase == .playing { message = "Replaying across the desktop. Cursor movement and window changes won’t stop it." }
            objectWillChange.send()
        }
        installShortcuts()
    }
    private func installShortcuts() {
        if let globalKeys { NSEvent.removeMonitor(globalKeys) }
        if let localKeys { NSEvent.removeMonitor(localKeys) }
        // NSEvent monitor callbacks run on the main thread; keep captured events in arrival order.
        globalKeys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { () -> Void in
                _ = self?.handleShortcut(event)
            }
        }
        localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleShortcut(event) == true }
            return handled ? nil : event
        }
    }
    @discardableResult private func handleShortcut(_ event: NSEvent) -> Bool {
        guard !DesktopEventCapture.isInjected(event) else { return false }
        if DesktopEventCapture.isControl(event, key: 53) { stop(); return true }
        if DesktopEventCapture.isControl(event, key: 15), recordingActive {
            finishRecording(trimmingShortcut: true); return true
        }
        return false
    }
    func refreshPermissions() async {
        let wasAllowed = accessibilityAllowed
        accessibilityAllowed = await Task.detached(priority: .utility) { AXIsProcessTrusted() }.value
        if accessibilityAllowed && (!wasAllowed || globalKeys == nil) { installShortcuts() }
    }
    func requestPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        let listening = CGRequestListenEventAccess()
        if AXIsProcessTrusted(), !listening,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
        Task { await refreshPermissions() }
    }
    func startRecording() {
        guard !busy else { return }
        guard AXIsProcessTrusted() else { requestPermissions(); message = "Enable Accessibility, then click Record again."; return }
        installShortcuts()
        recordingActive = true; recordCountdown = true; capturedEvents = 0
        message = "Recording starts in 5 seconds. Move to any app or screen."
        recordTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                try Task.checkCancellation()
                let layout = try DesktopInput.currentLayout()
                buffer = ScreenMacroBuffer(layout: layout)
                recordingStarted = ProcessInfo.processInfo.systemUptime
                monitor = NSEvent.addGlobalMonitorForEvents(matching: DesktopEventCapture.mask) { [weak self] event in
                    MainActor.assumeIsolated { () -> Void in
                        _ = self?.capture(event)
                    }
                }
                guard monitor != nil else { throw ScreenMacroError.invalid("Could not monitor input. Enable Input Monitoring and Accessibility, then reopen the app.") }
                recordCountdown = false
                message = "Recording desktop actions. Finish with Control–Option–Command–R."
                NSSound.beep()
                while ProcessInfo.processInfo.systemUptime - recordingStarted < ScreenMacro.maximumDuration {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    try Task.checkCancellation()
                    let (allowed, currentLayout) = try await Task.detached(priority: .utility) {
                        (AXIsProcessTrusted(), try DesktopInput.currentLayout())
                    }.value
                    try Task.checkCancellation()
                    guard allowed else { throw ScreenMacroError.invalid("Recording stopped because Accessibility permission was revoked. Previous macro kept.") }
                    guard layout.matches(currentLayout) else {
                        throw ScreenMacroError.invalid("Recording stopped because the display arrangement changed. Previous macro kept.")
                    }
                }
                finishRecording()
            } catch is CancellationError { }
            catch { cancelRecording(); message = error.localizedDescription }
        }
    }
    private func capture(_ event: NSEvent) {
        guard recordingActive, !recordCountdown else { return }
        if event.type == .keyDown && handleShortcut(event) { return }
        if (event.type == .keyDown || event.type == .keyUp),
           DesktopEventCapture.isControl(event, key: 15) || DesktopEventCapture.isControl(event, key: 53) { return }
        guard let value = DesktopEventCapture.convert(event, since: recordingStarted) else { return }
        do {
            try buffer?.append(value)
            // Avoid rebuilding the UI at the mouse-event rate.
            let count = buffer?.events.count ?? 0
            if count % 15 == 0 { capturedEvents = count }
        } catch ScreenMacroError.recordingLimit {
            finishRecording()
        } catch {
            cancelRecording()
            message = "Recording cancelled; previous macro kept. \(error.localizedDescription)"
        }
    }
    func finishRecording(trimmingShortcut: Bool = false) {
        guard recordingActive else { return }
        let captured = buffer
        let end = ProcessInfo.processInfo.systemUptime - recordingStarted
        removeRecordingMonitor()
        guard let captured else { message = "Recording countdown cancelled. Previous macro kept."; return }
        do {
            let macro = try captured.finish(at: end, trimmingStopShortcut: trimmingShortcut)
            recording = macro; capturedEvents = macro.events.count
            do { try store.save(macro); message = "Recording saved. Choose hours, then Play." }
            catch { message = "Recording is ready in memory. Autosave failed: \(error.localizedDescription). Use Save macro." }
        } catch { message = "Previous macro kept. \(error.localizedDescription)" }
    }
    private func removeRecordingMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; recordTask?.cancel(); recordTask = nil
        buffer = nil; recordingActive = false; recordCountdown = false
    }
    private func cancelRecording() { removeRecordingMonitor() }
    func savePlaybackSettings() {
        do { try store.saveSettings(ScreenMacroSettings(hours: hours, intervalSeconds: intervalSeconds)) }
        catch { message = error.localizedDescription }
    }
    func play() {
        guard !busy, let recording else { return }
        do {
            try store.saveSettings(ScreenMacroSettings(hours: hours, intervalSeconds: intervalSeconds))
            installShortcuts()
            guard globalKeys != nil else { throw ScreenMacroError.invalid("Could not install Emergency Stop. Check input permissions and reopen the app.") }
            try player.start(recording, hours: hours, intervalSeconds: intervalSeconds, io: DesktopInput())
            message = "Playback starts in 5 seconds. Cursor movement and changing windows will not stop it."
        } catch { message = error.localizedDescription }
    }
    func stop() {
        if recordingActive { cancelRecording(); message = "Recording cancelled. Previous macro kept." }
        player.stop()
    }
    func openMacro() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let macro = try ScreenMacroStore.read(url)
            try store.save(macro); recording = macro; message = "Macro opened. Ready to replay across the desktop."
        } catch { message = "Could not open macro. Choose a whole-screen macro from this version. \(error.localizedDescription)" }
    }
    func exportMacro() {
        guard !busy, let recording else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Screen Macro.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ScreenMacroStore.write(recording, to: url); message = "Macro file saved." }
        catch { message = error.localizedDescription }
    }
    func shutDown() {
        savePlaybackSettings()
        stop()
        if let globalKeys { NSEvent.removeMonitor(globalKeys) }; globalKeys = nil
        if let localKeys { NSEvent.removeMonitor(localKeys) }; localKeys = nil
    }
}

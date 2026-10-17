import AppKit
import ScreenCaptureKit
import SwiftUI
import AutomationCore

enum RecordingPurpose: String, CaseIterable {
    case jewelBanking = "Jewel workflow"
    case returnRoute = "Return to spot"
}

/// Observes the user's own input. Starting/stopping recording never injects events.
@MainActor
final class RouteRecorder: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var message = "Record your game clicks, key holds and pauses."
    @Published private(set) var recording: InputRecording?
    @Published var purpose: RecordingPurpose = .jewelBanking
    var onChange: (() -> Void)?
    var onRecorded: ((RecordingPurpose, InputRecording) -> Void)?
    private var monitor: Any?
    private var lifetime: Task<Void, Never>?
    private var io: MacWorkflowIO?
    private var frame = CGRect.zero
    private var previousRelease: TimeInterval = 0
    private var pending: (action: GameAction, time: TimeInterval)?
    private var recordingPurpose: RecordingPurpose = .jewelBanking

    func start(window: SCWindow, profile: CalibrationProfile) {
        guard !active else { return }
        do {
            let dimensions = InputRecording(windowWidth: window.frame.width, windowHeight: window.frame.height)
            io = try MacWorkflowIO(window: window, profile: profile, recordedWindow: dimensions)
            frame = window.frame; recording = dimensions; pending = nil; active = true
            recordingPurpose = purpose
            message = "Focus the selected game and wait for the beep after 5 seconds before acting. Maximum recording: 120 seconds."
            onChange?()
            lifetime = Task { [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    try await io?.prepareSelectedWindow()
                    try Task.checkCancellation()
                    try io?.checkSafety()
                    if let io { frame = io.captureBounds }
                    previousRelease = ProcessInfo.processInfo.systemUptime
                    monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown, .keyUp]) { [weak self] event in
                        Task { @MainActor [weak self] in self?.record(event) }
                    }
                    guard monitor != nil else { throw WorkflowFailure.prerequisite("Could not start input monitoring; check Accessibility permission") }
                    NSSound.beep()
                    message = "Recording now. Perform only the desired game sequence, then press Control–Option–Command–R to stop."
                    try await Task.sleep(nanoseconds: 120_000_000_000)
                    stop()
                } catch is CancellationError { }
                catch { message = error.localizedDescription; stop(saveRecording: false) }
            }
        } catch { message = error.localizedDescription }
    }

    private func record(_ event: NSEvent) {
        guard active, monitor != nil else { return }
        // App commands are never stored as game input.
        if event.modifierFlags.intersection([.command, .option, .control]) == [.command, .option, .control] { return }
        do {
            try io?.checkSafety()
            guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
                throw WorkflowFailure.prerequisite("Recording stopped: modifier shortcuts are not supported")
            }
            if event.type == .keyDown && event.isARepeat { return }
            switch event.type {
            case .leftMouseDown, .keyDown:
                guard pending == nil else { throw WorkflowFailure.prerequisite("Recording stopped: use one mouse/key control at a time") }
                let action: GameAction
                if event.type == .leftMouseDown {
                    guard let point = event.cgEvent?.location, frame.contains(point),
                          MacWorkflowIO.topWindow(at: point) == io?.window.windowID else {
                        throw WorkflowFailure.prerequisite("Recording stopped: click was outside the selected window")
                    }
                    action = .point(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
                } else { action = .key(event.keyCode) }
                pending = (action, event.timestamp)
            case .leftMouseUp, .keyUp:
                guard let press = pending else { return }
                switch press.action {
                case .point(let x, let y):
                    guard event.type == .leftMouseUp else { return }
                    guard let end = event.cgEvent?.location,
                          hypot(end.x - (frame.minX + x * frame.width), end.y - (frame.minY + y * frame.height)) <= 4 else {
                        throw WorkflowFailure.prerequisite("Recording stopped: mouse drags are not supported")
                    }
                case .key(let code): guard event.type == .keyUp, event.keyCode == code else { return }
                case .click: return
                }
                let step = RecordedInputStep(action: press.action,
                                            delayBeforeSeconds: max(0, press.time - previousRelease),
                                            holdSeconds: max(0.01, event.timestamp - press.time))
                var updated = recording!
                updated.steps.append(step)
                try updated.validate()
                recording = updated; pending = nil; previousRelease = event.timestamp
                message = "Recorded \(updated.steps.count) inputs with timing. Press Control–Option–Command–R to stop."
                if updated.steps.count >= 200 { stop() }
            default: break
            }
        } catch { pending = nil; message = error.localizedDescription; stop(saveRecording: false) }
    }

    func stop(saveRecording: Bool = true) {
        guard active else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; lifetime?.cancel(); lifetime = nil; io = nil
        if saveRecording, pending != nil {
            message = "Recording ended with an unfinished press. Previous saved sequence kept; release all controls before stopping a new recording."
        } else if saveRecording, var value = recording, !value.steps.isEmpty {
            value.tailDelaySeconds = min(120, max(0, ProcessInfo.processInfo.systemUptime - previousRelease))
            if (try? value.validate()) != nil {
                recording = value; onRecorded?(recordingPurpose, value)
                message = "Saved \(value.steps.count) inputs for \(recordingPurpose.rawValue). Review the recording in Workflows, then Save settings."
            }
        } else if saveRecording { message = "No completed inputs recorded; the previous saved sequence was kept." }
        pending = nil; active = false; onChange?()
    }
}

@MainActor
struct RouteRecordingView: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var recorder: RouteRecorder
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Record game inputs").font(.title2)
            Picker("Record for", selection: $recorder.purpose) {
                ForEach(RecordingPurpose.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).disabled(recorder.active)
            Text(recorder.message).textSelection(.enabled)
            Text(recorder.purpose == .jewelBanking
                 ? "Start with inventory and bank closed. Record opening inventory → opening bank → transferring jewels → closing panels. This captures your actual input and timing; no button image labels are needed."
                 : "Start in the spawn area. Record the clicks and keys that return to your farming spot, including travel pauses. OCR death/spawn detection and the final destination check remain separate.")
            HStack {
                Button("Record in 5 seconds") {
                    guard let window = model.capture.windows.first(where: { $0.windowID == model.capture.selectedID }) else { return }
                    model.capture.stopPreview()
                    recorder.start(window: window, profile: model.capture.profile)
                }.disabled(recorder.active || model.capture.selectedID == nil || model.capture.busy)
                Button("Stop recording") { recorder.stop() }.disabled(!recorder.active)
            }
            Text("Wait for the beep before starting. Release all controls, then stop from the game with Control–Option–Command–R. Recording observes your own input; it never sends clicks. Left clicks, unmodified key presses/holds and pauses are supported. Drags and simultaneous controls are not supported. Keep browser size, game layout and zoom consistent for playback.")
                .font(.caption).foregroundStyle(.secondary)
            if let recording = recorder.recording {
                List(Array(recording.steps.enumerated()), id: \.element.id) { index, step in
                    Text("\(index + 1). Wait \(step.delayBeforeSeconds, specifier: "%.2f")s • \(String(describing: step.action)) • hold \(step.holdSeconds, specifier: "%.2f")s")
                        .font(.caption.monospaced())
                }
            }
        }.padding(24).disabled(model.runner.active || model.arming)
    }
}

import AppKit
import ScreenCaptureKit
import SwiftUI
import AutomationCore

/// Records user-delivered taps, never injects input. Each recorded step needs explicit checkpoint review.
@MainActor
final class RouteRecorder: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var message = "Records left-click points and unmodified key taps in the selected game window."
    @Published private(set) var steps: [RouteStep] = []
    var onChange: (() -> Void)?
    var onRecorded: (([RouteStep]) -> Void)?
    private var monitor: Any?
    private var lifetime: Task<Void, Never>?
    private var io: MacWorkflowIO?
    private var frame = CGRect.zero

    func start(window: SCWindow, profile: CalibrationProfile) {
        guard !active else { return }
        do {
            io = try MacWorkflowIO(window: window, profile: profile)
            frame = window.frame; steps = []; active = true
            message = "Recording starts in 5 seconds; focus the game. Maximum duration: 120 seconds."
            onChange?()
            lifetime = Task { [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    try await io?.prepareSelectedWindow()
                    try Task.checkCancellation()
                    try io?.checkSafety()
                    if let io { frame = io.captureBounds }
                    monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
                        Task { @MainActor [weak self] in self?.record(event) }
                    }
                    message = "Recording. Stop recording before editing and testing checkpoints."
                    try await Task.sleep(nanoseconds: 120_000_000_000)
                    stop()
                } catch is CancellationError { }
                catch { message = error.localizedDescription; stop() }
            }
        } catch { message = error.localizedDescription }
    }

    private func record(_ event: NSEvent) {
        guard active else { return }
        do {
            try io?.checkSafety()
            let action: GameAction
            if event.type == .leftMouseDown {
                guard let point = event.cgEvent?.location, frame.contains(point) else { return }
                action = .point(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
            } else {
                guard !event.isARepeat, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return }
                action = .key(event.keyCode)
            }
            steps.append(.init(action: action, before: .routeCheckpoint, after: .routeCheckpoint2))
            message = "Recorded \(steps.count) taps. Assign the actual before/after landmarks to every step."
            if steps.count >= 200 { stop() }
        } catch { message = "Recording stopped: \(error.localizedDescription)"; stop() }
    }

    func stop() {
        guard active else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; lifetime?.cancel(); lifetime = nil; io = nil
        active = false; onRecorded?(steps); onChange?()
    }
}

@MainActor
struct RouteRecordingView: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var recorder: RouteRecorder
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Record return route").font(.title2)
            Text(recorder.message)
            Text("Select the game window in Calibration first. This records your clicks and key taps; it does not play them back. Finish recording, assign visual checkpoints in Workflows, and manually validate before enabling recovery.")
            HStack {
                Button("Record in 5 seconds") {
                    guard let window = model.capture.windows.first(where: { $0.windowID == model.capture.selectedID }) else { return }
                    model.capture.stopPreview()
                    recorder.start(window: window, profile: model.capture.profile)
                }.disabled(recorder.active || model.capture.selectedID == nil)
                Button("Stop recording") { recorder.stop() }.disabled(!recorder.active)
            }
            Text("Holds, drags, modifiers, and route timing are not recorded. Replays wait for visual checkpoints instead of replaying arbitrary timing.")
                .font(.caption).foregroundStyle(.secondary)
            List(recorder.steps) { Text(String(describing: $0.action)).font(.body.monospaced()) }
        }.padding(24).disabled(model.runner.active || model.arming)
    }
}

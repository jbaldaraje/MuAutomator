import SwiftUI
import AppKit
import ApplicationServices
import AutomationCore

@main
@MainActor
struct MUAutomatorApp: App {
    @StateObject private var model = SessionModel()
    init() { NSApplication.shared.setActivationPolicy(.regular) }
    var body: some Scene {
        WindowGroup {
            AppShellView(model: model)
        }.defaultSize(width: 1100, height: 800)
    }
}

private enum AppScreen: String, CaseIterable {
    case dashboard = "Dashboard"
    case calibration = "Calibration"
    case workflows = "Workflows"
    case recording = "Record inputs"
    case activity = "Activity"

    var symbol: String {
        switch self {
        case .dashboard: return "gauge"
        case .calibration: return "viewfinder"
        case .workflows: return "gearshape"
        case .recording: return "record.circle"
        case .activity: return "list.bullet"
        }
    }
}

@MainActor
private struct AppShellView: View {
    @ObservedObject var model: SessionModel
    @State private var selection: AppScreen = .dashboard

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MU Automator").font(.title.bold())
                Spacer()
                Text(model.runner.stage.rawValue)
                Button("Emergency Stop", role: .destructive) { model.stop() }
            }.padding()
            HStack(spacing: 8) {
                ForEach(AppScreen.allCases, id: \.self) { screen in
                    Button { selection = screen } label: {
                        Label(screen.rawValue, systemImage: screen.symbol)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selection == screen ? Color.accentColor : Color.primary)
                    .background(Color.accentColor.opacity(selection == screen ? 0.12 : 0),
                                in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityAddTraits(selection == screen ? .isSelected : [])
                }
                Spacer()
            }.padding(.horizontal).padding(.bottom, 12)
            Divider()
            // macOS 26's native TabView can cycle in StatefulTabContainer's
            // accessibility graph when reinserting Dashboard. Mount only the
            // selected screen; durable state stays in the app-owned models.
            selectedScreen
                .id(selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, minHeight: 700)
        .background(WindowCloseObserver {
            model.stop()
            model.capture.stopPreview()
        }.frame(width: 0, height: 0))
    }

    @ViewBuilder private var selectedScreen: some View {
        switch selection {
        case .dashboard:
            DashboardView(model: model, capture: model.capture, permissions: model.permissions)
        case .calibration:
            ScrollView {
                CalibrationView(capture: model.capture, configuration: model.configuration, settings: model.settings).padding()
            }
                .disabled(model.locked)
        case .workflows:
            WorkflowSettingsView(model: model)
        case .recording:
            RouteRecordingView(model: model, recorder: model.recorder)
        case .activity:
            ActivityLogView(model: model)
        }
    }
}

// View disappearance also happens during hierarchy updates. Stop automation
// on the owning window's actual close notification, never on screen changes.
@MainActor
private struct WindowCloseObserver: NSViewRepresentable {
    var onClose: () -> Void

    func makeNSView(context: Context) -> WindowCloseObservationView {
        WindowCloseObservationView(onClose: onClose)
    }

    func updateNSView(_ nsView: WindowCloseObservationView, context: Context) {
        nsView.onClose = onClose
    }

    static func dismantleNSView(_ nsView: WindowCloseObservationView, coordinator: ()) {
        nsView.stopObserving()
    }
}

@MainActor
final class WindowCloseObservationView: NSView {
    var onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                                   name: NSWindow.willCloseNotification, object: window)
        }
    }

    func stopObserving() {
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
    }

    @objc private func windowWillClose(_ notification: Notification) { onClose() }
}

@MainActor
struct DashboardView: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var capture: CaptureModel
    @ObservedObject var permissions: PermissionStatusModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Automation mode") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Mode", selection: $model.configuration.mode) {
                            ForEach(AutomationMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                        Text(model.settings.bankingInputMode == .recordedInput
                             ? "Replay your recorded clicks, key holds and timing. Jewel transfer is not verified by playback alone. OCR recovery remains available in full automation."
                             : model.configuration.mode == .jewelsOnly
                             ? "Bank jewels already in inventory, verify the transfer, close panels, then stop."
                             : "Bank, activate enabled helper, monitor farming, and run enabled skills and recovery.")
                        Toggle("Dry run (use Detect only in Calibration)", isOn: $model.configuration.dryRun)
                        Toggle("Strict gameplay recognition (require normalGameplay)", isOn: $model.configuration.strictGameplayRecognition)
                        Text(model.configuration.strictGameplayRecognition
                             ? "Strict: general gameplay and interruption labels are required."
                             : "Relaxed: recorded playback uses saved inputs and timing. The image workflow uses saved control positions with panel/result checks. Configured interruptions and window focus are checked in both.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("I explicitly allow live mouse and keyboard input to my selected game window", isOn: $model.liveConsent)
                        if model.runner.stage == .waitingForManualIntervention {
                            Toggle("I inspected the game and log and resolved the previous unverified result", isOn: $model.failureReviewed)
                        }
                    }.padding(8)
                }.disabled(model.locked)
                GroupBox("Readiness & controls") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Window: \(capture.selectedID.map { String($0) } ?? "not selected")")
                        Text("Game state: \(model.runner.lastObservation?.state.rawValue ?? "unknown")")
                        Text("Last verified result: \(model.runner.lastVerifiedAction ?? "none")")
                        if let error = model.runner.lastError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                        Text("Screen Recording: \(permissionLabel(permissions.screenRecordingAllowed)) • Accessibility: \(permissionLabel(permissions.accessibilityAllowed))")
                        Button("Request Accessibility for live input") { model.requestInputPermission() }
                            .disabled(model.locked)
                        if model.needsDetectionReview {
                            Button(model.reviewed ? "Reconfirm dry-run detection reviewed" : "Confirm I reviewed dry-run detection") { model.reviewDetection() }
                                .disabled(model.locked)
                        } else {
                            Text("Recorded-input playback needs a saved recording and selected game window. Image calibration is optional; add OCR labels when enabling recovery.")
                                .font(.caption)
                        }
                        HStack {
                            Button("Start in 5 seconds") { model.arm() }.disabled(model.locked)
                            Button(model.runner.stage == .paused ? "Resume" : "Pause") { model.pauseOrResume() }
                                .disabled(!model.runner.active || model.arming)
                            Button("Save settings") { model.save() }.disabled(model.locked)
                        }
                        Button("Test inventory click only (5 seconds)") { model.testInventoryClick() }
                            .disabled(model.locked || capture.busy)
                        Text("The click test sends one inventory-button click and captures the result. It does not open the bank or transfer jewels.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("After Start/Resume, focus the game. Pause/resume: Control–Option–Command–P. Emergency Stop: Control–Option–Command–Escape. Delivered input cannot be retracted.")
                            .font(.caption)
                        Text("Last event: \(model.runner.events.last?.message ?? "none")").textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                if !model.locked, let image = model.lastRunFrame {
                    DisclosureGroup("Last click and captured game — inspect alignment") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(model.lastClick ?? "No click attempted").font(.caption.monospaced()).textSelection(.enabled)
                            if let observation = model.lastRunObservation {
                                ForEach(model.lastRunProfile.targets.filter { [.inventoryPanel, .bankTitle].contains($0.role) }) { target in
                                    let score = observation.scores[target.role].map { String(format: "%.3f", $0) } ?? "unavailable"
                                    Text("\(target.role.rawValue): \(observation.has(target.role) ? "matched" : "not matched") • score \(score), threshold \(target.threshold, specifier: "%.3f")")
                                        .font(.caption.monospaced())
                                }
                            }
                            if let before = model.beforeClickFrame {
                                Text("Before the last click").font(.caption)
                                Image(decorative: before, scale: 1).resizable().scaledToFit().frame(maxHeight: 320)
                            }
                            Text("Latest captured frame").font(.caption)
                            Image(decorative: image, scale: 1).resizable().scaledToFit().frame(maxHeight: 420)
                            Text("Frames stay in memory for this attempt; they are not written to the activity log. If the position is wrong, select inventoryControl in Calibration and use Set click from game cursor.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 8)
                    }
                }
                Text(model.settings.bankingInputMode == .recordedInput
                     ? "Recorded playback needs the same browser size, zoom and game layout. Set the game to the same starting state before running. OCR recovery requires real death, spawn and destination examples."
                     : "macOS adapters and actual gameplay still require local acceptance testing. Calibrate verification evidence using real before/after examples; a static bank title is not transfer success.")
                    .foregroundStyle(.secondary)
            }.padding(24)
        }
        .task {
            // SwiftUI cancels this task when Dashboard leaves the visible hierarchy.
            while !Task.isCancelled {
                await permissions.refresh()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
            }
        }
    }

    private func permissionLabel(_ allowed: Bool?) -> String {
        allowed.map { $0 ? "allowed" : "missing" } ?? "checking…"
    }
}

@MainActor
struct ActivityLogView: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        VStack(alignment: .leading) {
            Button("Export activity log") { model.exportLog() }
            List(model.runner.events.reversed()) { event in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(event.timestamp.formatted()) • \(event.previous.rawValue) → \(event.stage.rawValue)").font(.caption)
                    Text(event.message)
                    Text("Evidence: \(event.observation?.matches.description ?? "none")").font(.caption.monospaced())
                    Text("Raw scores: \(event.observation?.scores.description ?? "none")").font(.caption.monospaced())
                }.textSelection(.enabled)
            }
        }.padding()
    }
}

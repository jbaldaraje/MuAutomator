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
            VStack(spacing: 0) {
                HStack {
                    Text("MU Automator").font(.title.bold())
                    Spacer()
                    Text(model.runner.stage.rawValue)
                    Button("Emergency Stop", role: .destructive) { model.stop() }
                }.padding()
                TabView {
                    DashboardView(model: model, capture: model.capture, permissions: model.permissions)
                        .tabItem { Label("Dashboard", systemImage: "gauge") }
                    ScrollView { CalibrationView(capture: model.capture).padding() }
                        .disabled(model.locked).tabItem { Label("Calibration", systemImage: "viewfinder") }
                    WorkflowSettingsView(model: model).tabItem { Label("Workflows", systemImage: "gearshape") }
                    RouteRecordingView(model: model, recorder: model.recorder)
                        .tabItem { Label("Record route", systemImage: "record.circle") }
                    ActivityLogView(model: model).tabItem { Label("Activity", systemImage: "list.bullet") }
                }
            }.frame(minWidth: 1000, minHeight: 700)
                .onDisappear { model.stop(); model.capture.stopPreview() }
        }.defaultSize(width: 1100, height: 800)
    }
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
                        Text(model.configuration.mode == .jewelsOnly
                             ? "Bank jewels already in inventory, verify the transfer, close panels, then stop."
                             : "Bank, activate enabled helper, monitor farming, and run enabled skills and recovery.")
                        Toggle("Dry run (use Detect only in Calibration)", isOn: $model.configuration.dryRun)
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
                        Button(model.reviewed ? "Reconfirm dry-run detection reviewed" : "Confirm I reviewed dry-run detection") { model.reviewDetection() }
                            .disabled(model.locked)
                        HStack {
                            Button("Start in 5 seconds") { model.arm() }.disabled(model.locked)
                            Button(model.runner.stage == .paused ? "Resume" : "Pause") { model.pauseOrResume() }
                                .disabled(!model.runner.active || model.arming)
                            Button("Save settings") { model.save() }.disabled(model.locked)
                        }
                        Text("After Start/Resume, focus the game. Pause/resume: Control–Option–Command–P. Emergency Stop: Control–Option–Command–Escape. Delivered input cannot be retracted.")
                            .font(.caption)
                        Text("Last event: \(model.runner.events.last?.message ?? "none")").textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                Text("macOS adapters and actual gameplay still require local acceptance testing. Calibrate verification evidence using real before/after examples; a static bank title is not transfer success.")
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
                }.textSelection(.enabled)
            }
        }.padding()
    }
}

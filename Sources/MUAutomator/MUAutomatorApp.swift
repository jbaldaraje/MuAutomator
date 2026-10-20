import SwiftUI
import AppKit
import SceneKit
import ApplicationServices
import AutomationCore

@main
@MainActor
struct MUAutomatorApp: App {
    @StateObject private var model = SessionModel()
    @NSApplicationDelegateAdaptor(BackgroundAppDelegate.self) private var delegate
    init() { NSApplication.shared.setActivationPolicy(.regular) }
    var body: some Scene {
        Window("MU Automator", id: "main") {
            AppShellView(model: model)
        }.defaultSize(width: 1280, height: 820)
        MenuBarExtra("MU Automator", systemImage: "shield.lefthalf.filled") {
            MenuBarControls(model: model)
        }
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit MU Automator") {
                    model.stop()
                    model.capture.stopPreview()
                    NSApplication.shared.terminate(nil)
                }.keyboardShortcut("q")
            }
        }
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
                Label(model.statusTitle, systemImage: model.statusSymbol)
                    .font(.callout.monospaced())
                Button { BackgroundAppDelegate.hideMainWindow() } label: {
                    Label("Minimize to menu bar", systemImage: "menubar.arrow.up.rectangle")
                }.help("Keep automation running and hide this window")
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
            HStack(spacing: 0) {
                selectedScreen
                    .id(selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                KnightCompanionView(model: model)
                    .frame(width: 240)
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
        .background(.ultraThinMaterial)
        .background(WindowAppearance().frame(width: 0, height: 0))
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
                GroupBox("Bank balance") {
                    VStack(alignment: .leading, spacing: 10) {
                        if !capture.profile.namedBankBalances.isEmpty {
                            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                                GridRow {
                                    Text("Jewel"); Text("Balance"); Text("Added"); Text("Read at")
                                }.font(.caption).foregroundStyle(.secondary)
                                ForEach(capture.profile.namedBankBalances) { target in
                                    GridRow {
                                        Text(target.name).fontWeight(.semibold)
                                        if let value = model.runner.namedBankBalanceReadings[target.id] {
                                            Text(value.reading.balance.formatted()).monospacedDigit()
                                            Text(value.reading.added.map { "+" + $0.formatted() } ?? "Not confirmed").monospacedDigit()
                                            VStack(alignment: .leading) {
                                                Text(value.reading.timestamp.formatted(date: .abbreviated, time: .standard))
                                                if !model.runner.updatedBankBalanceIDs.contains(target.id) {
                                                    Text("Previous reading").foregroundStyle(.orange)
                                                }
                                                if let issue = model.runner.namedBankBalanceIssues[target.id] {
                                                    Text("Last confirmed reading retained. \(issue)")
                                                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                                                }
                                            }.font(.caption)
                                        } else {
                                            Text("—"); Text("Not confirmed")
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("No reading yet")
                                                if let issue = model.runner.namedBankBalanceIssues[target.id] {
                                                    Text(issue).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                                                }
                                            }.font(.caption)
                                        }
                                    }
                                }
                            }
                        } else if let reading = model.runner.bankBalanceReading {
                            HStack(spacing: 32) {
                                VStack(alignment: .leading) {
                                    Text("Last confirmed balance").font(.caption).foregroundStyle(.secondary)
                                    Text(reading.balance.formatted()).font(.largeTitle.monospacedDigit())
                                }
                                VStack(alignment: .leading) {
                                    Text("Added in that collection").font(.caption).foregroundStyle(.secondary)
                                    Text(reading.added.map { "+" + $0.formatted() } ?? "Not confirmed")
                                        .font(.title2.monospacedDigit())
                                }
                            }
                            Text("Read at \(reading.timestamp.formatted(date: .abbreviated, time: .standard))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("No confirmed balance yet").font(.headline)
                        }
                        Text(model.runner.bankBalanceStatus).font(.caption).textSelection(.enabled)
                        Text("In Calibration, label bankTitle and add a named number region for each jewel under Named jewel balances. Recorded workflows need a pause with the bank visible before and after the deposit. Readings are retained for this app session.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox("Automation mode") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Mode", selection: $model.configuration.mode) {
                            ForEach(AutomationMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                        Text(model.settings.bankingInputMode == .recordedInput
                             ? "Replay your recorded clicks, key holds and timing using the repeat limit below. Jewel transfer is not verified by playback alone. OCR recovery remains available in full automation."
                             : model.configuration.mode == .jewelsOnly
                             ? "Bank jewels already in inventory, verify the transfer, close panels, then stop."
                             : "Bank, activate enabled helper, monitor farming, and run enabled skills and recovery.")
                        if model.settings.bankingInputMode == .recordedInput {
                            MacroRepeatEditor(repetition: $model.settings.macroRepeat)
                            if model.configuration.mode == .fullAutomation {
                                Text("Full automation continues its other enabled modules after macro repeats finish. Jewels only stops after the macro.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        AutoRefocusEditor(settings: $model.settings.autoRefocus)
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
                        if model.runner.isWaitingForFocus {
                            Text("Playback and timers are paused. Return to the selected game window to continue automatically. No new clicks or key presses are sent while you use another window.")
                                .font(.callout).foregroundStyle(.blue)
                        }
                        if model.settings.autoRefocus.enabled {
                            Text("Auto refocus and resume: after \(model.settings.autoRefocus.delaySeconds / 60, specifier: "%.1f") minutes paused, unfocused, or without an automation input.")
                                .font(.caption)
                        }
                        if model.settings.bankingInputMode == .recordedInput {
                            Text("Completed macro runs: \(model.runner.macroRunsCompleted)")
                        }
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
                        Text("Focus loss waits automatically; return to the selected game to continue. Manual Pause requires Resume unless Auto refocus and resume is enabled. Pause/resume: Control–Option–Command–P. Emergency Stop: Control–Option–Command–Escape.")
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

// The app owns the session. Hiding its window must never cancel the runner.
@MainActor
final class BackgroundAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.showMainWindow()
        return true
    }

    static weak var mainWindow: NSWindow?

    static func hideMainWindow() {
        mainWindow?.orderOut(nil)
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    static func showMainWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        mainWindow?.deminiaturize(nil)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class BackgroundWindowView: NSView, NSWindowDelegate {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        BackgroundAppDelegate.mainWindow = window
        window.delegate = self
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        BackgroundAppDelegate.hideMainWindow()
        return false
    }
}

@MainActor
private struct WindowAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> BackgroundWindowView { BackgroundWindowView() }
    func updateNSView(_ nsView: BackgroundWindowView, context: Context) {}
}

@MainActor
private extension SessionModel {
    var statusTitle: String {
        if arming { return "Starting in 5 seconds…" }
        if recorder.active { return "Recording inputs" }
        if runner.isWaitingForFocus { return "Waiting for game focus" }
        return runner.stage.rawValue
    }

    var statusSymbol: String {
        if runner.lastError != nil || error != nil { return "exclamationmark.triangle.fill" }
        if runner.stage == .paused || runner.isWaitingForFocus { return "pause.circle.fill" }
        return runner.active || arming || recorder.active ? "waveform.path" : "shield.checkered"
    }

    var statusColor: Color {
        if runner.lastError != nil || error != nil { return .orange }
        if runner.stage == .paused || runner.isWaitingForFocus { return .yellow }
        return runner.active || arming || recorder.active ? .cyan : .mint
    }

    var statusMessage: String {
        if let error = runner.lastError ?? error { return error }
        if arming { return "Get ready! Focus your selected game window." }
        if recorder.active { return "I'm watching your inputs. Stop recording with Control–Option–Command–R." }
        if runner.isWaitingForFocus { return "Return to your selected game window. I'll wait here." }
        if runner.stage == .paused { return "Taking a break. Resume when you're ready." }
        return runner.events.last?.message ?? "Ready when you are! Select your game window and review your setup."
    }
}

@MainActor
private struct MenuBarControls: View {
    @ObservedObject var model: SessionModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label(model.statusTitle, systemImage: model.statusSymbol)
        Text("Completed macro runs: \(model.runner.macroRunsCompleted)")
        if let error = model.runner.lastError { Text(error) }
        Divider()
        Button("Show MU Automator") {
            openWindow(id: "main")
            BackgroundAppDelegate.showMainWindow()
        }
        Button(model.runner.stage == .paused ? "Resume in 5 seconds" : "Pause") {
            model.pauseOrResume()
        }.disabled(!model.runner.active || model.arming)
        Button("Emergency Stop", role: .destructive) { model.stop() }
        Divider()
        Button("Quit MU Automator") {
            model.stop()
            model.capture.stopPreview()
            NSApplication.shared.terminate(nil)
        }
    }
}

@MainActor
private struct KnightCompanionView: View {
    @ObservedObject var model: SessionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scene = KnightScene.make()

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 6) {
                Circle().fill(model.statusColor).frame(width: 7, height: 7)
                Text("KNIGHT COMPANION").font(.caption2.weight(.semibold)).tracking(2)
            }
            VStack(alignment: .leading, spacing: 10) {
                Label(model.statusTitle, systemImage: model.statusSymbol)
                    .font(.headline).foregroundStyle(model.statusColor)
                Text(model.statusMessage).font(.callout).textSelection(.enabled)
                if model.runner.active && model.runner.stage != .paused && !model.runner.isWaitingForFocus {
                    ProgressView().controlSize(.small).accessibilityLabel("Automation in progress")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(model.statusColor.opacity(0.35)))
            .overlay(alignment: .bottom) {
                Image(systemName: "arrowtriangle.down.fill")
                    .foregroundStyle(model.statusColor.opacity(0.5)).offset(y: 12)
            }
            KnightSceneView(scene: scene, animated: !reduceMotion)
                .frame(height: 260)
                .accessibilityLabel("Cute armored knight with a glowing visor and sword")
            Text("Blade Knight–inspired").font(.headline)
            Text("Original 3D companion • not official MU artwork")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Divider()
            Label("\(model.runner.macroRunsCompleted) macro runs completed", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
            Text("Close the window to keep running in the menu bar. Quit ends the session.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(LinearGradient(colors: [.cyan.opacity(0.09), .indigo.opacity(0.12), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

@MainActor
private struct KnightSceneView: NSViewRepresentable {
    let scene: SCNScene
    let animated: Bool
    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.backgroundColor = .clear
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: SCNView, context: Context) {
        view.isPlaying = animated
        scene.isPaused = !animated
    }
}

// Real, locally rendered geometry: no network, downloads, or image masquerading as 3D.
@MainActor
private enum KnightScene {
    static func make() -> SCNScene {
        let scene = SCNScene()
        let knight = SCNNode()
        scene.rootNode.addChildNode(knight)
        let steel = NSColor(calibratedRed: 0.22, green: 0.27, blue: 0.40, alpha: 1)
        let silver = NSColor(calibratedRed: 0.65, green: 0.76, blue: 0.88, alpha: 1)
        let glow = NSColor.cyan
        func part(_ geometry: SCNGeometry, _ color: NSColor, _ position: SCNVector3, luminous: Bool = false) -> SCNNode {
            let material = SCNMaterial()
            material.diffuse.contents = color
            material.metalness.contents = luminous ? 0.2 : 0.75
            material.roughness.contents = 0.28
            if luminous { material.emission.contents = color }
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry)
            node.position = position
            knight.addChildNode(node)
            return node
        }
        func box(_ w: CGFloat, _ h: CGFloat, _ d: CGFloat, _ color: NSColor, _ x: Float, _ y: Float, _ z: Float, luminous: Bool = false) {
            _ = part(SCNBox(width: w, height: h, length: d, chamferRadius: min(w, min(h, d)) * 0.22), color, SCNVector3(x, y, z), luminous: luminous)
        }
        box(0.88, 0.78, 0.54, steel, 0, 0, 0)
        box(1.12, 0.92, 0.80, silver, 0, 0.83, 0)
        box(0.92, 0.25, 0.10, steel, 0, 0.86, 0.43)
        box(0.25, 0.08, 0.08, glow, -0.23, 0.88, 0.50, luminous: true)
        box(0.25, 0.08, 0.08, glow, 0.23, 0.88, 0.50, luminous: true)
        box(0.12, 0.72, 0.12, steel, 0, 0.90, 0.47)
        for x: Float in [-0.64, 0.64] {
            _ = part(SCNSphere(radius: 0.29), silver, SCNVector3(x, 0.20, 0))
            box(0.26, 0.52, 0.30, steel, x, -0.18, 0)
            let horn = part(SCNCone(topRadius: 0, bottomRadius: 0.15, height: 0.56), steel, SCNVector3(x * 0.72, 1.42, 0))
            horn.eulerAngles.z = x > 0 ? -0.4 : 0.4
        }
        for x: Float in [-0.25, 0.25] { box(0.36, 0.40, 0.49, silver, x, -0.60, 0.10) }
        let gem = part(SCNSphere(radius: 0.13), glow, SCNVector3(0, 0.12, 0.31), luminous: true)
        gem.scale = SCNVector3(0.8, 1.3, 0.5)
        box(0.12, 1.12, 0.08, silver, 0.90, 0.0, 0.23)
        box(0.45, 0.10, 0.14, glow, 0.90, -0.32, 0.23, luminous: true)
        box(0.09, 0.27, 0.10, steel, 0.90, -0.50, 0.23)
        knight.eulerAngles = SCNVector3(-0.08, -0.28, 0)
        let rise = SCNAction.moveBy(x: 0, y: 0.09, z: 0, duration: 1.6)
        let fall = rise.reversed()
        rise.timingMode = .easeInEaseOut
        fall.timingMode = .easeInEaseOut
        knight.runAction(.repeatForever(.sequence([rise, fall])))
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 1.65
        camera.position = SCNVector3(0, 0.40, 6)
        scene.rootNode.addChildNode(camera)
        return scene
    }
}

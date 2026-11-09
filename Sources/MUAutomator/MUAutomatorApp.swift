import SwiftUI
import AppKit
import AutomationCore

@main
@MainActor
struct MUAutomatorApp: App {
    @StateObject private var model = ScreenMacroModel()
    @NSApplicationDelegateAdaptor(MacroAppDelegate.self) private var delegate
    init() { NSApplication.shared.setActivationPolicy(.regular) }
    var body: some Scene {
        Window("MU Automator", id: "main") {
            ScreenMacroView(model: model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 560, height: 610)
        MenuBarExtra {
            MacroStatusMenu(model: model)
        } label: {
            MacroStatusLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
private struct ScreenMacroView: View {
    @ObservedObject var model: ScreenMacroModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "cursorarrow.motionlines").font(.system(size: 30)).foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Screen Macro").font(.title.bold())
                        Text("Mouse & keyboard recording for your whole desktop").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { MacroAppDelegate.hide() } label: {
                        Label("Hide", systemImage: "menubar.arrow.up.rectangle")
                    }.help("Hide to menu bar; keep recording or playback running")
                }
                HStack {
                    Label(model.recording.map { "\($0.events.count.formatted()) events · \(macroDuration($0.duration))" } ?? "No recording yet",
                          systemImage: "waveform.path")
                        .font(.callout.monospacedDigit())
                    Spacer()
                    Button("Open…") { model.openMacro() }.disabled(model.busy)
                    Button("Save…") { model.exportMacro() }.disabled(model.busy || model.recording == nil)
                }
                HStack {
                    Text("Run for")
                    TextField("Hours", value: $model.hours, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 100)
                        .disabled(model.busy).onSubmit { model.savePlaybackSettings() }
                    Text("hours").foregroundStyle(.secondary)
                    Spacer()
                }
                HStack {
                    Text("Repeat interval")
                    TextField("Seconds", value: $model.intervalSeconds, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 100)
                        .disabled(model.busy).onSubmit { model.savePlaybackSettings() }
                    Text("seconds").foregroundStyle(.secondary)
                    Spacer()
                }
                Text("The interval is a pause after each full replay. 0 repeats immediately; 60 waits one minute. Waiting counts toward your run hours.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Decimal hours work too: 0.5 = 30 minutes. The current replay finishes when the timer ends.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button(model.recordingActive ? "Finish recording" : "Record in 5 seconds") {
                        if model.recordingActive { model.finishRecording() } else { model.startRecording() }
                    }.buttonStyle(.borderedProminent).disabled(model.player.active)
                    Button("Play in 5 seconds") { model.play() }
                        .disabled(model.busy || model.recording == nil)
                    Button("Stop", role: .destructive) { model.stop() }.disabled(!model.busy)
                }.controlSize(.large)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        if model.recordingActive {
                            Label(model.recordCountdown ? "Get ready to record…" : "Recording your desktop…", systemImage: "record.circle.fill")
                                .foregroundStyle(.red)
                            if !model.recordCountdown { Text("\(model.capturedEvents.formatted()) events captured").font(.caption.monospacedDigit()) }
                        } else if model.player.phase == .countdown && model.player.active {
                            Text("Playback begins in \(model.player.countdownRemaining)…").font(.headline)
                        } else if model.player.active {
                            Text("\(model.player.completedCycles.formatted()) replays · \(macroDuration(model.player.remaining)) remaining")
                                .font(.headline.monospacedDigit())
                            if model.player.phase == .waiting {
                                Text("Next replay in \(macroDuration(model.player.intervalRemaining))")
                                    .font(.callout.monospacedDigit()).foregroundStyle(.orange)
                            }
                        }
                        Text(model.message).font(.callout).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                Text("Finish recording: Control–Option–Command–R\nStop immediately: Control–Option–Command–Escape")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Moving your mouse won’t stop playback. Playback uses your Mac’s shared pointer and keyboard. Closing this window keeps it running in the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(model.accessibilityAllowed ? "Input permissions…" : "Enable Accessibility / Input Monitoring") {
                    model.requestPermissions()
                }
            }.padding(26)
        }
        .frame(minWidth: 500, minHeight: 410)
        .background(.ultraThinMaterial)
        .background(MacroWindowAppearance().frame(width: 0, height: 0))
        .task { await model.refreshPermissions() }
        .onChange(of: model.hours) { _, value in
            if (try? ScreenMacroSettings(hours: value, intervalSeconds: model.intervalSeconds).validate()) != nil { model.savePlaybackSettings() }
        }
        .onChange(of: model.intervalSeconds) { _, value in
            if (try? ScreenMacroSettings(hours: model.hours, intervalSeconds: value).validate()) != nil { model.savePlaybackSettings() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshPermissions() }
        }
    }
}

@MainActor
final class MacroAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: ScreenMacroModel?
    static weak var mainWindow: NSWindow?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { Self.show(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        model.shutDown()
        Task { @MainActor in
            while model.player.active { try? await Task.sleep(nanoseconds: 20_000_000) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    static func hide() {
        mainWindow?.orderOut(nil)
        NSApplication.shared.setActivationPolicy(.accessory)
    }
    static func show() {
        NSApplication.shared.setActivationPolicy(.regular)
        mainWindow?.deminiaturize(nil); mainWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class MacroWindowHost: NSView, NSWindowDelegate {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        MacroAppDelegate.mainWindow = window
        window.delegate = self; window.isReleasedWhenClosed = false
        window.isOpaque = false; window.backgroundColor = .clear; window.titlebarAppearsTransparent = true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MacroAppDelegate.hide()
        return false
    }
}

@MainActor
private struct MacroWindowAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> MacroWindowHost { MacroWindowHost() }
    func updateNSView(_ view: MacroWindowHost, context: Context) {}
}


private func macroDuration(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "—" }
    let total = max(0, Int(ceil(seconds)))
    return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
}

@MainActor
private extension ScreenMacroModel {
    var barText: String {
        if recordingActive { return recordCountdown ? "READY" : "REC" }
        switch player.phase {
        case .countdown: return "START"
        case .playing: return "PLAY"
        case .waiting: return "WAIT"
        case .completed: return "DONE"
        case .stopped: return "STOP"
        case .failed: return "ERROR"
        case .idle: return ""
        }
    }
    var barSymbol: String {
        if recordingActive { return recordCountdown ? "timer" : "record.circle.fill" }
        switch player.phase {
        case .countdown: return "timer"
        case .playing: return "play.fill"
        case .waiting: return "hourglass"
        case .completed: return "checkmark.circle.fill"
        case .stopped: return "stop.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle: return "cursorarrow.motionlines"
        }
    }
    var barColor: Color {
        if recordingActive { return recordCountdown ? .orange : .red }
        switch player.phase {
        case .playing, .completed: return .green
        case .waiting, .countdown: return .orange
        case .failed: return .red
        default: return .primary
        }
    }
}

@MainActor
private struct MacroStatusLabel: View {
    @ObservedObject var model: ScreenMacroModel
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.barSymbol).symbolRenderingMode(.palette).foregroundStyle(model.barColor)
            if !model.barText.isEmpty { Text(model.barText).font(.caption.weight(.semibold)) }
        }
        .accessibilityLabel("MU Automator: \(model.barText.isEmpty ? "Ready" : model.barText)")
        .help("MU Automator: \(model.barText.isEmpty ? "Ready" : model.barText)")
    }
}

@MainActor
private struct MacroStatusMenu: View {
    @ObservedObject var model: ScreenMacroModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    Label(model.recordingActive ? (model.recordCountdown ? "Recording starts shortly" : "Recording desktop")
                          : model.player.phase.rawValue.capitalized, systemImage: model.barSymbol)
                        .font(.headline).foregroundStyle(model.barColor)
                    if model.player.active {
                        Text("\(model.player.completedCycles.formatted()) complete replays").monospacedDigit()
                        Text("Time remaining: \(macroDuration(model.player.remaining))").monospacedDigit()
                        if model.player.phase == .waiting {
                            Text("Next replay in \(macroDuration(model.player.intervalRemaining))").monospacedDigit()
                        } else if model.player.phase == .countdown {
                            Text("Starts in \(model.player.countdownRemaining) seconds").monospacedDigit()
                        }
                    }
                    if let error = model.player.error { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            Divider()
            HStack {
                Button("Show recorder") { MacroAppDelegate.show(); dismiss() }
                Button("Hide recorder") { MacroAppDelegate.hide(); dismiss() }
            }
            if model.recordingActive {
                Button("Finish recording") { model.finishRecording(); dismiss() }
            } else {
                Button("Record in 5 seconds") { model.startRecording(); dismiss() }.disabled(model.busy)
                Button("Play for \(model.hours.formatted()) hours") { model.play(); dismiss() }
                    .disabled(model.busy || model.recording == nil)
            }
            Button("Stop", role: .destructive) { model.stop() }.disabled(!model.busy)
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.bordered)
        .padding(16).frame(width: 310, alignment: .leading)
    }
}

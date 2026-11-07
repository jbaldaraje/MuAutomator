import SwiftUI
import ScreenCaptureKit
import AutomationCore

@MainActor
struct WindowQueueView: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var capture: CaptureModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Window macros").font(.title2.bold())
                Text("Record each game window separately. The queue focuses one assigned window, finishes one complete macro, then gives the next window a turn. It never sends input to two windows at once.")
                GroupBox("Save the current setup") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("In Calibration select a window and its jewel regions. Record inputs → Jewel workflow captures that window’s macro. Set its repeat limit in Workflows, then save it here. Load a profile to edit it later; save your current workspace before switching.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Window macro name", text: $model.windowProfileName).disabled(model.locked)
                        Text("Workspace window: \(capture.selectedID.map { String($0) } ?? "none selected")")
                            .font(.caption.monospaced())
                        Button("Save current setup as new window macro") { model.saveWindowProfile() }
                            .disabled(model.locked || capture.busy)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox("Queue controls") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("I allow live input and automatic switching between the assigned game windows", isOn: $model.queueInputConsent)
                            .disabled(model.locked)
                        Text("Only recorded jewel macros run here. Full automation remains on Dashboard. Set every game to its recording’s starting state and original browser size. Window assignments must be selected again after restarting the app.")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.windowQueue.lastError != nil {
                            Toggle("I inspected the stopped queue and resolved the failed macro", isOn: $model.queueFailureReviewed)
                                .disabled(model.locked)
                        }
                        HStack {
                            Button("Start included windows in 5 seconds") { model.startWindowQueue() }
                                .disabled(model.locked || capture.busy || model.includedQueueProfiles.isEmpty)
                            Button(model.windowQueue.paused ? "Resume in 5 seconds" : "Pause queue") {
                                if model.windowQueue.paused { model.resumeWindowQueue() } else { model.windowQueue.pause() }
                            }.disabled(!model.windowQueue.active || model.arming)
                            Button("Emergency Stop all", role: .destructive) { model.stop() }
                        }
                        Text(model.queuePreparing ? "Preparing assigned windows…" : "Queue: \(model.windowQueue.phase.rawValue)")
                            .font(.callout.monospaced())
                        if let current = model.windowQueue.current {
                            Text("Active window macro: \(current.entry.profile.name) • \(current.status)")
                        }
                        if let error = model.windowQueue.lastError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                        if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                        Button("Refresh available game windows") { Task { await capture.refresh(requestPermission: true) } }
                            .disabled(model.locked || capture.busy)
                        Button("Export all activity") { model.exportLog() }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                if model.windowProfiles.isEmpty {
                    Text("No window macros saved yet. Your existing single-window settings and recordings are unchanged.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.windowProfiles) { profile in
                    WindowMacroRow(model: model, capture: capture, profile: profile)
                }
            }.padding(24)
        }
    }
}

@MainActor
private struct WindowMacroRow: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var capture: CaptureModel
    let profile: WindowMacroProfile
    private var runtime: WindowMacroRuntime? { model.windowRuntime(profile.id) }
    private var queued: Bool { model.windowQueue.active && model.windowQueue.items.contains { $0.id == profile.id } }
    var body: some View {
        GroupBox(profile.name) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Include in queue", isOn: Binding(get: {
                    model.includedQueueProfiles.contains(profile.id)
                }, set: { included in
                    if included { model.includedQueueProfiles.insert(profile.id) }
                    else { model.includedQueueProfiles.remove(profile.id) }
                })).disabled(model.locked)
                Picker("Assigned game window", selection: Binding(get: {
                    model.queueWindowAssignments[profile.id]
                }, set: { model.assignQueueWindow(profile.id, windowID: $0) })) {
                    Text("Select window").tag(Optional<CGWindowID>.none)
                    ForEach(capture.windows, id: \.windowID) { window in
                        Text("\(window.owningApplication?.applicationName ?? "Browser"): \(window.title ?? "open.mu") [\(window.windowID)]")
                            .tag(Optional(window.windowID))
                    }
                }.disabled(model.locked || capture.busy)
                Text("\(profile.settings.bankingRecording?.steps.count ?? 0) inputs • \(profile.settings.macroRepeat.summary) • \(profile.settings.macroRepeat.delayBetweenRunsSeconds, specifier: "%.1f")s between turns")
                    .font(.caption)
                if profile.configuration.dryRun { Text("Dry run is on. Load, disable Dry run on Dashboard, then update this profile before starting.").font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button("Load for editing") { model.loadWindowProfile(profile.id) }.disabled(model.locked || capture.busy)
                    Button("Update from workspace") { model.saveWindowProfile(replacing: profile.id) }
                        .disabled(model.locked || capture.busy || model.editingWindowProfileID != profile.id)
                    Button("Start only this window") { model.startWindowQueue(only: profile.id) }.disabled(model.locked || capture.busy)
                    Button("Remove", role: .destructive) { model.removeWindowProfile(profile.id) }.disabled(model.locked)
                }
                if let runtime {
                    Text("\(runtime.status) • completed macro runs: \(runtime.completedRuns)")
                        .font(.callout.monospaced()).textSelection(.enabled)
                    if queued && !runtime.finished && !runtime.stopped {
                        HStack {
                            Button(runtime.paused ? "Resume window in 5 seconds" : "Pause window") {
                                if runtime.paused { model.resumeWindowQueue(entryID: profile.id) }
                                else { model.windowQueue.pauseEntry(profile.id) }
                            }.disabled(model.arming)
                            Button("Stop this window", role: .destructive) { model.windowQueue.stopEntry(profile.id) }
                        }
                        Text("Pausing an active macro holds its place until resumed or stopped. Pausing a waiting window lets the other windows continue.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Balances and activity for this window") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(runtime.entry.profile.calibration.namedBankBalances) { target in
                                if let value = runtime.runner.namedBankBalanceReadings[target.id] {
                                    Text("\(target.name): \(value.reading.balance.formatted()) • added \(value.reading.added.map { "+" + $0.formatted() } ?? "not confirmed") • \(value.reading.timestamp.formatted())")
                                        .font(.caption.monospaced())
                                } else { Text("\(target.name): no confirmed reading yet").font(.caption) }
                                if let issue = runtime.runner.namedBankBalanceIssues[target.id] { Text(issue).font(.caption).foregroundStyle(.orange) }
                            }
                            Text(runtime.runner.bankBalanceStatus).font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(runtime.runner.events.suffix(12))) { event in
                                Text("\(event.timestamp.formatted(date: .omitted, time: .standard)) • \(event.message)")
                                    .font(.caption).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}

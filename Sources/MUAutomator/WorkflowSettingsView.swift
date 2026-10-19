import SwiftUI
import AutomationCore

@MainActor
struct WorkflowSettingsView: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Jewel banking & inventory monitoring") {
                    VStack(alignment: .leading) {
                        Toggle("Enable jewel banking", isOn: $model.settings.bankingEnabled)
                        Picker("Input method", selection: $model.settings.bankingInputMode) {
                            ForEach(BankingInputMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        if model.settings.bankingInputMode == .recordedInput {
                            Text("Use Record inputs → Jewel workflow to capture your clicks, key holds and pauses. Playback does not require inventory/bank labels. Finishing the inputs does not verify a deposit.")
                                .font(.caption)
                            MacroRepeatEditor(repetition: $model.settings.macroRepeat)
                            RecordedInputEditor(recording: $model.settings.bankingRecording)
                        } else {
                            Picker("Transfer verification", selection: $model.settings.bankingVerification) {
                                ForEach(BankingVerificationMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            Text("Use a new success indicator or a calibrated reliable count change. Numeric regions must contain only one count in the selected format. Processing, unchanged counts and dialog closure are not success. Uncertain transfers are never clicked again automatically.")
                                .font(.caption)
                        }
                        Picker("Numeric format", selection: $model.settings.countFormat) {
                            ForEach(CountFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Text("Set up each jewel under Calibration → Named jewel balances, with bankTitle marked. Named rows use their own number formats; Numeric format above is for legacy bankBalanceText and transfer verification. Keep the bank visible for two OCR reads before and after depositing.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Monitor calibrated banking-trigger indicator (full mode)", isOn: $model.settings.inventoryMonitoringEnabled)
                        numeric("Minimum time between banking attempts (seconds)", value: $model.settings.bankingCooldownSeconds)
                        Text("The optional bankingTrigger label can start another banking cycle in full mode. Turn the monitor off while testing the recording.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("MU Helper & death recovery — full mode") {
                    VStack(alignment: .leading) {
                        Toggle("Enable MU Helper", isOn: $model.configuration.helperEnabled)
                        Toggle("Enable death recovery", isOn: $model.configuration.recoveryEnabled)
                        numeric("Respawn timeout (seconds)", value: $model.settings.recoveryTimeoutSeconds)
                        numeric("Route timeout (seconds)", value: $model.settings.routeTimeoutSeconds)
                        Stepper("Maximum recoveries: \(model.settings.maximumRecoveries)", value: $model.settings.maximumRecoveries, in: 1...10)
                        Text("Death requires independent indicators across fresh frames. The destination and helper state must be verified before farming resumes.")
                            .font(.caption)
                    }.padding(8)
                }
                GroupBox("Action limits") {
                    VStack {
                        numeric("Action verification timeout (seconds)", value: $model.settings.actionTimeoutSeconds)
                        numeric("Maximum session duration (seconds)", value: $model.settings.workflowTimeoutSeconds)
                        if model.settings.bankingInputMode == .recordedInput && model.settings.macroRepeat.mode != .once {
                            Text("The macro uses its repeat count or hours. This session limit applies to the other workflow phases.").font(.caption)
                        }
                        numeric("Capture polling interval (seconds)", value: $model.settings.pollSeconds)
                    }.padding(8)
                }
                AutoRefocusEditor(settings: $model.settings.autoRefocus)
                SkillEditor(configuration: $model.configuration, settings: $model.settings)
                RouteEditor(route: $model.settings.route)
                Button("Test route replay in 5 seconds (movement only)") { model.arm(routeTest: true) }
                    .disabled(model.configuration.mode != .fullAutomation)
                Button("Save settings") { model.save() }
            }.padding(24)
        }.disabled(model.locked)
    }

    private func numeric(_ title: String, value: Binding<Double>) -> some View {
        HStack { Text(title); Spacer(); TextField(title, value: value, format: .number).frame(width: 100) }
    }
}

struct AutoRefocusEditor: View {
    @Binding var settings: AutoRefocusSettings
    var body: some View {
        GroupBox("Window focus") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Auto refocus and resume", isOn: $settings.enabled)
                if settings.enabled {
                    HStack {
                        Button("30 minutes") { settings.delaySeconds = 1800 }
                        Button("1 hour") { settings.delaySeconds = 3600 }
                        Text("After (minutes)")
                        TextField("Minutes before refocusing", value: Binding(
                            get: { settings.delaySeconds / 60 },
                            set: { settings.delaySeconds = $0 * 60 }), format: .number)
                            .frame(width: 100)
                    }
                    Text("After this much time paused, unfocused, or without an automation input, bring your selected game window forward and continue. Manual Pause can resume automatically. Stopped or completed sessions stay stopped.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Switch windows freely. Playback waits for your selected game to regain focus; Manual Pause requires Resume.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(6)
        }
    }
}

struct MacroRepeatEditor: View {
    @Binding var repetition: MacroRepeatSettings
    var body: some View {
        GroupBox("Macro repeats") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Repeat", selection: $repetition.mode) {
                    ForEach(MacroRepeatMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                if repetition.mode == .count {
                    HStack {
                        Text("Total runs")
                        TextField("Total runs", value: $repetition.count, format: .number).frame(width: 110)
                    }
                }
                if repetition.mode == .duration {
                    HStack {
                        Text("Hours")
                        TextField("Hours", value: Binding(get: { repetition.durationSeconds / 3600 },
                                                         set: { repetition.durationSeconds = $0 * 3600 }), format: .number)
                            .frame(width: 110)
                    }
                }
                if repetition.mode != .once {
                    HStack {
                        Text("Delay between runs (seconds)")
                        TextField("Delay between runs", value: $repetition.delayBetweenRunsSeconds, format: .number)
                            .frame(width: 110)
                    }
                    Text("Repeats the entire recording. Count includes the first run. Hours exclude paused time; the current cycle finishes when time expires. Record a sequence that ends ready to start again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(repetition.summary).font(.caption)
            }.padding(6)
        }
    }
}

struct SkillEditor: View {
    @Binding var configuration: AutomationConfiguration
    @Binding var settings: WorkflowSettings
    var body: some View {
        GroupBox("Skill sequence — full mode") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable skill sequence", isOn: $configuration.skillsEnabled)
                Toggle("Repeat sequence within session limit", isOn: $settings.repeatSkills)
                Text("Enter macOS virtual key codes only after verifying each shortcut in the actual game. Rows execute in order; cooldowns may skip a row.").font(.caption)
                ForEach($settings.skills) { $skill in
                    HStack {
                        TextField("Key code", value: $skill.keyCode, format: .number).frame(width: 80)
                        Text("Delay")
                        TextField("Delay seconds", value: $skill.delaySeconds, format: .number).frame(width: 70)
                        Text("Cooldown")
                        TextField("Cooldown seconds", value: $skill.cooldownSeconds, format: .number).frame(width: 70)
                        Picker("Evidence", selection: $skill.verification) {
                            Text("No visual verification").tag(Optional<TargetRole>.none)
                            ForEach(TargetRole.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                        }
                        Button("Remove") { settings.skills.removeAll { $0.id == skill.id } }
                        Button("↑") { moveSkill(skill.id, offset: -1) }
                        Button("↓") { moveSkill(skill.id, offset: 1) }
                    }
                }
                Button("Add skill") { settings.skills.append(.init()) }
            }.padding(8)
        }
    }

    private func moveSkill(_ id: UUID, offset: Int) {
        guard let index = settings.skills.firstIndex(where: { $0.id == id }), settings.skills.indices.contains(index + offset) else { return }
        settings.skills.swapAt(index, index + offset)
    }
}

struct RouteEditor: View {
    @Binding var route: RecoveryRoute
    var body: some View {
        GroupBox("Return-to-spot route") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Route name", text: $route.name)
                if route.recording != nil {
                    Text("Replay your recorded return inputs and timing after OCR confirms spawn. Verify destinationLandmark at the end; individual input steps need no image checkpoints.")
                        .font(.caption)
                    RecordedInputEditor(recording: $route.recording)
                } else {
                    Text("Configure checkpoint-gated clicks or captured points. No map, key, teleport or path is assumed. Each step must produce its expected visual checkpoint.").font(.caption)
                    ForEach($route.steps) { $step in
                        VStack(alignment: .leading) {
                            HStack {
                                Picker("Before", selection: $step.before) { targets }
                                Picker("After", selection: $step.after) { targets }
                                Button("Remove") { route.steps.removeAll { $0.id == step.id }; route.validated = false }
                                Button("↑") { moveStep(step.id, offset: -1) }
                                Button("↓") { moveStep(step.id, offset: 1) }
                            }
                            Text("Action: \(String(describing: step.action))").font(.caption.monospaced())
                            if case let .key(code) = step.action {
                                TextField("Recorded key code", value: Binding(get: { code }, set: { step.action = .key($0) }), format: .number)
                            }
                            if case let .point(x, y) = step.action {
                                HStack {
                                    Text("Recorded window-relative point")
                                    TextField("X", value: Binding(get: { x }, set: { step.action = .point(x: $0, y: y) }), format: .number)
                                    TextField("Y", value: Binding(get: { y }, set: { step.action = .point(x: x, y: $0) }), format: .number)
                                }
                            }
                            Picker("Click calibrated target", selection: Binding(get: {
                                if case let .click(role) = step.action { return role }; return .routeCheckpoint
                            }, set: { step.action = .click($0); route.validated = false })) { targets }
                        }
                    }
                    Button("Add checkpoint click") {
                        route.steps.append(.init(action: .click(.routeCheckpoint), before: .respawnIndicator, after: .destinationLandmark))
                        route.validated = false
                    }
                }
                Toggle(route.recording == nil ? "I manually replayed this route and verified every checkpoint"
                       : "I tested the recording and verified arrival at the farming spot", isOn: $route.validated)
                Text("Route recording and replay validation must be performed on your Mac. This checkbox records your confirmation; it does not run a route test.")
                    .font(.caption)
            }.padding(8)
        }
        .onChange(of: route.steps) { _, _ in route.validated = false }
        .onChange(of: route.recording) { _, _ in route.validated = false }
    }
    private var targets: some View {
        ForEach(TargetRole.allCases.filter { $0 != .withdrawExcluded }, id: \.self) { Text($0.rawValue).tag($0) }
    }
    private func moveStep(_ id: UUID, offset: Int) {
        guard let index = route.steps.firstIndex(where: { $0.id == id }), route.steps.indices.contains(index + offset) else { return }
        route.steps.swapAt(index, index + offset)
    }
}

struct RecordedInputEditor: View {
    @Binding var recording: InputRecording?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let value = recording {
                Text("\(value.steps.count) recorded inputs • \(value.duration, specifier: "%.1f") seconds • window \(Int(value.windowWidth)) × \(Int(value.windowHeight)) points")
                    .font(.caption)
                ForEach(value.steps) { step in
                    HStack {
                        Text(String(describing: step.action)).font(.caption.monospaced())
                        Spacer()
                        Text("Wait")
                        TextField("Wait seconds", value: Binding(get: {
                            recording?.steps.first(where: { $0.id == step.id })?.delayBeforeSeconds ?? 0
                        }, set: { setTiming(step.id, delay: $0) }), format: .number).frame(width: 65)
                        Text("Hold")
                        TextField("Hold seconds", value: Binding(get: {
                            recording?.steps.first(where: { $0.id == step.id })?.holdSeconds ?? 0.05
                        }, set: { setTiming(step.id, hold: $0) }), format: .number).frame(width: 65)
                        Button("Remove") { recording?.steps.removeAll { $0.id == step.id } }
                    }
                }
                HStack {
                    Text("Wait after last input (seconds)")
                    TextField("Final wait", value: Binding(get: { recording?.tailDelaySeconds ?? 0 },
                                                         set: { recording?.tailDelaySeconds = $0 }), format: .number).frame(width: 70)
                    Button("Remove recording", role: .destructive) { recording = nil }
                }
            } else { Text("No saved recording. Open Record inputs to create one.").foregroundStyle(.secondary) }
        }
    }
    private func setTiming(_ id: UUID, delay: Double? = nil, hold: Double? = nil) {
        guard let index = recording?.steps.firstIndex(where: { $0.id == id }) else { return }
        if let delay { recording?.steps[index].delayBeforeSeconds = delay }
        if let hold { recording?.steps[index].holdSeconds = hold }
    }
}

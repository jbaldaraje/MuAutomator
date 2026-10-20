import SwiftUI
import ScreenCaptureKit
import AutomationCore

@MainActor
struct CalibrationView: View {
    @ObservedObject var capture: CaptureModel
    let configuration: AutomationConfiguration
    let settings: WorkflowSettings
    @State private var markingNamedBalance = false
    @State private var jewelName = ""
    @State private var jewelFormat: CountFormat = .digitsOnly
    @State private var jewelThreshold = 0.95

    var body: some View {
        GroupBox("Window capture & visual calibration") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("Profile name", text: $capture.profileName).frame(width: 160)
                    Button("Save named profile") { capture.saveNamedProfile() }
                    Menu("Load profile") {
                        ForEach(capture.namedProfiles, id: \.self) { name in
                            Button(name) { capture.profileName = name; capture.loadNamedProfile() }
                        }
                    }
                }
                HStack {
                    Button("Allow capture / Refresh windows") {
                        Task { await capture.refresh(requestPermission: true) }
                    }
                    Button("Open Screen Recording settings") { capture.openScreenRecordingSettings() }
                    Button("Allow Accessibility for URL detection") { capture.requestURLPermission() }
                    if capture.busy { ProgressView().controlSize(.small) }
                }.disabled(capture.busy)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Only windows with an active https://open.mu page are listed. Activate the game tab first, then refresh.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("open.mu window", selection: Binding(get: { capture.selectedID }, set: { capture.select($0) })) {
                        Text("Select an open.mu window").tag(Optional<CGWindowID>.none)
                        ForEach(capture.windows, id: \.windowID) { window in
                            Text("\(window.owningApplication?.applicationName ?? "App"): \(window.title ?? "Untitled") [\(window.windowID)]")
                                .tag(Optional(window.windowID))
                        }
                    }.pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Button("Capture snapshot") { Task { await capture.capture() } }
                            .disabled(capture.selectedID == nil)
                        Button(capture.previewEnabled ? "Freeze preview" : "Live preview") {
                            if capture.previewEnabled { capture.stopPreview() } else { capture.startPreview() }
                        }.disabled(capture.selectedID == nil)
                    }
                }.disabled(capture.busy)
                Text(capture.message).font(.callout).textSelection(.enabled)
                if !capture.discoveryDetails.isEmpty {
                    Text(capture.discoveryDetails).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let date = capture.capturedAt {
                    Text("Frame: \(date.formatted()) • \(capture.previewEnabled ? "preview updating" : "frozen snapshot")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                calibrationPlan
                if let image = capture.image {
                    namedBalanceEditor
                    Picker("Target label", selection: $capture.role) {
                        ForEach(CalibrationTargetGroup.allCases, id: \.self) { group in
                            Section(group.rawValue) {
                                ForEach(TargetRole.calibrationOrder.filter { $0.calibrationGuide.group == group }, id: \.self) { role in
                                    Text("\(role.rawValue) — \(role.calibrationGuide.title)")
                                        .tag(role).help(role.calibrationGuide.instruction)
                                }
                            }
                        }
                    }.pickerStyle(.menu).disabled(markingNamedBalance)
                    if !markingNamedBalance {
                        targetDescription
                        if capture.role.isNumericEvidence {
                            Text("Numeric OCR reads this region automatically; keep only one count inside it.").font(.caption)
                        } else {
                            HStack {
                                TextField("Optional OCR phrase for this target", text: $capture.expectedText)
                                Button("Use OCR only") { capture.useOCROnly() }
                                    .disabled(capture.expectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                Button("Use image only") { capture.expectedText = "" }
                                    .disabled(capture.expectedText.isEmpty || capture.profile.targets.first(where: { $0.role == capture.role })?.template == nil)
                            }
                        }
                        HStack {
                            Text("Minimum similarity \(capture.threshold, specifier: "%.2f")")
                            Slider(value: $capture.threshold, in: 0.8...1)
                        }
                    }
                    Text(markingNamedBalance
                         ? "Drawing now saves the named jewel above. Switch off Mark a named jewel balance to edit ordinary targets."
                         : "Edits update the selected target immediately. Save the profile to persist them; existing rectangles do not need redrawing.")
                        .font(.caption).foregroundStyle(.secondary)
                    RegionCanvas(image: image, targets: capture.profile.targets, selected: capture.role,
                                 namedBalances: capture.profile.namedBankBalances,
                                 selectedName: markingNamedBalance ? jewelName : nil) { region in
                        if markingNamedBalance {
                            capture.markNamedBalance(region, name: jewelName, format: jewelFormat, threshold: jewelThreshold)
                        } else { capture.mark(region) }
                    }
                        .aspectRatio(CGFloat(image.width) / CGFloat(image.height), contentMode: .fit)
                        .disabled(capture.previewEnabled)
                    if capture.previewEnabled { Text("Freeze preview before marking regions or reviewing detection.").font(.caption) }
                    Text("Drag on the snapshot. Red = excluded Withdraw region. Regions are window-relative; recheck after UI or layout changes.")
                        .font(.caption)
                }
                HStack {
                    Text("\(capture.profile.targets.count) workflow regions • \(capture.profile.namedBankBalances.count) jewel balances")
                    Button("Save as startup default") { capture.save() }
                    Button("Clear regions", role: .destructive) { capture.clear() }
                    Button("Detect only") { Task { await capture.detect(strictRecognition: configuration.strictGameplayRecognition) } }
                        .disabled(capture.busy || capture.image == nil || capture.previewEnabled)
                }
                if let result = capture.detection {
                    Text("Classification: \(result.state.rawValue)")
                    if let inventory = result.inventory {
                        Text("Inventory estimate: \(inventory.occupied)/\(inventory.total) occupied, \(inventory.uncertain) uncertain, \(inventory.jewelMatches) sample matches • confidence \(inventory.confidence, specifier: "%.2f")")
                            .font(.caption)
                    }
                    ForEach(capture.profile.namedBankBalances) { target in
                        if let sample = result.namedBankBalances[target.id] {
                            Text("\(target.name): \(sample.count.map { String($0) } ?? "unreadable") • OCR: \(sample.text) • confidence \(sample.confidence, specifier: "%.2f") / \(target.threshold, specifier: "%.2f")")
                                .font(.caption.monospaced()).textSelection(.enabled)
                            if let issue = sample.failureReason {
                                Text(issue).font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    ForEach(capture.profile.targets) { target in
                        HStack {
                            if let template = target.template, let image = VisionService.preview(template) {
                                Image(decorative: image, scale: 1).resizable().scaledToFit().frame(width: 72, height: 48)
                            }
                            Text(detectionSummary(target, result))
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
                HStack {
                    Stepper("Grid columns: \(capture.profile.inventoryColumns ?? 8)", value: Binding(get: {
                        capture.profile.inventoryColumns ?? 8
                    }, set: { capture.setGrid(columns: $0, rows: capture.profile.inventoryRows ?? 8) }), in: 1...16)
                    Stepper("Grid rows: \(capture.profile.inventoryRows ?? 8)", value: Binding(get: {
                        capture.profile.inventoryRows ?? 8
                    }, set: { capture.setGrid(columns: capture.profile.inventoryColumns ?? 8, rows: $0) }), in: 1...16)
                }
                Text("For inventory estimates, mark emptyInventoryGrid on a genuinely empty item grid, then capture an occupied grid. Optionally mark one jewelSample cell. Estimates are diagnostics; automatic banking uses the separate bankingTrigger target.")
                    .font(.caption)
                Text("Templates are region-based and must be checked on positive AND negative screenshots. Similarity is not a probability. Detection does not prove a transfer or helper activation succeeded.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
        .onDisappear { capture.stopPreview() }
    }

    private var namedBalanceEditor: some View {
        GroupBox("Named jewel balances") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Mark a named jewel balance", isOn: $markingNamedBalance)
                Text("Keep bankTitle calibrated. Enter the jewel name, choose its number format, then draw around only that jewel’s number. Repeat for each jewel. The same name updates its existing region.")
                    .font(.caption)
                Text("Choose a jewel, then draw around its balance:").font(.caption)
                ForEach(NamedBankBalanceTarget.suggestedNames, id: \.self) { name in
                    Button(name) {
                        jewelName = name; markingNamedBalance = true
                        if let target = capture.profile.namedBankBalances.first(where: { $0.name == name }) {
                            jewelFormat = target.format; jewelThreshold = target.threshold
                        }
                    }
                }
                if markingNamedBalance {
                    TextField("Jewel name", text: $jewelName)
                    Picker("Jewel number format", selection: $jewelFormat) {
                        ForEach(CountFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    HStack {
                        Text("Jewel OCR confidence \(jewelThreshold, specifier: "%.2f")")
                        Slider(value: $jewelThreshold, in: 0.8...1)
                    }
                    Text("Changing the name or options applies when you draw the rectangle. Save as startup default when finished.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(capture.profile.namedBankBalances) { target in
                    HStack {
                        Button("Edit \(target.name)") {
                            jewelName = target.name; jewelFormat = target.format
                            jewelThreshold = target.threshold; markingNamedBalance = true
                        }
                        Text(target.format.rawValue).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove", role: .destructive) { capture.removeNamedBalance(target.id) }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private var requiredRoles: Set<TargetRole> {
        CalibrationRequirements.roles(configuration: configuration, settings: settings)
    }

    private func detectionSummary(_ target: CalibratedTarget, _ result: AutomationCore.Observation) -> String {
        let match = result.has(target.role) ? "match" : "no match"
        let score = result.scores[target.role].map { String(format: "%.3f", $0) } ?? "—"
        let threshold = String(format: "%.2f", target.threshold)
        let expected = target.role.isNumericEvidence ? "numeric count" : (target.expectedText ?? "image only")
        return "\(target.role.rawValue): \(match) • score \(score) / \(threshold) • expected: \(expected) • OCR: \(result.text[target.role] ?? "not used")"
    }

    private var calibrationPlan: some View {
        GroupBox("Calibration plan — jewel banking first") {
            VStack(alignment: .leading, spacing: 8) {
                if settings.bankingInputMode == .recordedInput {
                    Text("Recorded inputs are selected. Select your game window here, then use Record inputs → Jewel workflow. Inventory/bank button images and panel labels are not needed for recorded playback.")
                    Text("For recovery in full mode, keep OCR labels for deathIndicator, deathConfirmation, respawnIndicator and destinationLandmark. Record Return to spot for the movement sequence. Enabled Helper/skill modules can still require their own labels.")
                } else {
                Text("1. Select the active open.mu window → Capture snapshot → freeze preview → label game area and the inventory button. The normal-play label is optional in relaxed recognition.")
                Text("2. Open inventory manually → recapture → label inventory, its close button and the bank button. Open the bank → recapture → label bank title, Transfer, excluded Withdraw and bank close.")
                Text("3. Use real before/pending/after transfer examples. Label Processing and the proof chosen in Workflows: \(verificationTarget.rawValue). Strict recognition also requires the general gameplay and interruption labels.")
                Text("4. Save calibration → capture fresh examples → Detect only → inspect matches/OCR → confirm review on Dashboard. After Start, focus the game during the countdown.")
                }
                Text("Jewel banking transfers jewels already in inventory. Add Helper looting, skills, monitoring and recovery after this workflow works.")
                    .foregroundStyle(.secondary)
                if configuration.mode == .fullAutomation {
                    Text("To test banking first in Full automation, enable banking and turn off Helper, skills, recovery and the banking-trigger monitor. After depositing, full mode keeps monitoring the game until you press Stop.")
                        .foregroundStyle(.secondary)
                    if settings.bankingEnabled && settings.inventoryMonitoringEnabled {
                        Text("The banking-trigger monitor is enabled: also label bankingTrigger for repeat banking. This target is needed by the monitor even though Start does not require it.")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Current options: \(configuration.mode.title) • jewel banking \(settings.bankingEnabled ? "enabled" : "disabled"). Change options on Dashboard / Workflows to update this checklist.")
                Text(configuration.strictGameplayRecognition
                     ? "Strict recognition: normalGameplay and interruption labels are required."
                     : "Relaxed recognition: normalGameplay and general interruption labels are optional. Existing interruption labels still stop input when they match.")
                DisclosureGroup("Required before Start: \(requiredRoles.filter { hasLabel($0) }.count)/\(requiredRoles.count) targets labeled — select a row to label it") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(TargetRole.calibrationOrder.filter { requiredRoles.contains($0) }, id: \.self) { role in
                            Button { capture.role = role } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: hasLabel(role) ? "checkmark.circle" : "circle")
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("\(role.rawValue) — \(role.calibrationGuide.title)").bold()
                                        Text("\(role.calibrationGuide.kind): \(role.calibrationGuide.instruction)")
                                            .foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.padding(.top, 8)
                }
                Text("Label count does not verify detection. Each target needs its own real screen example; not every target should match the same screenshot. Click targets use a measured cursor position when set, otherwise the rectangle center.")
                    .foregroundStyle(.secondary)
            }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private var verificationTarget: TargetRole { settings.bankingVerification.countRole ?? .transferSuccess }

    private func hasLabel(_ role: TargetRole) -> Bool {
        capture.profile.targets.contains {
            $0.role == role && (role == .gameViewport || (!configuration.strictGameplayRecognition && role.isClickControl)
                               || $0.template != nil || !($0.expectedText ?? "").isEmpty)
        }
    }

    private var targetDescription: some View {
        let guide = capture.role.calibrationGuide
        return GroupBox("\(guide.title) • \(guide.kind)") {
            VStack(alignment: .leading, spacing: 6) {
                Text(guide.group.rawValue).font(.caption).foregroundStyle(.secondary)
                Text(guide.instruction)
                if !configuration.strictGameplayRecognition && !capture.role.isNumericEvidence {
                    Text(capture.role.isRecoveryEvidence
                         ? "Death, spawn, destination and route evidence use the OCR phrase when configured, including in relaxed mode. Leave it blank to use the saved image."
                         : "Relaxed detection uses the saved image when available; an optional OCR phrase is diagnostic. OCR-only targets still use their phrase.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !configuration.strictGameplayRecognition && capture.role.isClickControl {
                    Text("Relaxed mode uses this control's saved click point, or the rectangle center, even when its OCR/template does not match.")
                        .font(.caption)
                }
                if capture.role.isClickControl,
                   let target = capture.profile.targets.first(where: { $0.role == capture.role }) {
                    HStack {
                        Button("Set click from game cursor (5 seconds)") { Task { await capture.locateClickFromCursor() } }
                            .disabled(capture.busy || capture.selectedID == nil)
                        if target.clickPoint != nil {
                            Button("Use rectangle center") { try? capture.setClickPoint(nil) }.disabled(capture.busy)
                        }
                    }
                    Text("Focus the selected game and hover its actual button during the countdown. This measures a position without clicking or changing the recognition rectangle.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let point = target.clickPoint {
                        Text("Cursor click point: \(point.x, specifier: "%.4f"), \(point.y, specifier: "%.4f") of the selected window")
                            .font(.caption.monospaced())
                    }
                }
                if let target = capture.profile.targets.first(where: { $0.role == capture.role }),
                   let image = capture.image, let cropped = VisionService.crop(image, region: target.region) {
                    HStack(alignment: .top) {
                        if let template = target.template, let saved = VisionService.preview(template) {
                            VStack {
                                Text("Saved template").font(.caption)
                                Image(decorative: saved, scale: 1).resizable().scaledToFit().frame(width: 160, height: 80)
                            }
                        }
                        VStack {
                            Text("Selected region in current snapshot").font(.caption)
                            Image(decorative: cropped, scale: 1).resizable().scaledToFit().frame(width: 240, height: 80)
                        }
                    }
                }
                Text(requiredRoles.contains(capture.role)
                     ? "Required before Start with your current options."
                     : capture.role == .bankTitle && !capture.profile.namedBankBalances.isEmpty
                     ? "Required for reading your named jewel balances. Recorded playback can start without it, but balances update only when this header is recognized."
                     : "Not required by Start with your current options; check the workflow description above for when this target is needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}

private struct RegionCanvas: View {
    let image: CGImage
    let targets: [CalibratedTarget]
    let selected: TargetRole
    var namedBalances: [NamedBankBalanceTarget] = []
    var selectedName: String? = nil
    let mark: (NormalizedRegion) -> Void
    @State private var drag: CGRect?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable()
                ForEach(targets) { target in
                    let r = target.region
                    Rectangle().stroke(target.role == .withdrawExcluded ? Color.red
                                       : (target.role == selected ? Color.yellow : Color.green.opacity(0.35)), lineWidth: 2)
                        .frame(width: r.width * geometry.size.width, height: r.height * geometry.size.height)
                        .overlay(alignment: .topLeading) {
                            Text(target.role.rawValue).font(.caption2).background(.black.opacity(0.8)).foregroundStyle(.white)
                        }
                        .offset(x: r.x * geometry.size.width, y: r.y * geometry.size.height)
                }
                ForEach(namedBalances) { target in
                    let r = target.region
                    Rectangle().stroke(selectedName == target.name ? Color.yellow : Color.cyan, lineWidth: 2)
                        .frame(width: r.width * geometry.size.width, height: r.height * geometry.size.height)
                        .overlay(alignment: .topLeading) {
                            Text(target.name).font(.caption2).background(.black.opacity(0.8)).foregroundStyle(.white)
                        }
                        .offset(x: r.x * geometry.size.width, y: r.y * geometry.size.height)
                }
                if let drag {
                    Rectangle().stroke(.yellow, style: StrokeStyle(lineWidth: 2, dash: [4]))
                        .frame(width: drag.width, height: drag.height)
                        .offset(x: drag.minX, y: drag.minY)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { value in drag = rectangle(value, in: geometry.size) }
                .onEnded { value in
                    defer { drag = nil }
                    let rect = rectangle(value, in: geometry.size)
                    guard rect.width >= 4, rect.height >= 4,
                          let region = try? NormalizedRegion(
                            x: rect.minX / geometry.size.width, y: rect.minY / geometry.size.height,
                            width: rect.width / geometry.size.width, height: rect.height / geometry.size.height)
                    else { return }
                    mark(region)
                })
        }
    }

    private func rectangle(_ value: DragGesture.Value, in size: CGSize) -> CGRect {
        let x1 = min(max(value.startLocation.x, 0), size.width)
        let y1 = min(max(value.startLocation.y, 0), size.height)
        let x2 = min(max(value.location.x, 0), size.width)
        let y2 = min(max(value.location.y, 0), size.height)
        return CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
    }
}

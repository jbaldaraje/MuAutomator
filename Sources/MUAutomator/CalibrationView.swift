import SwiftUI
import ScreenCaptureKit
import AutomationCore

@MainActor
struct CalibrationView: View {
    @ObservedObject var capture: CaptureModel
    let configuration: AutomationConfiguration
    let settings: WorkflowSettings

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
                    Picker("Target label", selection: $capture.role) {
                        ForEach(CalibrationTargetGroup.allCases, id: \.self) { group in
                            Section(group.rawValue) {
                                ForEach(TargetRole.calibrationOrder.filter { $0.calibrationGuide.group == group }, id: \.self) { role in
                                    Text("\(role.rawValue) — \(role.calibrationGuide.title)")
                                        .tag(role).help(role.calibrationGuide.instruction)
                                }
                            }
                        }
                    }.pickerStyle(.menu)
                    targetDescription
                    TextField("Optional exact OCR phrase (must also match the template)", text: $capture.expectedText)
                    HStack {
                        Text("Minimum similarity \(capture.threshold, specifier: "%.2f")")
                        Slider(value: $capture.threshold, in: 0.8...1)
                    }
                    RegionCanvas(image: image, targets: capture.profile.targets, mark: capture.mark)
                        .aspectRatio(CGFloat(image.width) / CGFloat(image.height), contentMode: .fit)
                        .disabled(capture.previewEnabled)
                    if capture.previewEnabled { Text("Freeze preview before marking regions or reviewing detection.").font(.caption) }
                    Text("Drag on the snapshot. Red = excluded Withdraw region. Regions are window-relative; recheck after UI or layout changes.")
                        .font(.caption)
                }
                HStack {
                    Text("\(capture.profile.targets.count) labeled regions")
                    Button("Save as startup default") { capture.save() }
                    Button("Clear regions", role: .destructive) { capture.clear() }
                    Button("Detect only") { Task { await capture.detect() } }
                        .disabled(capture.busy || capture.image == nil || capture.previewEnabled)
                }
                if let result = capture.detection {
                    Text("Classification: \(result.state.rawValue)")
                    if let inventory = result.inventory {
                        Text("Inventory estimate: \(inventory.occupied)/\(inventory.total) occupied, \(inventory.uncertain) uncertain, \(inventory.jewelMatches) sample matches • confidence \(inventory.confidence, specifier: "%.2f")")
                            .font(.caption)
                    }
                    ForEach(capture.profile.targets) { target in
                        HStack {
                            if let template = target.template, let image = VisionService.preview(template) {
                                Image(decorative: image, scale: 1).resizable().scaledToFit().frame(width: 72, height: 48)
                            }
                            Text("\(target.role.rawValue): \(result.matches[target.role].map { String(format: "%.3f", $0) } ?? "no match") • OCR: \(result.text[target.role] ?? "—")")
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
        .onChange(of: capture.role) { _, role in
            let target = capture.profile.targets.first { $0.role == role }
            capture.expectedText = target?.expectedText ?? ""
            capture.threshold = target?.threshold ?? 0.95
        }
    }

    private var requiredRoles: Set<TargetRole> {
        CalibrationRequirements.roles(configuration: configuration, settings: settings)
    }

    private var calibrationPlan: some View {
        GroupBox("Calibration plan — jewel banking first") {
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Select the active open.mu window → Capture snapshot → freeze preview → label game area, normal play and the inventory button.")
                Text("2. Open inventory manually → recapture → label inventory, its close button and the bank button. Open the bank → recapture → label bank title, Transfer, excluded Withdraw and bank close.")
                Text("3. Use real before/pending/after transfer examples. Label Processing and the proof chosen in Workflows: \(verificationTarget.rawValue). Also label real interruption states before live use.")
                Text("4. Save calibration → capture fresh examples → Detect only → inspect matches/OCR → confirm review on Dashboard. After Start, focus the game during the countdown.")
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
                Text("Label count does not verify detection. Each target needs its own real screen example; not every target should match the same screenshot. Click targets use the center of your rectangle.")
                    .foregroundStyle(.secondary)
            }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private var verificationTarget: TargetRole { settings.bankingVerification.countRole ?? .transferSuccess }

    private func hasLabel(_ role: TargetRole) -> Bool {
        capture.profile.targets.contains {
            $0.role == role && (role == .gameViewport || $0.template != nil || !($0.expectedText ?? "").isEmpty)
        }
    }

    private var targetDescription: some View {
        let guide = capture.role.calibrationGuide
        return GroupBox("\(guide.title) • \(guide.kind)") {
            VStack(alignment: .leading, spacing: 6) {
                Text(guide.group.rawValue).font(.caption).foregroundStyle(.secondary)
                Text(guide.instruction)
                Text(requiredRoles.contains(capture.role)
                     ? "Required before Start with your current options."
                     : "Not required by Start with your current options; check the workflow description above for when this target is needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}

private struct RegionCanvas: View {
    let image: CGImage
    let targets: [CalibratedTarget]
    let mark: (NormalizedRegion) -> Void
    @State private var drag: CGRect?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable()
                ForEach(targets) { target in
                    let r = target.region
                    Rectangle().stroke(target.role == .withdrawExcluded ? Color.red : Color.green, lineWidth: 2)
                        .frame(width: r.width * geometry.size.width, height: r.height * geometry.size.height)
                        .overlay(alignment: .topLeading) {
                            Text(target.role.rawValue).font(.caption2).background(.black.opacity(0.8)).foregroundStyle(.white)
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

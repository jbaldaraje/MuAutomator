import AppKit
import ScreenCaptureKit
import CoreGraphics
import SwiftUI
import AutomationCore
import ApplicationServices

@MainActor
final class CaptureModel: ObservableObject {
    @Published var windows: [SCWindow] = []
    @Published var selectedID: CGWindowID?
    @Published private(set) var image: CGImage?
    @Published private(set) var capturedAt: Date?
    @Published private(set) var busy = false
    @Published private(set) var message = "Screen Recording and Accessibility are needed to find and capture open.mu browser windows."
    @Published private(set) var profile = CalibrationProfile()
    @Published var role: TargetRole = .gameViewport {
        didSet { if oldValue != role { loadTargetSettings() } }
    }
    @Published var expectedText = "" { didSet { updateTargetSettings() } }
    @Published var threshold = 0.95 { didSet { updateTargetSettings() } }
    @Published private(set) var detection: Observation?
    @Published private(set) var previewEnabled = false
    @Published var profileName = "Default"
    @Published private(set) var namedProfiles: [String] = []
    @Published private(set) var discoveryDetails = ""
    private var previewTask: Task<Void, Never>?
    private let profileURL: URL
    private var loadingTargetSettings = false
    private var detectionRevision = 0

    init(profileURL: URL? = nil) {
        self.profileURL = profileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MUAutomator/calibration.json")
        if FileManager.default.fileExists(atPath: self.profileURL.path) {
            do {
                let loaded = try JSONDecoder().decode(CalibrationProfile.self, from: Data(contentsOf: self.profileURL))
                try loaded.validate()
                profile = loaded
            } catch { message = "Calibration could not be loaded: \(error)" }
        }
        refreshProfiles()
        loadTargetSettings()
    }

    private func invalidateDetection() {
        detectionRevision += 1
        detection = nil
    }

    private func loadTargetSettings() {
        loadingTargetSettings = true
        defer { loadingTargetSettings = false }
        let target = profile.targets.first { $0.role == role }
        expectedText = target?.expectedText ?? ""
        threshold = target?.threshold ?? 0.95
    }

    private func updateTargetSettings() {
        guard !loadingTargetSettings, let index = profile.targets.firstIndex(where: { $0.role == role }) else { return }
        let phrase = expectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = phrase.isEmpty ? nil : phrase
        guard profile.targets[index].expectedText != value || profile.targets[index].threshold != threshold else { return }
        profile.targets[index].expectedText = value
        profile.targets[index].threshold = threshold
        invalidateDetection()
        message = "Updated \(role.rawValue) settings. Save the profile to keep them after relaunch."
    }

    /// Explicitly select the existing phrase-only recognition path without redrawing.
    func useOCROnly() {
        let phrase = expectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !role.isNumericEvidence, !phrase.isEmpty,
              let index = profile.targets.firstIndex(where: { $0.role == role }) else {
            message = "Select a saved target and enter its fixed OCR phrase first."
            return
        }
        profile.targets[index].expectedText = phrase
        profile.targets[index].template = nil
        invalidateDetection()
        message = "\(role.rawValue) now uses its OCR phrase in both Detect only and live playback. Save the profile."
    }

    private func refreshProfiles() {
        let directory = profileURL.deletingLastPathComponent().appendingPathComponent("Profiles")
        namedProfiles = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    private func namedURL() throws -> URL {
        guard profileName.range(of: "^[A-Za-z0-9_-]{1,40}$", options: .regularExpression) != nil else {
            throw WorkflowFailure.prerequisite("Profile name must be 1–40 letters, numbers, underscores or dashes")
        }
        return profileURL.deletingLastPathComponent().appendingPathComponent("Profiles/\(profileName).json")
    }

    func saveNamedProfile() {
        do {
            try profile.validate()
            let url = try namedURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(profile).write(to: url, options: .atomic)
            refreshProfiles(); message = "Named profile saved. Save as default separately to load it automatically next launch."
        } catch { message = error.localizedDescription }
    }

    func loadNamedProfile() {
        do {
            let value = try JSONDecoder().decode(CalibrationProfile.self, from: Data(contentsOf: namedURL()))
            try value.validate()
            stopPreview(); profile = value; image = nil; capturedAt = nil; invalidateDetection(); loadTargetSettings()
            message = "Profile loaded. Recapture and review detection before live input."
        } catch { message = error.localizedDescription }
    }

    func select(_ id: CGWindowID?) {
        stopPreview()
        selectedID = id
        image = nil
        capturedAt = nil
        invalidateDetection()
    }

    func startPreview() {
        guard !previewEnabled, selectedID != nil else { return }
        previewEnabled = true
        previewTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, previewEnabled, selectedID != nil else { return }
                await capture()
                do { try await Task.sleep(nanoseconds: 750_000_000) } catch { return }
            }
        }
    }

    func stopPreview() {
        guard previewEnabled || previewTask != nil else { return }
        previewTask?.cancel(); previewTask = nil; previewEnabled = false
    }

    func refresh(requestPermission: Bool = false) async {
        guard !busy else { return }
        stopPreview()
        busy = true
        defer { busy = false }
        message = "Looking for browser windows whose active page is https://open.mu…"
        discoveryDetails = ""
        let allowed = await Task.detached(priority: .utility) { CGPreflightScreenCaptureAccess() }.value
        guard !Task.isCancelled else { return }
        if !allowed && requestPermission {
            _ = CGRequestScreenCaptureAccess()
        }
        let accessibility = await Task.detached(priority: .utility) { AXIsProcessTrusted() }.value
        guard accessibility else {
            windows = []; select(nil)
            message = "Accessibility is required to verify browser URLs. Click Allow Accessibility for URL detection, enable MU Automator, then refresh."
            return
        }
        // ScreenCaptureKit is the authority: a stale preflight result must not
        // prevent the actual framework from reporting its permission/error state.
        do {
            // Include other Spaces and minimized windows in discovery. The user
            // must still restore/focus the selected game before live automation.
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            try Task.checkCancellation()
            let eligible = content.windows.filter {
                $0.windowLayer == 0 && $0.frame.width > 0 && $0.frame.height > 0
                && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
            }
            let candidates = eligible.compactMap(BrowserWindowCandidate.init)
            let report = await Task.detached(priority: .utility) {
                BrowserWindowDiscovery.inspect(candidates)
            }.value
            try Task.checkCancellation()
            windows = eligible.filter { report.windowIDs.contains($0.windowID) }.sorted {
                let left = ($0.owningApplication?.applicationName ?? "") + ($0.title ?? "")
                let right = ($1.owningApplication?.applicationName ?? "") + ($1.title ?? "")
                return left == right ? $0.windowID < $1.windowID : left < right
            }
            if let id = selectedID, !windows.contains(where: { $0.windowID == id }) { select(nil) }
            discoveryDetails = (["Checked \(candidates.count) browser windows; \(windows.count) verified open.mu windows. Screen Recording precheck: \(allowed ? "allowed" : "not confirmed")."] + report.details).joined(separator: "\n")
            message = windows.isEmpty
                ? "No verified open.mu window found. Make https://open.mu the active tab in Chrome, allow Screen Recording and Accessibility, then refresh. Windows with unreadable URLs stay hidden."
                : "Found \(windows.count) open.mu windows. Select the game below. Other websites are hidden."
        } catch is CancellationError {
            message = "Window refresh cancelled."
        } catch {
            windows = []; select(nil)
            let failure = error as NSError
            discoveryDetails = "\(failure.domain), code \(failure.code). Permission precheck: \(allowed ? "allowed" : "not confirmed")."
            message = "Cannot list game windows: \(failure.localizedDescription). Check Screen Recording permission for this copy of MU Automator, then quit/reopen it and refresh."
        }
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func requestURLPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func capture() async {
        guard !busy, let id = selectedID else { return }
        busy = true
        defer { busy = false }
        // Keep the last frame mounted while a new one is captured. Removing it
        // each tick tears down/rebuilds the calibration canvas during preview.
        invalidateDetection()
        do {
            // Resolve the window again; never capture from a stale selection object.
            // The framework enforces Screen Recording access for both discovery
            // and capture, even when the legacy preflight API disagrees.
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            try Task.checkCancellation()
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                select(nil); message = "Selected window disappeared. Select it again."; return
            }
            guard BrowserWindowCandidate(window) != nil else {
                select(nil); message = "Selected window is not a supported browser window."; return
            }
            let candidates = content.windows.compactMap(BrowserWindowCandidate.init)
            let confirmed = await Task.detached(priority: .utility) {
                BrowserWindowDiscovery.matchingWindowIDs(candidates).contains(id)
            }.value
            try Task.checkCancellation()
            guard confirmed, selectedID == id else {
                select(nil); message = "The selected window's active page is no longer verified as open.mu. Open the game tab and refresh."; return
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = max(1, Int(window.frame.width * 2))
            config.height = max(1, Int(window.frame.height * 2))
            config.showsCursor = false
            let frame = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            try Task.checkCancellation()
            guard selectedID == id else { return }
            image = frame; capturedAt = Date()
            message = "Snapshot captured. Drag a rectangle to label a target. No input is sent to the game."
        } catch is CancellationError {
            // Leaving Calibration cancels preview without clearing the frozen frame.
        } catch {
            image = nil; capturedAt = nil
            message = "Capture failed: \(error.localizedDescription)"
        }
    }

    func mark(_ region: NormalizedRegion) {
        guard let image else { return }
        let ratio = Double(image.width) / Double(image.height)
        if let old = profile.windowAspectRatio, abs(old - ratio) > 0.01, !profile.targets.isEmpty || !profile.namedBankBalances.isEmpty {
            message = "Window aspect ratio changed. Clear the old calibration before marking new targets."
            return
        }
        profile.windowAspectRatio = ratio
        let width = role == .emptyInventoryGrid ? 128 : (role == .jewelSample ? 128 / (profile.inventoryColumns ?? 8) : 48)
        let height = role == .emptyInventoryGrid ? 128 : (role == .jewelSample ? 128 / (profile.inventoryRows ?? 8) : 32)
        guard let crop = VisionService.crop(image, region: region), let template = VisionService.gray(crop, width: width, height: height) else {
            message = "Could not create target template"; return
        }
        profile.targets.removeAll { $0.role == role }
        profile.targets.append(.init(role: role, region: region, template: template,
                                    expectedText: expectedText.isEmpty ? nil : expectedText, threshold: threshold))
        invalidateDetection()
        message = "Created template for \(role.rawValue). Save, then test against a fresh screenshot."
    }

    func markNamedBalance(_ region: NormalizedRegion, name: String, format: CountFormat, threshold: Double) {
        guard let image else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let ratio = Double(image.width) / Double(image.height)
        if let old = profile.windowAspectRatio, abs(old - ratio) > 0.01,
           !profile.targets.isEmpty || !profile.namedBankBalances.isEmpty {
            message = "Window aspect ratio changed. Use a profile matching this layout."
            return
        }
        var updated = profile
        updated.windowAspectRatio = ratio
        let existing = updated.namedBankBalances.firstIndex { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        let target = NamedBankBalanceTarget(id: existing.map { updated.namedBankBalances[$0].id } ?? UUID(),
                                           name: trimmed, region: region, format: format, threshold: threshold)
        if let existing { updated.namedBankBalances[existing] = target }
        else { updated.namedBankBalances.append(target) }
        do {
            try updated.validate()
            profile = updated; invalidateDetection()
            message = "Marked \(trimmed). Save as startup default, then Capture snapshot and Detect only."
        } catch {
            message = "Use a unique jewel name (1–80 characters), separate non-overlapping number regions, and at most 32 jewels."
        }
    }

    func removeNamedBalance(_ id: UUID) {
        profile.namedBankBalances.removeAll { $0.id == id }
        invalidateDetection()
    }

    func setGrid(columns: Int, rows: Int) {
        guard (1...16).contains(columns), (1...16).contains(rows) else { return }
        profile.inventoryColumns = columns; profile.inventoryRows = rows; invalidateDetection()
    }

    func setClickPoint(_ point: CalibratedClickPoint?) throws {
        guard role.isClickControl, let index = profile.targets.firstIndex(where: { $0.role == role }) else {
            throw WorkflowFailure.prerequisite("Label this control first")
        }
        try point?.validate()
        if let point {
            guard let viewport = profile.targets.first(where: { $0.role == .gameViewport }),
                  viewport.region.contains(x: point.x, y: point.y) else {
                throw WorkflowFailure.prerequisite("Place the cursor inside the calibrated game area")
            }
            if let excluded = profile.targets.first(where: { $0.role == .withdrawExcluded }),
               excluded.region.contains(x: point.x, y: point.y) {
                throw WorkflowFailure.prerequisite("The cursor is inside the excluded Withdraw area")
            }
        }
        profile.targets[index].clickPoint = point
        invalidateDetection()
        message = point == nil ? "Using the rectangle center for \(role.rawValue). Save the profile."
            : "Saved cursor position for \(role.rawValue) in memory. Other regions and templates are unchanged. Save the profile."
    }

    func locateClickFromCursor() async {
        guard !busy, role.isClickControl,
              let window = windows.first(where: { $0.windowID == selectedID }) else { return }
        stopPreview(); busy = true
        defer { busy = false }
        message = "5 seconds: focus the selected game and place the cursor over \(role.rawValue). No click will be sent."
        do {
            let selectedRole = role
            let io = try MacWorkflowIO(window: window, profile: profile)
            try await Task.sleep(nanoseconds: 5_000_000_000)
            try await io.prepareSelectedWindow()
            guard role == selectedRole, selectedID == window.windowID,
                  let cursor = CGEvent(source: nil)?.location,
                  io.captureBounds.contains(cursor), MacWorkflowIO.topWindow(at: cursor) == window.windowID else {
                throw WorkflowFailure.prerequisite("Cursor is not over the selected game window; try again")
            }
            let bounds = io.captureBounds
            try setClickPoint(CalibratedClickPoint(x: (cursor.x - bounds.minX) / bounds.width,
                                                 y: (cursor.y - bounds.minY) / bounds.height))
        } catch { message = error.localizedDescription }
    }

    func detect(strictRecognition: Bool = true) async {
        guard !busy, let image, let capturedAt else { return }
        busy = true
        defer { busy = false }
        let profile = self.profile
        let revision = detectionRevision
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try VisionService.detect(image: image, profile: profile, timestamp: capturedAt, strictRecognition: strictRecognition)
            }.value
            guard !Task.isCancelled, revision == detectionRevision else {
                message = "Calibration changed during detection. Run Detect only again."
                return
            }
            detection = result
            message = "Dry-run detection finished; no input sent. Review each match and OCR text."
        } catch { message = "Detection failed: \(error.localizedDescription)" }
    }

    func clear() {
        profile = .init(); invalidateDetection(); loadTargetSettings()
        message = "Calibration cleared in memory. Save to persist."
    }

    func save() {
        do {
            try profile.validate()
            try FileManager.default.createDirectory(at: profileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(profile).write(to: profileURL, options: .atomic)
            message = "Calibration regions and small grayscale templates saved locally. Full screenshots are not saved."
        } catch { message = "Save failed: \(error.localizedDescription)" }
    }
}

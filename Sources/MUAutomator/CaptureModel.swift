import AppKit
import ScreenCaptureKit
import CoreGraphics
import SwiftUI
import AutomationCore

@MainActor
final class CaptureModel: ObservableObject {
    @Published var windows: [SCWindow] = []
    @Published var selectedID: CGWindowID?
    @Published private(set) var image: CGImage?
    @Published private(set) var capturedAt: Date?
    @Published private(set) var busy = false
    @Published private(set) var message = "Screen Recording permission is needed to list and capture game windows."
    @Published private(set) var profile = CalibrationProfile()
    @Published var role: TargetRole = .inventoryPanel
    @Published var expectedText = ""
    @Published var threshold = 0.95
    @Published private(set) var detection: Observation?
    @Published private(set) var previewEnabled = false
    @Published var profileName = "Default"
    @Published private(set) var namedProfiles: [String] = []
    @Published private(set) var discoveryDetails = ""
    private var previewTask: Task<Void, Never>?
    private let profileURL: URL

    init() {
        profileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MUAutomator/calibration.json")
        if FileManager.default.fileExists(atPath: profileURL.path) {
            do {
                let loaded = try JSONDecoder().decode(CalibrationProfile.self, from: Data(contentsOf: profileURL))
                try loaded.validate()
                profile = loaded
            } catch { message = "Calibration could not be loaded: \(error)" }
        }
        refreshProfiles()
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
            stopPreview(); profile = value; image = nil; capturedAt = nil; detection = nil
            message = "Profile loaded. Recapture and review detection before live input."
        } catch { message = error.localizedDescription }
    }

    func select(_ id: CGWindowID?) {
        stopPreview()
        selectedID = id
        image = nil
        capturedAt = nil
        detection = nil
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
        message = "Looking for game windows…"
        discoveryDetails = ""
        let allowed = await Task.detached(priority: .utility) { CGPreflightScreenCaptureAccess() }.value
        guard !Task.isCancelled else { return }
        if !allowed && requestPermission {
            _ = CGRequestScreenCaptureAccess()
        }
        // ScreenCaptureKit is the authority: a stale preflight result must not
        // prevent the actual framework from reporting its permission/error state.
        do {
            // Include other Spaces and minimized windows in discovery. The user
            // must still restore/focus the selected game before live automation.
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            try Task.checkCancellation()
            windows = content.windows.filter {
                $0.windowLayer == 0 && $0.frame.width > 0 && $0.frame.height > 0
                && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
            }.sorted {
                let left = ($0.owningApplication?.applicationName ?? "") + ($0.title ?? "")
                let right = ($1.owningApplication?.applicationName ?? "") + ($1.title ?? "")
                return left == right ? $0.windowID < $1.windowID : left < right
            }
            if let id = selectedID, !windows.contains(where: { $0.windowID == id }) { select(nil) }
            discoveryDetails = "ScreenCaptureKit returned \(content.windows.count) windows; \(windows.count) selectable. Permission precheck: \(allowed ? "allowed" : "not confirmed")."
            message = windows.isEmpty
                ? "No selectable windows returned. Open Chrome with the game, enable this app in Screen Recording settings, then quit/reopen MU Automator and refresh."
                : "Found \(windows.count) windows. Select Chrome below. Restore the game window if it is minimized or on another Space."
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

    func capture() async {
        guard !busy, let id = selectedID else { return }
        busy = true
        defer { busy = false }
        // Keep the last frame mounted while a new one is captured. Removing it
        // each tick tears down/rebuilds the calibration canvas during preview.
        detection = nil
        do {
            // Resolve the window again; never capture from a stale selection object.
            // The framework enforces Screen Recording access for both discovery
            // and capture, even when the legacy preflight API disagrees.
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            try Task.checkCancellation()
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                select(nil); message = "Selected window disappeared. Select it again."; return
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
        if let old = profile.windowAspectRatio, abs(old - ratio) > 0.01, !profile.targets.isEmpty {
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
        detection = nil
        message = "Created template for \(role.rawValue). Save, then test against a fresh screenshot."
    }

    func setGrid(columns: Int, rows: Int) {
        guard (1...16).contains(columns), (1...16).contains(rows) else { return }
        profile.inventoryColumns = columns; profile.inventoryRows = rows; detection = nil
    }

    func detect() async {
        guard !busy, let image, let capturedAt else { return }
        busy = true
        defer { busy = false }
        let profile = self.profile
        do {
            detection = try await Task.detached(priority: .userInitiated) {
                try VisionService.detect(image: image, profile: profile, timestamp: capturedAt)
            }.value
            message = "Dry-run detection finished; no input sent. Review each match and OCR text."
        } catch { message = "Detection failed: \(error.localizedDescription)" }
    }

    func clear() { profile = .init(); message = "Calibration cleared in memory. Save to persist." }

    func save() {
        do {
            try profile.validate()
            try FileManager.default.createDirectory(at: profileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(profile).write(to: profileURL, options: .atomic)
            message = "Calibration regions and small grayscale templates saved locally. Full screenshots are not saved."
        } catch { message = "Save failed: \(error.localizedDescription)" }
    }
}

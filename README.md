# MU Automator

Native SwiftUI automation application for macOS 14+ and Apple Silicon. The repository now contains the workflow engine and macOS adapters; it is **not yet validated as a working local gameplay application**. Read [implementation status](docs/IMPLEMENTATION-STATUS.md) before enabling live input.

## Build and run on your Mac

Install Xcode 15+ and select its command-line tools. From this directory:

```sh
swift test -j 2
bash scripts/build-macos.sh
open .build/xcode/Build/Products/Release/MUAutomator.app
```

The script runs tests, builds an Apple Silicon app, creates its icon, ad-hoc signs the bundle, and verifies that signature. It has not been executed on macOS here. Distribution signing/notarization requires your own Apple identity.

You can also open `MUAutomator.xcodeproj`, select the shared MUAutomator scheme and My Mac, and build/run with Command-R. The project scheme builds the app; run package tests with `swift test` or open `Package.swift` in Xcode to run its tests. The project scheme does not include the package test targets. `swift run MUAutomator` is also supported; use a consistent app bundle for permission testing because macOS grants permissions to an application identity.

## Modes

- **Jewels only:** open inventory and bank, deposit once, wait for a new calibrated success indicator, close panels, then stop. It never starts the helper, rotates skills, moves, or recovers.
- **Full automation:** run enabled banking/helper modules, monitor gameplay, trigger banking from a configured visual condition with cooldown, run configured skills, and recover through a validated checkpoint route.

Dry run is enabled by default. Detect only and the live preview never send input. Start requires dry run off, explicit input consent, reviewed detection, required calibration, and the selected game window in focus after a five-second countdown. Settings lock during execution, pause, recording and startup. A previous unverified result must be acknowledged before a new workflow can start.

## Calibration

1. In Calibration, allow Screen Recording, refresh windows, and select the Chrome game window.
2. Capture a snapshot or enable live preview. Freeze preview before marking targets.
3. Label `gameViewport` around only the game area. Label controls and state indicators from real examples, using separate screenshots for different dialogs/states. No game coordinates or shortcuts are prefilled.
4. Drag regions to create local grayscale templates; optionally enter OCR text. Both template and text must match when both are configured. Thresholds are adjustable. Save the calibration as the startup default or as a named profile. Named profiles can be loaded from the menu; saving the default separately controls what loads at launch.
5. Capture fresh positive and negative examples and run Detect only. Inspect templates, scores, OCR and classification. Confirm the review on Dashboard. Calibration/window changes invalidate that confirmation.
6. Calibrate banking targets including separate Transfer and excluded Withdraw, pending Processing, a reliable success indicator, and close controls. Also calibrate normal gameplay and interruption states (disconnect, login, character selection, loading, death and respawn). Full-mode modules add helper/recovery/route prerequisites. Start reports missing targets.

A screenshot of Processing is not proof of transfer. Select a newly appearing success indicator, a decreasing inventory count, or an increasing reliable bank balance in Workflows. For numeric verification, calibrate inventoryCountText or bankBalanceText around exactly one count and select digits-only, comma-grouped, or space-grouped format. Parsing rejects labels, malformed grouping, decimals and OCR uncertainty. Unchanged counts remain unverified, including when there are no eligible jewels. Validate the chosen signal against the actual game; a changing count is not proof that every jewel category transferred.

Templates compare calibrated regions; they do not search the entire screen. Moved dialogs, browser zoom changes, fullscreen transitions, same-aspect-ratio layout changes, and effects may invalidate them. Recalibrate rather than lower thresholds to force a match.

## Inventory, skills and routes

Inventory estimates require `emptyInventoryGrid` calibrated on an actually empty item grid. Set row/column counts, capture the occupied grid, and detect. Occupancy and jewel-sample matching are diagnostics with uncertainty reporting; they are not transfer evidence. Automated banking uses the separate `bankingTrigger` indicator, without repeatedly opening inventory to inspect it.

Skills are ordered unmodified macOS virtual key taps with delays, optional cooldowns (zero disables cooldown), and optional visual checks. They do not support held keys or modifier chords. Verify actual shortcuts in the game; no game shortcuts are supplied.

Record route captures user clicks/key taps only in the selected focused window. After recording, assign actual before/after targets to every step, reorder/edit as needed, and calibrate destination landmarks. A route replay test performs movement only and stops after verifying the destination; it never starts the helper. It requires full mode and the same explicit live gates. Confirm manual replay validation before enabling automated recovery. Route edits invalidate validation. Ten checkpoint labels are available in addition to map/destination targets. Holds, drags and original timing are not recorded; replay waits for visual checkpoints.

## Safety and logging

- One task serializes all input. Each action checks cancellation, permissions, focus, window identity, fresh evidence and its visual precondition.
- Window disappearance, unexpected states, focus loss, revoked permissions or unverified outcomes stop execution for manual intervention. No automatic continuation follows them.
- Transfer and helper actions are single-shot. Ambiguous outcomes are never automatically retried. Detection polling and recovery attempts are bounded by configured limits; maximum action retries remain an upper cap, not a promise to repeat mutations.
- Pause prevents subsequent actions. Emergency Stop cancels the task and pending startup. The global stop chord is Control–Option–Command–Escape; pause/resume is Control–Option–Command–P. Verify both on macOS. Dashboard Resume waits five seconds so you can refocus the game. Already delivered events cannot be retracted.
- The Activity tab shows transitions, actions, evidence, confidence, elapsed time, polls, and failures; logs can be exported manually.

Configuration, workflow settings, regions and small templates are saved in `~/Library/Application Support/MUAutomator/`. Full capture frames remain in memory. The app has no network backend, credential storage or automatic screenshot upload. Reference fixtures in this repository came from the supplied recording.

## Validation in this cloud environment

The portable core built successfully and all 33 XCTest tests passed with official Swift 6.0.3 in Docker:

```sh
docker run --rm --network none -v "$PWD":/src -w /src \
  swift:6.0.3-jammy@sha256:b394f699c1844fabf5c01d8a5673639141dc007f500661a4fa56f4ba1f23d87b \
  swift test -j 2
```

On Linux the Swift package intentionally exposes only the core library/test target. macOS includes the executable and additional adapter tests. Linux tests cannot prove Apple framework compilation or gameplay. macOS CI configuration is provided but has not been run here. See [acceptance checks](docs/ACCEPTANCE.md) and [recording review](docs/GAMEPLAY-REFERENCE.md).

The game URL is `https://open.mu/versions/20261006042155/index.html`. Cloud access currently fails at the network proxy with CONNECT 403. An `open.mu` allowlist addition was saved in the environment draft; review/save it in environment settings and publish before retrying. Additional game-service destinations may become apparent only after the page loads.

Cloud tasks are already isolated: use the existing checkout; do not create a Git worktree unless explicitly requested.

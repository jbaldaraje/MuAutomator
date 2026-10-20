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

## Glass interface and menu bar mode

The main window uses native translucent material, with a floating, locally rendered 3D knight and a status bubble that follows the real automation state, focus waits, recording and errors. Reduce Motion in macOS Accessibility settings disables the knight's floating animation. The companion is original Blade Knight–inspired geometry, not official MU game artwork. Official artwork retrieval from `muonline.webzen.com` was blocked by the cloud network proxy; that asset replacement is outstanding.

Use **Minimize to menu bar** or the red close button to hide the window while retaining the current session. The shield icon in the macOS menu bar shows status and completed macro runs, and offers Show, Pause/Resume, Emergency Stop and Quit. Show restores the same window. Quit (or Command-Q) ends the app; closing the window does not. Background mode does not bypass game-focus or permission checks: input waits until the selected game is focused. This does not keep automation running through Mac sleep or logout.

Mac acceptance checks (not executable on Linux): build with the commands above; confirm desktop translucency in light/dark appearance; toggle Reduce Motion; start a configured session, close the main window, return focus to the selected game and confirm progress from the menu bar; pause, stop, reopen and quit from that menu. Run `swift test -j 2` on macOS for the new close/hide/reopen lifecycle checks. Existing macOS CI builds both the Swift package and Xcode app bundle.

## Modes

- **Jewels only:** replay your recorded jewel workflow once, a set number of times, or for a set number of hours; alternatively use the image workflow to open inventory/bank, deposit with visual verification, close panels, then stop. It does not run the separate Helper, skill or recovery modules; the recorded sequence contains only the inputs you chose to capture.
- **Full automation:** run enabled banking/helper modules, monitor gameplay, trigger banking from a configured visual condition with cooldown, run configured skills, and recover through a validated checkpoint route.

**Relaxed gameplay recognition is now the default**, including when loading existing settings. It uses a directly measured cursor position when set, otherwise the center of your saved control region, without requiring button OCR/template matches, a `normalGameplay` match, or general interruption labels at Start. Enable “Strict gameplay recognition” on Dashboard to restore the general-scene requirements. Existing interruption labels still block input when they match; calibrated target presence, inventory/bank transitions, transfer proof, focus/window binding, permissions and cancellation remain active. Strict recognition additionally requires button recognition. Relaxed recognition polls through brief missing panel detections within the action timeout; it never repeats an uncertain transfer.

Dry run is enabled by default. Detect only and the live preview never send input. Start requires dry run off, explicit input consent, and a selected game window bound after a five-second countdown. Playback waits if that window loses focus. Recorded jewel playback needs a saved recording; it does not need inventory/bank image labels or Detect only review. Enabled OCR/image modules still require their targets and detection review. Settings lock during execution, pause, recording and startup. A previous unverified result must be acknowledged before a new workflow can start.

## Recorded inputs — jewel workflow first

1. In Calibration, refresh and select your open.mu Chrome window. No image labels are needed for recorded jewel playback in relaxed recognition.
2. Open **Record inputs → Jewel workflow → Record in 5 seconds**. Focus the selected game and wait for the beep. With inventory/bank initially closed, perform the actual sequence: open inventory, open bank, deposit, wait for the game, then close the panels.
3. Release all controls and press **Control–Option–Command–R** to stop. Recording observes your own input; it never injects events. Left clicks, unmodified key presses/holds, and the gaps between inputs are stored. Drags, modifiers and simultaneous controls are not supported. Recording is limited to 120 seconds/200 completed inputs and holds to 30 seconds. An interrupted or unfinished recording keeps the previous saved sequence.
4. In Workflows, review the recorded positions and edit waits/hold durations if needed, then **Save settings**. A captured jewel recording selects **Recorded inputs** automatically; existing image calibration is preserved.
5. Restore the same starting game state, browser size, zoom and panel layout. On Dashboard choose Jewels only, turn Dry run off, allow live input, and Start. Focus the same selected game during the countdown. The original window size is checked; moving the window between sessions is supported. Playback uses your selected macro repeat limit and does not treat delivered clicks as verified transfer success.

Before Start, set **Macro repeats** on Dashboard or in Workflows: **Once**, **Number of times** (total runs including the first), or **For hours** (decimal hours such as 0.5 are supported). Optionally set a delay between cycles, then Save settings. Each run replays the whole recording, so it should end in the state needed to start again. Dashboard shows completed runs and Activity shows each cycle. Hours include playback and gaps, exclude paused time, and finish the current cycle before stopping. Count/hours mode uses its own limit instead of the general session timeout; other workflow phases keep their remaining session budget. An interruption or failed cycle stops the batch without retrying it. Jewels only stops after the selected macro limit; Full automation continues its other enabled modules. Return-route recordings still play once per recovery/test, independently of this repeat setting. Existing settings default to Once.

For recovery later, record **Return to spot** starting from spawn. In Calibration, mark only the OCR regions needed by recovery: `deathIndicator`, an independent `deathConfirmation`, `respawnIndicator`, and `destinationLandmark`, and set their phrases. These recovery phrases are read during live relaxed detection even when an image template is also saved. Enable recovery in Full automation, test route replay and mark the route validated. The app waits for stable death/spawn evidence, replays the recorded return inputs/timing, and checks the destination. Individual recorded route inputs need no image checkpoints. Keep Helper disabled unless its separate visual controls are configured; existing checkpoint-based routes remain available when no route recording is selected.

Pause blocks subsequent recorded input and freezes pending playback waits; Stop cancels pending input and releases an injected held key/button. Configured interruption labels are checked between inputs and during playback waits. Timing is subject to capture and OS dispatch latency; recording is positional playback, not automatic button recognition or pathfinding. The optional banking-trigger monitor can start another recorded cycle in full mode, so disable it while testing a single recording.

## Dashboard bank balances

Dashboard supports separate balances for **Jewel of Soul**, **Jewel of Creation**, **Jewel of Socket**, and **Jewel of Rare**, plus custom jewel names. Each row shows its balance, observed amount added during that collection, and reading time. Values stay in memory for the current app session; successful readings also appear in Activity for export.

1. Open the bank in the game. In Calibration, capture a snapshot (freeze Live preview first) and mark `bankTitle` on its fixed header as usual.
2. Under **Named jewel balances**, click **Jewel of Soul**. Choose **Jewel number format** for digits (`1234`), comma grouping (`1,234`), or space grouping (`1 234`). Draw around only Soul's number, excluding its name/icon and other numbers.
3. Repeat for **Jewel of Creation**, **Jewel of Socket**, and **Jewel of Rare**. Names are editable; each saved name gets its own region, number format and OCR threshold. The same name updates its existing region when redrawn. Regions must not overlap. **Edit** loads a saved row's settings; redraw to apply changes. **Remove** deletes that row from the profile.
4. Turn off **Mark a named jewel balance** when returning to ordinary target calibration. Click **Save as startup default**, capture a fresh snapshot, then **Detect only**. Check each jewel's OCR number against the game.
5. For recorded inputs, leave the bank visible briefly before depositing and after processing finishes, before closing it. Allow at least two OCR observations at each end. Run a collection and check each Dashboard row.

A confirmed pair of readings is retained with its original timestamp if later frames become unreadable while the bank closes. Those later frames cannot replace the confirmed number or erase its observed increase. The Dashboard shows a warning beside the retained value; a single new or uncertain number is never promoted to a confirmed reading. A macro that stops or fails still does not publish partial collection results. Exported Activity logs include each jewel’s live OCR text, parsed count, confidence and failure reason to distinguish live-capture failures from Detect only results.

Each jewel uses its own baseline within that collection. Two fresh, consecutive, confident reads must agree. A positive difference is the observed amount added, not independent deposit proof. An unchanged number shows **Not confirmed** for amount added. An unreadable row keeps its previous value and timestamp with **Previous reading**, while readable rows still update. Interrupted collections publish no partial results. No extra clicks, retries or bank reopening are introduced.

If Dashboard shows **No reading yet**, open the bank and run **Calibration → Capture snapshot → Detect only**. Check `bankTitle` first. Detect only exposes each jewel's raw OCR even when the header does not match, while keeping that reading blocked from balance updates. Each failed Dashboard row and Activity entry now explains whether the bank was not recognized, the number was empty/low-confidence, its format was wrong, processing was still visible, the frame was stale, or only one matching read was captured. Redraw the relevant region or fix its numeric format based on that evidence. If Detect only reads correctly, lengthen the recorded pauses before deposit and before closing the bank. Live capture continues to skip jewel OCR outside a recognized bank.

When Detect only succeeds but playback never recognizes the bank, use **Dashboard → Test live bank reading (5 seconds, no clicks)**. Open the bank manually, click the test, then focus the selected game during the countdown and keep the bank open. This uses the same selected window, profile, focus checks and recognition mode as live recorded banking, but sends no input and does not modify collection totals. Expand **Live bank recognition details** to inspect the actual focused-game header crop, best observed score against the saved threshold, header OCR and jewel samples. The expandable captured game window helps identify layout/zoom changes. The same details are captured during ordinary workflows; exported logs include the best live bankTitle score.

If the focused-game header OCR correctly reads `Jewel bank` but its saved-image score fails, select `bankTitle` in Calibration, enter `Jewel bank` as its OCR phrase, click **Use OCR only**, then **Save as startup default**. This explicitly removes that target's image template while preserving its region, threshold, other targets and named jewel regions. Both detection paths then require that phrase in the calibrated region at the saved threshold. It does not relax recognition globally or bypass bank recognition. Image matching remains available by redrawing the header. Mac validation of focused capture still requires the actual game window.

Existing single-balance profiles remain supported through `bankBalanceText` and **Workflows → Numeric format**. Named rows use their own formats. Named balances do not replace `bankBalanceText` if you selected `bankBalanceIncrease` as the image workflow's transfer-verification method; keep that verification target or use your existing valid alternative. Exact regions require calibration on your Mac. Linux tests validate the tracking logic, not Apple Vision accuracy against the real game.

## Calibration

Start with the [jewel-banking calibration guide](docs/CALIBRATION-GUIDE.md), then add Helper, skills and recovery for full automation. Calibration now groups targets in workflow order, explains what to mark for every label, and shows the targets required by the currently selected mode and options. Changing a label loads that target's own OCR/threshold settings. Editing either field immediately updates that saved target in memory; Save as startup default or Save named profile persists it without redrawing. Use image only clears an optional phrase for the selected target. The selected region is highlighted and previewed beside its saved template, and detection rows show each target's expected phrase, actual OCR, raw score and threshold.

1. In Calibration, allow Screen Recording, refresh windows, and make open.mu the active tab and select its Chrome window.
2. Capture a snapshot or enable live preview. Freeze preview before marking targets.
3. Label `gameViewport` around only the game area. Label controls and state indicators from real examples, using separate screenshots for different dialogs/states. No game coordinates or shortcuts are prefilled.
4. Drag regions to create local grayscale templates; optionally enter OCR text. In strict recognition, both template and text must match when both are configured. Relaxed state/evidence detection uses the saved image when present, except numeric proof and configured recovery phrases use OCR. Optional non-recovery OCR text does not override a valid image match. Relaxed control clicks use their saved positions. Thresholds are adjustable. Save the calibration as the startup default or as a named profile. Named profiles can be loaded from the menu; saving the default separately controls what loads at launch.
5. Capture fresh positive and negative examples and run Detect only. Inspect templates, scores, OCR and classification. Confirm the review on Dashboard. Calibration/window changes invalidate that confirmation.
6. Calibrate banking targets including separate Transfer and excluded Withdraw, pending Processing, a reliable success indicator, and close controls. Strict recognition also requires normal gameplay and interruption states (disconnect, login, character selection, loading, death and respawn). Full-mode modules add helper/recovery/route prerequisites. Start reports missing targets.

If a click lands away from the button, select that control in Calibration and choose **Set click from game cursor (5 seconds)**. Focus the selected game and hover the actual button until the countdown ends; no input is sent while measuring. Save the profile. This changes only the click position, preserving all recognition rectangles, templates and other labels. On Dashboard, **Test inventory click only (5 seconds)** sends one inventory click without any banking actions. Expand **Last click and captured game** to compare before/after frames and panel scores. Live clicks move the pointer first, wait 60 ms, press for 50 ms, then release; they recheck focus and the window under the point before pressing. Frames stay in memory, and activity logs include attempted coordinates and raw scores.

A screenshot of Processing is not proof of transfer. Select a newly appearing success indicator, a decreasing inventory count, or an increasing reliable bank balance in Workflows. For numeric verification, calibrate inventoryCountText or bankBalanceText around exactly one count and select digits-only, comma-grouped, or space-grouped format. Parsing rejects labels, malformed grouping, decimals and OCR uncertainty. Unchanged counts remain unverified, including when there are no eligible jewels. Validate the chosen signal against the actual game; a changing count is not proof that every jewel category transferred.

Templates compare calibrated regions; they do not search the entire screen. Moved dialogs, browser zoom changes, fullscreen transitions, same-aspect-ratio layout changes, and effects may invalidate them. Recalibrate rather than lower thresholds to force a match.

## Inventory, skills and routes

Inventory estimates require `emptyInventoryGrid` calibrated on an actually empty item grid. Set row/column counts, capture the occupied grid, and detect. Occupancy and jewel-sample matching are diagnostics with uncertainty reporting; they are not transfer evidence. Automated banking uses the separate `bankingTrigger` indicator, without repeatedly opening inventory to inspect it.

Skills are ordered unmodified macOS virtual key taps with delays, optional cooldowns (zero disables cooldown), and optional visual checks. They do not support held keys or modifier chords. Verify actual shortcuts in the game; no game shortcuts are supplied.

Record inputs captures user clicks, key holds and pauses only in the selected focused window. Recorded return routes use stable spawn detection and a final destination check; older routes can retain before/after checkpoints for each step. A route replay test performs movement only and stops after verifying the destination; it never starts the helper. It requires full mode and the same explicit live gates. Confirm manual replay validation before enabling automated recovery. Route edits invalidate validation. Ten checkpoint labels are available in addition to map/destination targets. Recorded routes retain holds and timing. Drags, modifiers and simultaneous controls are not supported; checkpoint routes continue to wait for visual checkpoints.

## Safety and logging

- One task serializes all input. Each action checks cancellation, permissions, focus, window identity and fresh evidence. Image workflows also require their visual preconditions; recorded playback uses the saved points and timing within the bound window. After the focus countdown, the selected ScreenCaptureKit window ID is bound to its public Accessibility window identity and active document. Display titles are not used as identity. Focusing another game window suspends input even if it has the same title/URL; returning to the bound game automatically continues the same session. The original document URL must remain unchanged; browsers exposing an outer web-area identity also detect tab replacement/reload at the same URL.
- Focus loss keeps the active session alive in **Waiting for game focus**. No new mouse/key presses are sent while another window has focus. Playback delays, macro hours, verification and route/session timeouts pause while waiting; the selected window/page is checked again and a fresh frame is captured before continuing. A press already delivered before focus changed is released and never repeated; a partially completed hold advances to the next input. Input recording itself still stops on focus loss.
- **Auto refocus and resume**, available on Dashboard and in Workflows, is optional and defaults off. Choose **30 minutes**, **1 hour**, or custom minutes before Start. After that much time paused, unfocused, or since the last automation input, it restores and raises the retained selected game window and continues the active session. This can resume Manual Pause. The timer uses elapsed real time while paused/backgrounded; normal playback delays still apply. Failed temporary focus attempts wait another configured interval. Completed, stopped or failed sessions are never restarted.
- Window disappearance, changed tab/page, unexpected states, revoked permissions or unverified outcomes stop execution for manual intervention.
- Transfer and helper actions are single-shot. Ambiguous outcomes are never automatically retried. Detection polling and recovery attempts are bounded by configured limits; maximum action retries remain an upper cap, not a promise to repeat mutations.
- Pause prevents subsequent actions until Resume or the enabled auto-refocus timer. Emergency Stop cancels the task and pending startup. The global stop chord is Control–Option–Command–Escape; pause/resume is Control–Option–Command–P. Verify both on macOS. Dashboard Resume waits five seconds so you can refocus the game. Already delivered events cannot be retracted.
- The Activity tab shows transitions, actions, evidence, confidence, elapsed time, polls, and failures; logs can be exported manually.

Configuration, workflow settings, regions and small templates are saved in `~/Library/Application Support/MUAutomator/`. Full capture frames remain in memory. The app has no network backend, credential storage or automatic screenshot upload. Reference fixtures in this repository came from the supplied recording.

## Validation in this cloud environment

The portable core built successfully and all 107 portable XCTest tests passed with official Swift 6.0.3 in Docker:

```sh
docker run --rm --network none -v "$PWD":/src -w /src \
  swift:6.0.3-jammy@sha256:b394f699c1844fabf5c01d8a5673639141dc007f500661a4fa56f4ba1f23d87b \
  swift test -j 2
```

On Linux the Swift package intentionally exposes only the core library/test target. macOS includes the executable and additional adapter tests. Linux tests cannot prove Apple framework compilation or gameplay. macOS CI configuration is provided but has not been run here. See [acceptance checks](docs/ACCEPTANCE.md) and [recording review](docs/GAMEPLAY-REFERENCE.md).

The game URL is `https://open.mu/versions/20261006042155/index.html`. Cloud access currently fails at the network proxy with CONNECT 403. An `open.mu` allowlist addition was saved in the environment draft; review/save it in environment settings and publish before retrying. Additional game-service destinations may become apparent only after the page loads.

Cloud tasks are already isolated: use the existing checkout; do not create a Git worktree unless explicitly requested.

## If the app stops responding

The supplied macOS 26.0 process sample showed an AttributeGraph dependency cycle while SwiftUI's `StatefulTabContainer` reinserted a screen's accessibility tree, spending most samples printing cycle diagnostics. Navigation now uses ordinary buttons and mounts only the selected screen, removing the native `TabView` path from that sample. Configuration and calibration stay in the app-owned models. Workflow shutdown follows the owning window's close notification instead of root-view disappearance.

The Dashboard renders cached permission status; privacy-service queries run off the main actor. Leaving Calibration freezes its preview while retaining the last frame. The navigation workaround still requires verification on macOS 26.0; Linux checks cannot establish that the hang is resolved.

If a hang persists, capture a process sample while the app is still frozen, before force-quitting:

```sh
sample MUAutomator 5 -file /tmp/MUAutomator-hang.txt
```

Alternatively use Activity Monitor → MUAutomator → Sample Process. The main-thread call graph identifies the blocking operation; include it when reporting a hang. A process sample is different from a crash report because a hung process has not exited.

## Only open.mu windows are listed

The picker verifies the active document URL through public macOS Accessibility metadata. It accepts HTTPS on the exact `open.mu` host (default port or 443), including versioned game paths. Other domains, misleading titles/links, inactive game tabs, and unreadable URLs are excluded. No browser tab is switched automatically. Make the game the active tab, grant Accessibility using the Calibration button, then refresh. Chrome is the primary target; other listed browsers work only when they expose the required active-document metadata. Capture rechecks the URL; live automation rechecks the focused browser URL before each input operation. No AppleScript, browser extension, private browser API, or extra network request is used.

Discovery reads the browser application's Accessibility role to activate Chromium's native accessibility support, then retries an initially empty web tree within a bounded background lookup. Each window gets its own document-search budget within an eight-second per-browser limit. Discovery matches unique window bounds within the same process, so a stale/different title from ScreenCaptureKit no longer hides an otherwise identifiable game window. Overlapping windows with indistinguishable bounds remain excluded; move them apart and refresh. Live input separately checks the bound AX window identity, selected document, focus and layout.

The details below the picker now explain each excluded window: an Accessibility error, unmatched/ambiguous bounds, a missing document URL, an origin other than HTTPS open.mu, or a search limit. If Chrome is still missing after rebuilding, copy those details from Calibration. They omit page URLs and titles.

Chromium documents its lazy activation in [the application role getter](https://github.com/chromium/chromium/blob/main/chrome/browser/chrome_browser_application_mac.mm) and [the web-content container role getter](https://github.com/chromium/chromium/blob/main/content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm). Actual Chrome/macOS interoperability still needs local acceptance testing.

## If the window menu is empty

1. Open **System Settings → Privacy & Security → Screen & System Audio Recording** (or **Screen Recording** on older macOS).
2. Enable the **MU Automator** app you are actually launching. Accessibility permission and Chrome's own permissions do not grant MU Automator screen capture access.
3. Fully quit and reopen that app bundle, then click **Calibration → Allow capture / Refresh windows**. If necessary, use the settings panel's add button to select `.build/xcode/Build/Products/Release/MUAutomator.app` in your checkout.
4. Click **Allow Accessibility for URL detection** and enable MU Automator if needed. Make `https://open.mu` the active tab in Chrome, refresh, and select its window. Discovery includes other Spaces; restore/show the game before capture or live automation.

Use the same `.app` consistently instead of switching between Xcode, `swift run`, and different copies. Rebuilding an ad-hoc signed bundle can invalidate an existing permission grant; reapprove the rebuilt app if needed. Permission is still enforced by macOS. The app now attempts ScreenCaptureKit discovery rather than rejecting it solely on a legacy precheck, and reports returned-window counts or the native error domain/code below the controls.

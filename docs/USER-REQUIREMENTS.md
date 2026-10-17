# MU AUTOMATOR — FULL SOFTWARE ENGINEERING MASTER PROMPT

## 1. ROLE AND EXPECTATIONS

Act as a principal macOS software engineer and automation architect with 20+ years of software development experience.

You specialize in:
- Swift and SwiftUI
- Apple Silicon and native macOS applications
- ScreenCaptureKit and Vision
- Computer vision and OCR
- macOS Accessibility and permitted mouse/keyboard automation
- State machines, asynchronous programming, cancellation, and fault recovery
- XCTest, software architecture, and production-quality debugging

Your task is to design, implement, test, and document a complete native macOS application called **MU Automator**.

Work as an experienced engineer who prioritizes correctness, maintainability, observability, and safety over rushing to produce a large amount of code.

Do not merely provide a conceptual architecture. Implement the application incrementally, produce actual source files, build and test the project where tools permit, and help resolve compiler errors.

Never claim that code compiles or a feature works unless it has actually been verified.

---

## 2. PROJECT OVERVIEW

### Application name

MU Automator

### Target platform

- macOS
- Apple Silicon: M1, M2, M3, M4, and newer compatible chips
- Native Swift and SwiftUI
- Minimum deployment target: macOS 14, unless a documented technical requirement justifies another target
- Primary game environment: MU Online running in a browser
- Initial browser target: Google Chrome
- Initial game interface: the supplied OpenMU browser-game screenshots and screen recording

### Main objective

Build a configurable automation application that assists with repetitive MU Online gameplay tasks through visual recognition and permitted user-interface automation.

The app must coordinate the entire farming routine:

1. Open the inventory.
2. Open the Jewel bank.
3. Transfer all eligible jewels into the bank.
4. Verify the transfer and close the appropriate windows.
5. Open MU Helper settings.
6. Start the helper and verify that it is running.
7. Monitor gameplay.
8. Detect possible death, respawn, disconnection, or other interruptions.
9. Confirm the character has respawned.
10. Return the character to the configured farming spot.
11. Restart MU Helper.
12. Verify that normal farming has resumed.
13. Continue monitoring and repeat recovery when necessary.

The automation must be state-driven, not a blind macro that repeatedly clicks fixed coordinates.

Use only supported screen capture, accessibility, and input mechanisms. Do not use process injection, unauthorized memory manipulation, anti-cheat evasion, or private game APIs. Make the automation configurable and respect the rules of the selected game server.

---

## 3. REFERENCE MATERIAL

Use the provided files as visual and behavioral references:

- Screenshot 1: MU Online with the inventory open.
- Screenshot 2: Jewel bank dialog with the "Transfer all to bank" button.
- Screen recording: the user's normal routine, including inventory access, jewel banking, MU Helper, map selection, gameplay, and recovery-related transitions.

The recording demonstrates the sequence of actions but does not necessarily prove the exact internal state of the game at every moment.

Extract and document:
- The visible controls.
- The order in which the user activates them.
- The relevant UI states.
- Which transitions can be detected visually.
- Which actions need additional user calibration.
- Which behaviors cannot be determined from the recording alone.

Do not invent coordinates, keyboard shortcuts, game commands, teleport behavior, or death-detection signals that have not been verified.

Create a visual calibration workflow so the user can confirm all important UI targets on the actual running game.

---

## 4. CORE PRODUCT REQUIREMENTS

### A. Native macOS dashboard

Create a clean, professional SwiftUI application with the following sections:

**Dashboard**
- Current application state.
- Selected game/browser window.
- Current automation workflow.
- Screen-capture and input-permission status.
- Current game-state classification.
- Last completed action.
- Last detected error.
- Start, Pause, Resume, and Emergency Stop controls.

**Jewel Banking**
- Enable/disable toggle.
- Open-inventory procedure.
- Jewel-bank detection.
- Transfer button calibration.
- Transfer verification settings.
- Configurable action timeout.
- Configurable retry limit.
- Optional banking triggers.

**MU Helper**
- Enable/disable toggle.
- Helper window detection.
- Start Helper button calibration.
- Configurable activation timeout.
- Verification that the helper has actually started.

**Death Recovery**
- Enable/disable toggle.
- Death detection configuration.
- Respawn detection configuration.
- Recovery timeout.
- Maximum recovery attempts.
- Return-to-spot route configuration.
- Verification before restarting farming.

**Skill Rotation**
- Configurable keyboard actions.
- Adjustable timing and sequence order.
- Optional cooldowns.
- Start/pause/stop controls.
- Focus-loss safeguards.

**Inventory Monitoring**
- Inventory-state detection.
- Configurable visual conditions.
- Optional banking trigger.
- Detection confidence and error reporting.

**Visual Calibration**
- Live screenshot preview.
- Window and region selection.
- Visual target selection.
- Template creation and preview.
- OCR diagnostics.
- Detection confidence.
- Dry-run testing.

**Activity Log**
- Timestamped actions.
- State transitions.
- Detection results.
- Retry attempts.
- Timeouts.
- Errors.
- Recovery history.

### B. Global safety controls

Implement:
- An emergency stop that cancels all active workflows.
- Pause on loss of game-window focus.
- Pause when the target window disappears.
- Pause on missing permissions.
- Pause on unknown or ambiguous game states.
- Maximum action and workflow durations.
- Bounded retry counts.
- Cancellation checks between actions.
- No overlapping workflows.
- No infinite click loops.
- No automatic continuation after an unverified failure.

The emergency stop must prevent further scheduled input actions as promptly as practical.

Do not promise that an emergency stop can retract an input event that has already been delivered to the operating system.

---

## 5. TECHNICAL STACK

Use native Apple frameworks wherever practical.

### User interface
- Swift
- SwiftUI
- Combine or Swift concurrency as appropriate

### Screen capture
- ScreenCaptureKit
- Window identification and capture where supported
- Permission checks and useful failure messages

### Visual recognition
- Vision framework
- VNRecognizeTextRequest for OCR where appropriate
- Image-template matching for distinctive buttons and UI regions
- Core Image or a lightweight custom image-matching implementation
- Configurable confidence thresholds
- Temporal confirmation across multiple frames when needed

### Input
- Core Graphics event APIs or supported macOS Accessibility APIs, as appropriate
- Explicit permission checks
- Keyboard and mouse input restricted to configured workflows
- No input when the target window is unknown or unsafe

### Persistence
- JSON configuration for the initial implementation
- Local persistence for visual templates and user-defined routes
- Versioned configuration schema
- Safe defaults and migration handling

### Testing
- XCTest
- Unit tests for state transitions
- Mock capture and input services
- Screenshot-based visual-recognition tests
- Integration tests for workflow orchestration
- Manual acceptance tests against the actual game

Avoid third-party dependencies unless there is a clear engineering reason to use them.

Do not use Electron or require a Python runtime for the application.

---

## 6. REQUIRED ARCHITECTURE

Keep the system modular, with clear boundaries between UI, perception, decision-making, and input.

Recommended components:

### Application layer
- `MUAutomatorApp`
- `ContentView`
- `DashboardView`
- `JewelBankView`
- `HelperSettingsView`
- `RecoverySettingsView`
- `CalibrationView`
- `ActivityLogView`

### Models
- `AutomationState`
- `GameState`
- `WorkflowState`
- `AutomationConfiguration`
- `ActionConfiguration`
- `VisualTarget`
- `DetectionResult`
- `RecoveryRoute`
- `ActivityEntry`

### Services
- `CaptureService`
- `VisionService`
- `OCRService`
- `TemplateMatchingService`
- `GameStateDetector`
- `WindowSelectionService`
- `InputController`
- `ConfigurationStore`
- `ActionLogger`

### Workflow layer
- `AutomationCoordinator`
- `JewelBankWorkflow`
- `HelperWorkflow`
- `InventoryMonitoringWorkflow`
- `DeathRecoveryWorkflow`
- `ReturnToSpotWorkflow`
- `SkillRotationWorkflow`

Use protocols for capture, input, and detection dependencies where this improves testability.

Inject mock implementations into tests so workflow behavior can be verified without sending real mouse or keyboard events.

Avoid giant view files, giant coordinator classes, global mutable state, and tightly coupled business logic.

---

## 7. GAME-STATE MODEL

Create a typed representation of known visual states.

At minimum, support:

- `unknown`
- `browserLoading`
- `loginScreen`
- `characterSelection`
- `normalGameplay`
- `inventoryOpen`
- `jewelBankOpen`
- `warpWindowOpen`
- `helperWindowOpen`
- `helperRunning`
- `possibleDeath`
- `respawnScreen`
- `disconnected`
- `loadingTransition`

The state detector must return more than a bare enum when appropriate.

Include:
- Detected state.
- Confidence score.
- Evidence or matched visual targets.
- Capture timestamp.
- Optional recognized text.
- Whether the state is safe for the next action.

Do not infer death from low health, disappearing character sprites, or combat effects alone.

Do not treat a loading screen, login screen, disconnect screen, and death screen as interchangeable.

Require multiple independent visual indicators or temporally stable observations for high-impact decisions such as initiating recovery.

When the state is uncertain, pause and log the uncertainty.

---

## 8. WORKFLOW 1 — JEWEL BANKING

This is the first feature to implement and validate.

### Reference dialog

The supplied screenshot shows:
- A modal titled "Jewel bank".
- Jewel categories and quantities.
- A "Transfer all to bank" button.
- A "Withdraw" button.

### Required workflow

1. Confirm the selected game window.
2. Capture a fresh screenshot.
3. Detect whether the inventory is open.
4. If necessary, open the inventory through a calibrated control.
5. Detect the configured jewel-bank control.
6. Activate the control once.
7. Confirm that the Jewel bank dialog is open.
8. Detect the correct transfer button.
9. Verify the target is not the Withdraw button.
10. Record the current visual state.
11. Activate Transfer all to bank once.
12. Wait for the interface to settle.
13. Capture another screenshot.
14. Compare the pre-action and post-action evidence.
15. Determine whether the result is successful, unsuccessful, or uncertain.
16. Retry only when the result is safe and retry conditions are satisfied.
17. Close the dialog and inventory only after the workflow's exit conditions are met.
18. Log the result.

### Verification requirements

Do not assume that bank balances must change after every transfer. Bank totals and inventory counts are different quantities.

Use the most reliable observable success indicator available after testing the actual game.

Possible evidence includes:
- A change in inventory item count.
- A change in inventory grid occupancy.
- A change in a reliable bank balance.
- A confirmation message.
- A change in button or dialog state.

If no reliable success indicator is available, report "unverified" rather than falsely claiming success.

### Retry policy

- Retry count must be configurable.
- Retry delay must be configurable.
- Use bounded retries.
- Never click the transfer button continuously.
- Never activate Withdraw during deposit.
- Pause if the dialog disappears unexpectedly.
- Stop if the selected window changes.
- Do not perform additional clicks while the previous action's outcome remains uncertain.

---

## 9. WORKFLOW 2 — MU HELPER

The user's routine includes opening the MU Helper interface and activating the visible "START HELPER" button.

### Required behavior

1. Detect normal gameplay.
2. Locate the configured helper control or keyboard shortcut.
3. Open the helper settings.
4. Verify the expected helper window is present.
5. Detect the Start Helper button.
6. Activate the button once.
7. Wait for a visual state change.
8. Confirm the helper appears active using a calibrated indicator.
9. If the helper is already running, do not toggle it off.
10. If the state is uncertain, pause rather than repeatedly clicking.

The exact helper-running indicator must be established using the actual game.

Do not assume that opening helper settings proves the helper is running.

Do not assume that a button changes state unless verified.

---

## 10. WORKFLOW 3 — SKILL ROTATION

Add skill automation only after the banking and helper workflows are stable.

Support:
- User-defined keyboard shortcuts.
- User-defined action order.
- Adjustable delays.
- Optional cooldown timers.
- Optional repeated sequences.
- Cancellation checks.
- Pause on focus loss.
- No input when the game is disconnected or the state is unknown.
- Optional visual verification for important actions.

Prefer keyboard shortcuts when they are confirmed to work reliably in the target game.

Do not invent shortcuts or assume a skill was activated just because an event was sent.

Provide a visible editor for action sequences.

---

## 11. WORKFLOW 4 — INVENTORY MONITORING

Monitor the inventory using calibrated visual indicators.

Support:
- Inventory open/closed detection.
- Item-grid occupancy estimates where visually reliable.
- Detection of configured jewel types when recognizable.
- Configurable banking triggers.
- Cooldowns between banking attempts.
- Optional manual approval before the first live transfer.

Do not rely solely on fixed inventory coordinates if the window or interface can move.

Avoid repeated opening and closing of the inventory when no action is necessary.

If inventory recognition is unreliable, report low confidence rather than guessing.

---

## 12. WORKFLOW 5 — DEATH DETECTION AND RESPAWN

The user wants the character to recover from death and resume farming.

### Detection

Identify and calibrate actual visual indicators for:
- Character death.
- Respawn or revival.
- Loading transitions.
- Disconnection.
- Login or character selection.
- Normal gameplay.

Use multiple indicators when possible.

Do not trigger death recovery solely because the character is temporarily hidden by combat effects, another character, or an animation.

### Recovery sequence

1. Detect a possible death.
2. Pause the skill rotation.
3. Stop nonessential interactions.
4. Gather additional visual evidence.
5. Confirm death or respawn state.
6. Wait for a verified respawn.
7. Determine the current map and approximate location if feasible.
8. Select the appropriate recovery route.
9. Execute the configured route.
10. Verify the destination.
11. Open MU Helper.
12. Start the helper if it is not already running.
13. Verify that normal farming has resumed.

### Recovery failure

If respawn is not detected within the configured timeout:
- Stop the recovery attempt.
- Record the last known state.
- Show an understandable error.
- Wait for manual intervention or an explicitly configured retry.

Never issue unlimited movement commands or repeated teleport actions.

---

## 13. WORKFLOW 6 — RETURN TO FARMING SPOT

The user refers to a Dop4 map and a path through the respawn area to the normal farming spot.

The exact map identifiers, coordinates, teleport procedure, and movement commands have not yet been verified.

Do not invent them.

### Route configuration

Implement a user-configurable route model that can eventually support:
- A known map or destination identifier.
- A documented, supported teleport or map-selection action.
- Recorded keyboard and mouse movement sequences.
- Checkpoints.
- Timeouts.
- Optional visual landmark recognition.
- Maximum route duration.
- Cancellation.
- Manual recovery.

If the game offers a reliable supported teleport mechanism, prefer it over long recorded movement sequences.

If only recorded movement is available, allow the user to record the actual path from respawn to farming spot.

### Route verification

At route completion:
1. Confirm that the expected game scene is visible.
2. Check configured visual landmarks where available.
3. Check that the character is at or near the expected location when reliable visual evidence exists.
4. Do not resume farming merely because a timer expired.
5. Pause if the destination cannot be verified.

Provide a calibration and replay-testing mode before enabling automated movement.

---

## 14. MASTER AUTOMATION STATE MACHINE

Create an explicit orchestration state machine.

Suggested high-level states:

- `idle`
- `initializing`
- `selectingWindow`
- `checkingPermissions`
- `preparingInventory`
- `openingJewelBank`
- `transferringJewels`
- `verifyingBanking`
- `closingInventory`
- `openingHelper`
- `startingHelper`
- `verifyingHelper`
- `farming`
- `possibleDeath`
- `waitingForRespawn`
- `selectingRecoveryRoute`
- `returningToSpot`
- `verifyingLocation`
- `restartingHelper`
- `paused`
- `waitingForManualIntervention`
- `disconnected`
- `failed`
- `completed`
- `cancelled`

Define valid state transitions explicitly.

For every transition, specify:
- Required evidence.
- Preconditions.
- Timeout.
- Action to perform.
- Success criteria.
- Failure behavior.
- Retry policy.

Prevent two workflows from sending conflicting inputs simultaneously.

A global coordinator should serialize game actions or use a carefully designed action scheduler.

---

## 15. SCREEN CAPTURE AND VISUAL CALIBRATION

Implement screen capture before live automation.

### Capture requirements

- Enumerate eligible windows.
- Let the user select the correct browser/game window.
- Capture frames through supported APIs.
- Display the captured frame in the app.
- Handle missing or revoked permissions.
- Handle window closure and resize.
- Avoid unnecessarily recording or storing the entire desktop.

### Calibration requirements

Allow the user to select and label:
- Inventory control.
- Jewel-bank control.
- Jewel bank title region.
- Transfer all to bank button.
- Withdraw button as an explicitly excluded target.
- Inventory item-grid region.
- Helper control.
- Helper window.
- Start Helper button.
- Warp window.
- Map-selection targets.
- Death and respawn indicators.
- Farming-spot landmarks.

Support saving calibration profiles.

Use window-relative coordinates where appropriate, and account for scaling, resolution, and window movement.

Use image matching and OCR where they improve robustness.

Do not assume a visual template remains valid after substantial UI changes.

Show a detection confidence score and allow the user to inspect the match.

---

## 16. PERMISSIONS AND INPUT SAFETY

Request macOS permissions only when needed.

Handle:
- Screen Recording permissions.
- Accessibility permissions if required for the selected input strategy.
- Missing permissions.
- Permission revocation.
- Browser window changes.
- Window focus loss.
- Fullscreen transitions.
- Capture failure.

Explain why each permission is required.

Do not request unrelated permissions.

Do not send live input until:
1. The user has selected the correct window.
2. Visual calibration has passed.
3. Dry-run detection has been reviewed.
4. The user has explicitly enabled live automation.

Ensure the emergency stop cancels scheduled and future actions.

Do not attempt to bypass macOS security restrictions.

---

## 17. CONFIGURATION AND PERSISTENCE

Store configuration locally.

Include:
- Selected workflow modules.
- Dry-run setting.
- Action delays.
- Timeouts.
- Retry limits.
- Visual target definitions.
- Detection thresholds.
- Skill sequences.
- Recovery routes.
- Logging preferences.

Requirements:
- Safe defaults.
- Schema versioning.
- Validation on load.
- Sensible recovery from invalid or outdated configuration.
- No hard-coded credentials.
- No unnecessary cloud services.
- No automatic transmission of screenshots or game data to external services.

Store only the information necessary for the automation.

---

## 18. OBSERVABILITY AND DEBUGGING

Every important operation must be logged.

Log fields should include:
- Timestamp.
- Workflow name.
- Previous state.
- New state.
- Detection evidence.
- Confidence.
- Action attempted.
- Result.
- Retry number.
- Duration.
- Error details.

Provide a recent-activity panel.

Optionally save diagnostic screenshots only when the user enables them, and explain what is stored.

Avoid logging secrets or unrelated desktop content.

Make it possible to determine why the automation clicked, paused, retried, or stopped.

---

## 19. TESTING STRATEGY

Create unit tests before introducing live input.

### State-machine tests
- Valid state transitions.
- Invalid transition rejection.
- Cancellation.
- Timeout.
- Retry exhaustion.
- Unknown state handling.
- Disconnect handling.
- Emergency stop behavior.

### Jewel-bank tests
- Bank dialog correctly detected.
- Transfer button correctly identified.
- Withdraw button rejected.
- Dialog-closed behavior.
- Ambiguous detection.
- Successful verification.
- Unverified outcome.
- Retry limits.

### Helper tests
- Helper already running.
- Helper inactive.
- Start button missing.
- State transition after activation.
- Timeout and cancellation.

### Death recovery tests
- Death confirmed.
- False-positive death.
- Respawn confirmed.
- Disconnect instead of respawn.
- Recovery timeout.
- Route failure.
- Destination verification failure.
- Successful recovery.

### Screenshot tests
Use the supplied screenshots as initial fixtures, and add further labeled screenshots captured from the target game.

Test different window positions, sizes, visual effects, and partially obscured UI states.

### Integration tests
Use mock implementations of capture, detection, and input services.

Verify that no real input is sent during automated tests.

Create a manual acceptance-test checklist for actual Chrome and MU Online use.

---

## 20. IMPLEMENTATION PHASES

Do not implement the entire system in one unverified code dump.

### Phase 1 — Foundation
- Create the Xcode project.
- Implement SwiftUI dashboard.
- Add configuration models.
- Add typed state models.
- Add coordinator and logging.
- Add unit tests.
- Confirm the app builds.

### Phase 2 — Screen capture
- Add ScreenCaptureKit.
- Implement window selection.
- Display screenshot previews.
- Add permission handling.
- Validate capture and resize behavior.

### Phase 3 — Visual calibration
- Add target selection and template storage.
- Detect inventory and Jewel bank dialog.
- Identify Transfer all to bank.
- Exclude Withdraw.
- Add confidence reporting and dry-run mode.
- Test with the supplied screenshots.

### Phase 4 — Jewel-bank workflow
- Implement the complete banking state machine.
- Add bounded retries.
- Add visual verification.
- Test on the actual game.
- Enable live input only after explicit confirmation.

### Phase 5 — MU Helper
- Detect helper settings.
- Detect Start Helper.
- Activate once.
- Verify the active state.
- Integrate with the coordinator.

### Phase 6 — Inventory and skill rotation
- Add inventory monitoring.
- Add configurable skill sequences.
- Add focus-loss safeguards.
- Add optional triggers.

### Phase 7 — Death detection
- Calibrate death and respawn indicators.
- Distinguish loading, disconnection, login, and death states.
- Add confirmation logic.
- Add recovery timeouts.

### Phase 8 — Return to farming spot
- Implement configurable route recording.
- Add map-selection support after calibration.
- Add route checkpoints and destination verification.
- Test recovery without automatically restarting farming until the route is validated.

### Phase 9 — Full orchestration
- Combine banking, helper, farming, and recovery.
- Prevent overlapping actions.
- Add failure recovery and emergency stop.
- Run the full manual acceptance-test suite.

### Phase 10 — Packaging and release
- Configure Apple Silicon builds.
- Verify permissions and entitlements.
- Add an app icon and basic documentation.
- Document installation and troubleshooting.
- Sign and notarize the app if distribution requires it.

---

## 21. ENGINEERING RULES

Follow these rules throughout implementation:

1. Build incrementally and keep the project compiling.
2. Use modern Swift concurrency where appropriate.
3. Keep UI code separate from workflow logic.
4. Use typed models rather than unstructured strings for internal state.
5. Avoid force unwraps in production code.
6. Avoid arbitrary sleeps as the primary synchronization mechanism.
7. Prefer condition-based waits with timeouts and cancellation.
8. Use bounded retries.
9. Do not repeat irreversible or potentially harmful actions without verification.
10. Do not assume an input event guarantees a successful game action.
11. Do not guess game-specific commands, coordinates, or shortcuts.
12. Do not claim that screenshots prove a state they do not show.
13. Do not add unnecessary dependencies.
14. Do not add a network backend unless a clear requirement emerges.
15. Do not skip tests because the UI appears to work.
16. Explain any important limitation or unresolved assumption.
17. Provide complete source files when requested, not isolated snippets that cannot be integrated.
18. State exactly where each file belongs.
19. Give precise Xcode build and test instructions.
20. Never claim to have run tests on the user's computer.

If an API is deprecated or unavailable for the deployment target, select a supported alternative and explain the decision.

---

## 22. DEFINITION OF DONE

The project is not considered complete merely because the dashboard exists.

The final application must demonstrate:

- Reliable selection of the correct game window.
- Working screen capture.
- Calibrated visual detection.
- Safe jewel transfer with meaningful verification.
- Correct MU Helper activation.
- Inventory monitoring.
- Configurable skill rotation.
- Death detection with false-positive safeguards.
- Respawn handling.
- A configurable return-to-spot route.
- Destination verification.
- Automatic helper restart after successful recovery.
- Bounded retries and timeouts.
- Emergency stop.
- Useful diagnostic logs.
- Automated tests.
- Successful manual validation against the target game.
- Clear documentation of limitations and supported environments.

If a behavior cannot be reliably detected, the app must expose that limitation and pause rather than pretend the task succeeded.

---

## 23. IMMEDIATE TASK FOR THE CODING AGENT

Start with Phase 1 and do not jump ahead.

First:
1. Inspect the available project files, if any.
2. Confirm the Xcode project structure.
3. Establish the state models and configuration.
4. Implement the initial SwiftUI dashboard.
5. Implement the coordinator and logging.
6. Add unit tests.
7. Build and test when the environment permits.
8. Fix compilation and test failures before continuing.

Then explain the result and identify the exact next step: ScreenCaptureKit integration and visual calibration.

Do not implement live game input in Phase 1.

**Primary engineering objective: build a reliable, observable, state-driven macOS automation system that follows the user's actual gameplay routine, verifies every important transition, and fails safely when the game state is uncertain.**
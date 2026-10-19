# Calibration from window selection to jewel banking

Get the **jewel-banking option** working first, then add the other full-automation modules. Banking opens inventory and the bank, deposits jewels already in inventory, verifies the transfer, and closes both panels. Ground looting is handled by the game’s MU Helper in full automation; configure item/jewel looting inside the actual game Helper first. No loot rules or jewel coordinates are supplied by the app.

For a banking-first test in **Full automation**, enable jewel banking in Workflows, turn off Helper, skill sequence and death recovery, and turn off “Monitor calibrated banking-trigger indicator.” The first bank transfer still runs; afterward full mode keeps monitoring gameplay until you press Stop. Enable the later modules only after their calibration and local tests are complete. The separate Jewels only mode uses the same bank routine and stops after banking, but changing modes is not necessary to follow this guide.

## Record actions instead of labeling buttons

Use **Record inputs → Jewel workflow** for the simplest banking setup. Select the game window, start recording, focus it and wait for the beep. Perform the whole deposit sequence yourself, release all controls, then stop with **Control–Option–Command–R**. Review waits/holds in Workflows and Save settings. Restore the same starting panel state before playback. Before Start, choose Macro repeats on Dashboard: Once, a total number of runs, or hours, with an optional delay between cycles. The recording should finish ready to start again. Hours exclude paused time and finish the current cycle before stopping; repeat mode uses its own limit rather than the general session timeout. Return-route playback still runs once per recovery. Recorded inputs use real window-relative positions and timing; inventory/bank image targets are not required. Playback completion does not prove the jewels transferred. The original image workflow below remains available by selecting Calibrated image workflow in Workflows.

For **Return to spot**, record movement from spawn to the farming location. Keep recovery OCR for `deathIndicator`, independent `deathConfirmation`, `respawnIndicator`, and `destinationLandmark`; these phrases are used even in relaxed mode. After stable spawn detection the app replays the route and waits for the destination label. Individual recorded inputs do not need before/after image checkpoints. Existing checkpoint routes are preserved. Enabled Helper or skill modules can still add visual requirements.

Keep browser dimensions, zoom and layout consistent. Recording stores left clicks, one unmodified key/control at a time, holds and pauses, with no drags. Recording does not send input. Stop/Emergency Stop remains available during playback; pending inputs are not retried. These native input behaviors require local macOS acceptance testing.

## Work through these screens in order

1. Open Chrome with `https://open.mu` as the active tab. Keep the window size and browser zoom consistent. In Calibration, grant Screen Recording and Accessibility, refresh windows, and select the game window. Window discovery needs no target labels.
2. With the game alive and normal dialogs closed, capture a snapshot and freeze preview. Label `gameViewport` and `inventoryControl`. `normalGameplay` is optional in the default relaxed recognition mode; label it if you enable Strict gameplay recognition on Dashboard.
3. Manually open inventory and capture a new snapshot. Label `inventoryPanel`, `bankControl`, and `inventoryClose`.
4. Manually open the Jewel Bank and capture a new snapshot. Label `bankTitle`, `transferButton`, `withdrawExcluded`, and `bankClose`. Keep Transfer separate from the entire excluded Withdraw button.
5. Use genuine examples of a manual transfer to label `processingIndicator` and a reliable success signal. In Workflows, choose **one** verification method: `newSuccessIndicator` → `transferSuccess`; `inventoryCountDecrease` → `inventoryCountText`; `bankBalanceIncrease` → `bankBalanceText`. The bank must remain visible during verification. Numeric regions contain only one count in the selected numeric format. A static bank title, Processing, dialog closure or unchanged count is not transfer proof.
6. Capture real interruption screens to label `disconnected`, `loginScreen`, `characterSelection`, `browserLoading`, `loadingTransition`, `deathIndicator`, and `respawnIndicator`. All seven are required when Strict gameplay recognition is enabled. They are optional for a banking-first test in relaxed recognition; configured interruption labels still block input when they match. Recovery adds its own required death/respawn evidence when enabled. They are separate examples, not features to find in one normal screenshot. Do not substitute ordinary HUD features for missing interruption examples.
7. Save as startup default (or save a named profile). Capture fresh positive and negative examples and run Detect only. When normal gameplay is visible, interruption labels must not match; in the bank, bankTitle must match while Helper/Warp titles must not. Not every label should match every screenshot. Moving dialogs, changing zoom or resizing invalidates region matching and requires rechecking/recalibration.
8. Return to Dashboard and click Confirm I reviewed dry-run detection. For a live run, enable jewel banking, turn Dry run off and explicitly allow live input. Click Start in 5 seconds and focus the game. The bank routine opens inventory → opens bank → clicks Transfer once → verifies a new success signal/count change → closes bank → closes inventory. Full automation then continues monitoring; press Stop after confirming the banking-first test. An uncertain transfer stops for manual inspection.

With banking enabled and other modules disabled, default relaxed recognition requires **11 labels**: `gameViewport`, nine inventory/bank/processing/closure labels, and one selected success-proof label. Strict gameplay recognition requires **19 labels**, adding `normalGameplay` and seven interruption labels. Label presence is only a checklist item; Detect only review still has to establish that the labels work on real game states. Templates use a fixed window-relative region, so capture each target from the screen where it actually appears.

## Editing labels and checking OCR

Select a target to load its own OCR phrase and threshold. Changes immediately update that target in memory; Save as startup default or Save named profile writes them to disk. Existing rectangles do not need redrawing. Switching labels or loading a profile refreshes the editor from the selected target, so settings do not carry over between labels. If an older profile already contains an unwanted phrase, select that label and edit it or choose Use image only, then save.

The yellow outline and current-crop preview show exactly which saved region is being inspected. Compare that crop with the saved template and the per-label expected phrase, actual OCR, raw score and threshold. Repeated text is possible when different state labels cover the same screen area; target names do not make different pixels. Numeric proof labels always use OCR from their own crop and do not use a fixed expected phrase. Each OCR crop is rendered into its own bitmap; phrase confidence uses the lines containing the requested phrase rather than unrelated low-confidence OCR lines.

In default relaxed recognition, measured cursor positions (when set) or saved control rectangle centers determine click positions even if button OCR or image matching fails. State/evidence labels use their saved image when available; an old optional phrase does not override the image match. OCR-only labels and numeric counts still use OCR. Live runs skip optional OCR work for image-backed labels, while Detect only can show their actual OCR for diagnosis. Inventory and bank state evidence still determine sequencing, and the chosen transfer proof must still verify success. Brief missing state detections are polled within the action timeout; an uncertain transfer is never clicked again. Strict recognition retains per-button recognition and immediate bank-disappearance checks.

## If a click lands in the wrong place

The inventory-panel timeout means the panel was not recognized after the click; it does not identify whether clicking or recognition failed. First use Dashboard → **Test inventory click only (5 seconds)** with live input allowed and focus the selected game during the countdown. This sends one click and may open or close inventory; it never transfers jewels. Expand **Last click and captured game** to see the attempted window/screen coordinates, before/after frames and inventory/bank scores with their thresholds.

If the click position is wrong, select `inventoryControl` in Calibration and choose **Set click from game cursor (5 seconds)**. Focus the same game and hover the real inventory button until the countdown ends. This measures the actual global cursor position in the selected window, without sending a click or depending on the screenshot's padding. Save the profile. Recognition regions, templates, OCR and every other label stay unchanged. Repeat for another click control only if needed. **Use rectangle center** removes the override for that control. Changes invalidate the Dashboard detection review as usual.

Clicks now send pointer movement before the press, allow 60 ms for browser/game pointer processing, hold for 50 ms, and release even when cancelled. Focus and the top window under the intended point are checked before movement and again before the press. These changes need local macOS/game validation; the screenshots alone do not prove the cause of the misplaced click. No capture-geometry migration or threshold changes are applied to existing profiles.

## Every target label

“Click” means the measured cursor position, or the marked rectangle center when no override is set, can receive input. “State”, “Proof” and “Trigger” regions identify visual evidence. The whole game area bounds clicks. Optional route evidence becomes required if it is used by an enabled route or skill.

### 1 · Game area & normal play

| Label | Purpose | What to mark |
| --- | --- | --- |
| `gameViewport` — Game area | Area | Draw around the entire playable game canvas, including every game button the workflow will click. Exclude Chrome tabs, the address bar and browser controls. This bounds clicks; it is not a gameplay-state indicator. |
| `normalGameplay` — Normal gameplay | State | Optional in relaxed recognition. While alive and playing with inventory and other dialogs closed, mark a distinctive, stable HUD feature that identifies normal play. Avoid moving monsters, effects, changing numbers and featureless background. |

### 2 · Open inventory

| Label | Purpose | What to mark |
| --- | --- | --- |
| `inventoryControl` — Open inventory | Click | With inventory closed, mark the visible inventory button or icon tightly enough that its center is safe to click. The workflow clicks it once when normal gameplay is verified. |
| `inventoryPanel` — Inventory is open | State | Manually open inventory, capture a new snapshot, then mark its unique title or fixed panel decoration. Avoid item slots: their contents change. This confirms opening and later closing inventory. |

### 3 · Open bank & transfer

| Label | Purpose | What to mark |
| --- | --- | --- |
| `bankControl` — Open jewel bank | Click | With inventory open, mark the actual Jewel Bank button or icon used by this game version. Its center must be safe to click. No bank shortcut or position is assumed. |
| `bankTitle` — Jewel bank is open | State | Manually open the Jewel Bank and mark its unique title or fixed header. It must distinguish this dialog from Helper and Warp. The bank must remain visible while transfer success is verified. |
| `transferButton` — Transfer / deposit jewels | Click | Mark only the actual Transfer or Deposit button in the open bank. Its center must be inside the game area and outside the Withdraw exclusion. One click is sent; an uncertain result is never retried automatically. |
| `withdrawExcluded` — Withdraw — excluded area | Exclude | Cover the entire Withdraw button and its clickable edges in the open bank. Keep it separate from Transfer. Automated clicks are rejected inside this region; this target is never clicked. |

### 4 · Verify the transfer

| Label | Purpose | What to mark |
| --- | --- | --- |
| `processingIndicator` — Transfer is processing | State | From an actual pending transfer, capture the Processing text or spinner and mark its distinctive region. Processing means wait, not success. Do not label a permanent bank heading as processing. |
| `transferSuccess` — New transfer success message | Proof | Use only with newSuccessIndicator verification. Mark a real success message or indicator that is absent before transfer and newly visible afterward while the bank stays open. A static bank title or Processing label is not proof. |
| `inventoryCountText` — Inventory jewel count | OCR proof | Alternative to a success message: choose inventoryCountDecrease in Workflows. Mark exactly one reliable numeric jewel count that is readable before and after transfer and decreases afterward. Exclude labels, icons and other numbers; select its numeric format in Workflows. |
| `bankBalanceText` — Bank jewel balance | OCR proof | Alternative to a success message: choose bankBalanceIncrease in Workflows. Mark exactly one reliable numeric bank balance that is readable before and after transfer and increases afterward. Exclude labels, icons and other numbers; select its numeric format in Workflows. |

### 5 · Close bank & inventory

| Label | Purpose | What to mark |
| --- | --- | --- |
| `bankClose` — Close jewel bank | Click | With the bank open, mark its own close button or X. Its center must be safe to click. After verified transfer, the workflow closes the bank and confirms inventory remains open. |
| `inventoryClose` — Close inventory | Click | With inventory open and the bank closed, mark the inventory close button or X. After closing, the workflow must see normal gameplay and no inventory panel. |

### 6 · Interruption states — strict recognition / recovery

| Label | Purpose | What to mark |
| --- | --- | --- |
| `disconnected` — Disconnected | Stop state | Capture the actual disconnected or connection-lost dialog and mark its unique message. A match stops the workflow for manual intervention. Use a real example, not an ordinary HUD region. |
| `loginScreen` — Login screen | Stop state | Capture the actual game login screen and mark a unique title or fixed login-screen feature. This distinguishes logged-out state from normal play and blocks input. |
| `characterSelection` — Character selection | Stop state | Capture the actual character-selection screen and mark a unique heading or control that is absent during gameplay. Do not label the character model itself if it moves. |
| `browserLoading` — Browser / page loading | Blocked state | Capture a real browser or game-page loading state and mark its distinctive loading indicator in the captured window. It must be absent from settled gameplay; a matching loading state blocks input. |
| `loadingTransition` — Game loading transition | Blocked state | Capture the actual in-game map or scene loading transition and mark a unique loading message or graphic. Distinguish it from normal play, bank Processing and browser-page loading. |
| `deathIndicator` — Character is dead | Blocked state | Capture an actual death screen and mark its distinctive death message or overlay. Low health and combat effects alone are not death evidence. Banking stops on death; full-mode recovery also needs deathConfirmation. |
| `respawnIndicator` — Character has respawned | State | Capture the actual post-respawn state and mark a distinctive respawn/location indicator that is absent before death. An ordinary HUD element that is always visible will misclassify normal play as respawn. |

### 7 · Full mode: MU Helper

| Label | Purpose | What to mark |
| --- | --- | --- |
| `helperControl` — Open MU Helper | Click | Full mode with Helper enabled: while playing normally, mark the game control that opens Helper settings. Do not assume a keyboard shortcut. |
| `helperPanel` — Helper settings are open | State | Full mode with Helper enabled: open Helper manually and mark its unique settings-panel title or header. Distinguish it from the bank and Warp dialog. |
| `helperStart` — Start MU Helper | Click | Full mode with Helper enabled: mark the actual Start control inside Helper settings. The workflow clicks it only when the separate helperRunning indicator is absent. |
| `helperRunning` — MU Helper is running | State | Full mode with Helper enabled: mark a real active/running indicator visible after Helper starts and the settings panel closes. The Start button itself is not running-state evidence. Configure jewel looting inside the game Helper. |

### 8 · Full mode: monitoring & optional diagnostics

| Label | Purpose | What to mark |
| --- | --- | --- |
| `bankingTrigger` — Time to bank again | Trigger | Full mode with inventory monitoring enabled: mark a reliable visible condition that means another banking run is needed, such as an actual full-inventory warning. It triggers banking after the cooldown; occupancy estimates alone do not trigger it. |
| `emptyInventoryGrid` — Empty inventory grid baseline | Diagnostic | Optional: empty the actual item grid, capture it, and mark the whole grid without its title, buttons or equipment slots. Set the correct row/column counts. Later snapshots are compared against this empty baseline to estimate occupancy. |
| `jewelSample` — Example jewel item | Diagnostic | Optional: capture a known jewel in inventory and mark one item cell as a sample. Sample matches are uncertain diagnostics, not proof of jewel type, complete collection or successful transfer. |
| `inventoryGrid` — Inventory grid reference | Optional | Optional reference region around the item-slot grid. Current occupancy estimates use emptyInventoryGrid and jewelSample instead; inventoryGrid alone does not count items or trigger banking. |

### 9 · Recovery & travel

| Label | Purpose | What to mark |
| --- | --- | --- |
| `deathConfirmation` — Independent death confirmation | State | Full mode with recovery enabled: mark a second, independent death-only feature, such as a genuine revive control. It must agree with deathIndicator across fresh frames. Do not reuse the same rectangle or low-health indicator. |
| `destinationLandmark` — Farming destination reached | State | For recovery or route replay: at the real farming destination, mark a stable, unique location landmark or location text. Route completion requires this marker before Helper can restart; strict recognition also requires normalGameplay. |
| `warpPanel` — Warp / travel dialog | State | For routes that use travel: open the actual Warp dialog and mark its unique title or header. The app can recognize this state but does not choose a map or build a route automatically. |
| `mapControl` — Open map / travel | Route click | Optional route target: mark the actual map or travel button only if your configured route clicks it. Record and verify the real route; no map action is added merely by labeling this target. |
| `mapDestination` — Choose map destination | Route click | Optional route target: with the correct map/travel dialog open, mark the actual destination control your route should click. Labeling it does not select a destination automatically; add it to a verified route. |

### 10 · Optional route checkpoints

| Label | Purpose | What to mark |
| --- | --- | --- |
| `routeCheckpoint` — Route checkpoint 1 | Route evidence | Optional checkpoint 1: mark a stable scene feature used as a before/after condition in your recorded route. If you assign this role as a click target, its center must also be a safe clickable location inside the game area. |
| `routeCheckpoint2` — Route checkpoint 2 | Route evidence | Optional checkpoint 2: mark a stable scene feature used as a before/after condition in your recorded route. If you assign this role as a click target, its center must also be a safe clickable location inside the game area. |
| `routeCheckpoint3` — Route checkpoint 3 | Route evidence | Optional checkpoint 3: mark a stable scene feature used as a before/after condition in your recorded route. If you assign this role as a click target, its center must also be a safe clickable location inside the game area. |
| `routeCheckpoint4` — Route checkpoint 4 | Route evidence | Optional checkpoint 4: mark a stable scene feature used as a before/after condition in your recorded route. If you assign this role as a click target, its center must also be a safe clickable location inside the game area. |
| `routeCheckpoint5` — Route checkpoint 5 | Route evidence | Optional checkpoint 5: mark a stable scene feature used as a before/after condition in your recorded route. If you assign this role as a click target, its center must also be a safe clickable location inside the game area. |
| `routeCheckpoint6` — Route checkpoint 6 | Route evidence | Optional checkpoint 6: mark a stable scene feature used as a before/after condition in your recorded route. If you assign this role as a click target, its center must also be a safe clickable location inside the game area. |
| `routeCheckpoint7` — Route checkpoint 7 | Route evidence | Optional checkpoint 7: mark a stable scene feature used as a before/after condition in your recorded route. If you assign this role as a click target, its center must also be a safe clickable location inside the game area. |
| `routeCheckpoint8` — Route checkpoint 8 | Route evidence | Optional checkpoint 8: mark a stable scene feature used as a before/after condition in your recorded route. If you assign this role as a click target, its center must also be a safe clickable location inside the game area. |
| `routeCheckpoint9` — Route checkpoint 9 | Route evidence | Optional checkpoint 9: mark a stable scene feature used as a before/after condition in your recorded route. If you assign this role as a click target, its center must also be a safe clickable location inside the game area. |
| `routeCheckpoint10` — Route checkpoint 10 | Route evidence | Optional checkpoint 10: mark a stable scene feature used as a before/after condition in your recorded route. If you assign this role as a click target, its center must also be a safe clickable location inside the game area. |

Full mode adds the Helper targets only when Helper is enabled, plus recovery/destination and every configured route/skill evidence target when those modules are enabled. `bankingTrigger` is needed for repeated banking from the farming monitor, although the current Start preflight does not require it. `emptyInventoryGrid`, `jewelSample` and `inventoryGrid` are optional diagnostics/reference regions; they are not required for a single jewels-only deposit. Travel and route labels do not build or activate a route on their own.

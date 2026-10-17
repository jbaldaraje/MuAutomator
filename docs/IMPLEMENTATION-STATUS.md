# Prompt audit and completion status

The implementation is **not accepted as complete** against the supplied definition of done. 48 portable XCTest tests passed with Swift 6.0.3 in the pinned official Docker image; macOS compilation, permission behavior, capture alignment, live input and actual-game outcomes have not been validated here. Nineteen macOS adapter tests are present but remain unrun here, including three window-close lifecycle checks and six browser-discovery regression checks and five selected-window binding checks using mocked metadata. Apple-framework sources passed Swift syntax parsing; Xcode project OpenStep syntax, scheme XML, Info.plist, source membership and shell syntax were checked. These are not macOS compilation. The user supplied a macOS 26.0 hang sample showing a native SwiftUI tab reinsertion/accessibility dependency cycle. The native tab container has been replaced with selected-screen navigation; the workaround still needs local reproduction testing.

| Prompt area | Source implemented | Evidence / remaining gate |
| --- | --- | --- |
| Native project and dashboard | Swift package, Xcode app project, dashboard/settings/calibration/route/log views | Linux syntax parsing only for Apple-framework sources; macOS build required |
| Modes | Jewels-only isolation; full mode respects modules; relaxed recognition defaults on old/new settings; strict recognition opt-in; locked active configuration | Mock banking with missing gameplay labels, strict rejection, interruption gating, full-mode monitoring and route isolation tests pass |
| Capture | Only active HTTPS open.mu browser windows are listed, with URL checks before capture/input; Chromium AX activation/retries, unique geometry matching, snapshots, preview, per-window diagnostics | Host parsing tests pass; mocked browser-discovery tests added but unrun; native URL discovery and capture still require macOS verification |
| Calibration | Workflow-ordered descriptions for all 44 labels, current-options checklist shared with Start requirements, relative regions, templates/OCR, exclusion, preview, JSON save/load | Six guide/requirements regression tests and bank-title crop tests pass; native guide UI and Vision tests still require macOS verification |
| Banking | Visual preconditions, single transfer, pending/success distinction, strict OCR count/balance deltas, bounded verification, verified panel closure | Mock end-to-end, stale success, disappearance and unverified outcome tests pass; actual success indicator not yet established |
| Helper | Detect active first, start once, verify active state | Mock active/inactive/missing-button paths pass; real active indicator needs calibration |
| Inventory | Panel detection, empty-grid comparison, sample matching diagnostics, visual banking trigger and cooldown | Core estimate tests pass; effects/resolution robustness and live empty-grid baseline unverified |
| Skill rotation | Ordered key taps, delay/cooldown, optional evidence, repeat setting, focus/cancellation gates | Core cooldown/cancellation test; actual shortcuts unconfigured |
| Death/respawn | Independent death evidence across frames, stable respawn, bounded attempts and waits | False-positive and timeout tests pass; no labeled actual death/respawn reference yet |
| Return route | User tap recorder, ordered editable steps, checkpoints, time cap, destination verification, movement-only replay test | Mock success/failure and helper restart tests pass; actual route unconfigured and unvalidated |
| Safety | Serialized task, fresh frames, retained AX window/document identity, selected URL/focus/bounds checks, viewport restriction, excluded Withdraw, explicit live gates, cancellation | Core tests pass; five mocked window-binding checks added but unrun; OS-level input/focus/hotkey behavior requires macOS tests |
| Configuration/logging | Validated versioned JSON, legacy region decoding, safe defaults, evidence/state/action logs and export | Core persistence/validation tests pass; app UI save/load/export unverified |
| Packaging | Apple Silicon Xcode target, build script, icon generator, local ad-hoc signing and signature check, macOS CI definition | Files provided; no macOS build/sign/CI run yet; distribution signing/notarization not performed |

## Scope limits that must stay visible

- Region matching pauses when layouts move; automatic whole-window target relocation is not implemented.
- Transfer supports a newly appearing success indicator or a calibrated OCR count/balance delta. None is established as reliable for the actual game yet. Unchanged or unreadable counts remain unverified; no transfer is repeated automatically.
- Grid occupancy/sample recognition is diagnostic and may be uncertain; it is not a verified general jewel classifier and does not imply all eligible items were deposited.
- Keyboard actions are taps, without modifiers/holds. Route recording does not capture drags or movement duration. Landmark-gated clicks/map selections must suffice for a configured route; otherwise a supported movement primitive must be added.
- Mutating actions are never automatically repeated on uncertain outcomes. Safe negative-result-based action retries are not implemented. Detection polling has time bounds and recovery has a count bound.
- Named calibration profiles and a startup default are implemented; profile UI persistence still requires macOS acceptance testing.
- No automatic map/location inference, game commands, coordinates or shortcuts are supplied.
- Some UI-specific safety failures terminate in waiting-for-manual-intervention rather than offering automatic resume. New runs require explicit acknowledgment of unresolved results.

## External validation blockers

This machine is Linux. Apple frameworks, Xcode and real macOS permissions cannot be executed here. The supplied game URL is additionally blocked by the environment's proxy (CONNECT 403), before game HTTP content is retrieved. The `open.mu` domain and reusable Linux test setup/start instructions were saved to the environment configuration draft; saving did not apply or publish them.

Review/save the draft in environment settings and publish to activate the configuration. Once the game loads, verify its actual network destinations and login requirements without sharing credentials in chat. Then perform the macOS and actual-game acceptance checks. Until those pass and the outstanding scope limits are resolved as needed for the actual routine, do not call this full gameplay automation complete.

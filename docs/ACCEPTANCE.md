# macOS and actual-game acceptance

Run these checks on macOS 14+ with Xcode and the actual selected Chrome game window. Record outcomes and exported logs. Do not mark unrun checks passed.

## Build and permission checks

- Run `swift test -j 2`. On macOS this includes `MacAdapterTests` and compiles the executable. Run `bash scripts/build-macos.sh`; verify an Apple Silicon `.app` is produced and its ad-hoc signature check passes.
- Launch the built app. Deny Screen Recording and verify an actionable error with no screenshot. Grant access, relaunch if requested, select the correct Chrome window and verify capture matches it.
- Test Retina scaling, resizing, window movement and browser zoom. Freeze preview, label regions, save/relaunch, and inspect alignment. Clear/recalibrate after layout changes.
- Switch Calibration → Dashboard repeatedly, both with preview off and while preview is running. Verify preview freezes when leaving Calibration, Dashboard stays responsive, and permission status updates without resetting the layout every second. Repeat with Screen Recording denied and granted.
- Verify Accessibility is requested only through the live-input button. Revoke either permission during a workflow; verify subsequent input stops.
- Change Chrome tabs, close the target, select another Chrome window and focus another application. Verify no further action is delivered to the replacement target.
- Test Emergency Stop, its global chord, cancellation during countdown and waits, and closing the app window. Check no subsequent scheduled action fires. Already delivered events are outside cancellation control.

## Detection review

- Calibrate gameViewport to exclude browser chrome. Capture separate positive and negative examples for every required state/control.
- Reject false bank matches against helper/warp/loading screens. Verify Withdraw is excluded and overlapping Transfer/Withdraw regions block Start.
- Verify helper settings and helper-running indicators are distinct. Verify normal gameplay, death, respawn, loading, disconnect, login and character selection are not conflated.
- Label actual death and respawn examples; combat effects and low health alone must not initiate recovery.
- Review Detect only output and scores with no input. Change any calibration/window selection and verify a new review is required.

## Jewels only

- Begin with known eligible jewels and capture before-state evidence. Calibrate either a real new-success signal or a reliable numeric count/balance region. Select the matching verification mode and count format; verify OCR against known values. If no reliable signal exists, keep live banking blocked.
- With explicit live consent, start jewels-only mode. Verify inventory and bank open, Transfer is clicked once, Processing is treated as pending, success is verified, panels close and the run stops.
- Leave helper/recovery/skill switches enabled from full mode and repeat. Confirm none of those modules execute in jewels-only mode.
- Test zero eligible jewels, stalled Processing, an already visible success message, unexpected dialog closure and a missing Transfer button. Each ambiguous outcome must stop without a second transfer or a Withdraw click.

## Full routine

- Test helper inactive then already active. Confirm exactly one Start event for inactive and zero toggles for active; require the real running indicator.
- Configure actual verified key codes, order, delay and cooldown. Confirm sequences pause/stop with the workflow, do not run on unknown/death/disconnect states, and respect cooldown.
- Test calibrated banking trigger and cooldown without repeatedly opening inventory for polling. Validate empty-grid diagnostics against known counts; retain uncertain results as uncertain.
- Record the real return route. Assign each checkpoint and calibrate the destination. Run movement-only replay; verify it ends at the destination without starting helper. Make an edit and verify validation is cleared.
- Enable recovery only after verified route replay. Test false-positive death, confirmed death, verified respawn, respawn timeout, route failure, destination mismatch and disconnect during recovery.
- Confirm no helper restart on failed route/destination checks; confirm helper restarts and normal farming is verified after successful recovery.
- Test maximum session duration and recovery-count limits. Export the activity log and confirm action reasons, evidence and failure context are present.

Distribution signing/notarization is separate from these development acceptance checks and is not performed by the local ad-hoc build script.

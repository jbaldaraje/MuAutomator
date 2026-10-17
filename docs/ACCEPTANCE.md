# macOS and actual-game acceptance

Run these checks on macOS 14+ with Xcode and the actual selected Chrome game window. Record outcomes and exported logs. Do not mark unrun checks passed.

## Build and permission checks

- Run `swift test -j 2`. On macOS this includes `MacAdapterTests` and compiles the executable. Run `bash scripts/build-macos.sh`; verify an Apple Silicon `.app` is produced and its ad-hoc signature check passes.
- Launch the built app. Deny Screen Recording and verify an actionable error with no screenshot. Grant access, relaunch if requested, select the correct Chrome window and verify capture matches it.
- Confirm the window menu lists only browser windows with an active HTTPS open.mu document, including eligible windows on other Spaces. Other websites, a page merely titled open.mu, and an inactive open.mu tab must not be listed. Switch the selected browser to another website and verify capture/live input stops. Deny Accessibility and verify the URL-permission explanation appears. Restore the selected game before capturing/live automation. If enumeration fails, verify its native error domain/code appears; if it succeeds with no candidates, verify the empty-list explanation appears.
- Quit/relaunch Chrome with no screen reader running, open the game tab, then refresh Calibration. Verify the cold Accessibility tree populates and the game is listed. Repeat with several browser windows and while the game title changes during loading. Confirm per-window diagnostics explain exclusions; move identically positioned browser windows apart and refresh to resolve an ambiguous bounds match. A page containing only an open.mu link or iframe must stay excluded. Do not count these checks as passed based on the mocked tree tests.
- Test Retina scaling, resizing, window movement and browser zoom. Freeze preview, label regions, save/relaunch, and inspect alignment. Clear/recalibrate after layout changes.
- On macOS 26.0, switch Calibration → Dashboard at least 20 times using the navigation buttons, both with preview off and while preview is running. Also visit Workflows, Record route and Activity. Verify preview freezes when leaving Calibration, saved model edits/selected window/calibration survive navigation, Dashboard stays responsive, and the console does not flood with AttributeGraph cycle diagnostics. Repeat with Screen Recording denied and granted. This checks the native TabView reinsertion workaround against the supplied hang sample.
- Verify Accessibility is requested only through the live-input button. Revoke either permission during a workflow; verify subsequent input stops.
- Change Chrome tabs, close the target, select another Chrome window and focus another application. Verify no further action is delivered to the replacement target.
- Keep three Chrome game windows open with the same title and URL, give them distinguishable bounds, and select one in Calibration. Start and focus that exact window during the countdown. Verify a display-title difference/change does not require recalibration. Focus either other game window during a run and confirm no further input is sent. Switch/reload the selected tab (including another tab at the same URL when Chrome exposes a web-area identity) and confirm the run stops. Test route recording with the same window selection. These are native acceptance checks; mocked identity tests do not establish browser interoperability.
- Test Emergency Stop, its global chord, cancellation during countdown and waits, and closing the app window. Switching screens must not cancel a countdown or workflow; closing the owning app window must cancel it and stop preview/route recording. Closing an unrelated panel must not cancel it. Check no subsequent scheduled action fires. Already delivered events are outside cancellation control.

## Detection review

- In Calibration, verify all 44 target labels are grouped in workflow order and have descriptions. With Full automation selected and only banking enabled, verify the checklist requires 19 targets; switch the banking-proof option and verify the required proof changes. Enable Helper/recovery/skill evidence and verify their required targets appear. Select an existing target and verify its own OCR phrase and threshold load without changing the saved region. Label counts must not appear as proof of correct detection.
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

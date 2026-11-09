# MU Automator — Screen Macro

A small macOS 14+ app for recording and replaying mouse and keyboard actions across the whole desktop. No game setup, selected window, browser, calibration, OCR, or window queue.

## Use

1. Open the app and enable **Accessibility / Input Monitoring** when requested. This is input-action recording, not a video; Screen Recording permission is not required.
2. Click **Record in 5 seconds**, switch to your app, and wait for the beep. Perform the clicks, pointer movements, drags, scrolling and keyboard actions you want to repeat. Timings and desktop positions are captured.
3. Release your controls and press **Control–Option–Command–R** to finish. You can also return to the recorder and click **Finish recording**. Its own UI interactions are excluded. The new macro is saved automatically.
4. Enter **Run for … hours** (`0.5` means 30 minutes) and an optional **Repeat interval** in seconds. The interval is a pause after each complete replay (`0` repeats immediately; `60` waits one minute). Click **Play in 5 seconds**, and restore your starting desktop/app state during the countdown.
5. Playback repeats the whole recording until the hours are reached, then finishes the current replay. The countdown is excluded from the hours; repeat intervals are included. If the run time ends during an interval, no extra replay starts. **Stop**, or **Control–Option–Command–Escape**, cancels immediately and releases injected held keys/buttons. Escape during recording cancels the new recording and keeps the previous macro.

**Moving your mouse or switching windows does not pause or stop playback.** The next recorded event can move the shared pointer back, and keyboard events go to the desktop's currently focused app. The app does not provide a separate cursor or isolated background input. Restore the same desktop layout and starting app state before each run. Each macro should end in the state needed for the next cycle.

The app supports multiple displays using absolute Quartz desktop coordinates, including negative coordinates for displays above/left of the main screen. A changed display arrangement or revoked Accessibility permission stops playback; there are no game-window/focus/pointer-position gates. Mouse motion is sampled at up to 60 events per second. Recording is limited to one hour / 250,000 events. Keyboard presses, releases, repeats, modifier chords, left/right/other buttons, double clicks, drag paths, and line/pixel scrolling are represented as timed events. This is positional replay, not visual recognition, and macOS dispatch latency can affect timing.

Click **Hide** (top right) or close the app window to keep it running in the menu bar. The indicator shows **PLAY** with a play icon during replay, **WAIT** during the repeat interval, **REC** while recording, and **DONE**, **STOP**, or **ERROR** afterward. Status text and symbols remain useful even if macOS renders the icon without color. Click the indicator for live replay count, remaining run time, next-replay countdown, Show/Hide recorder and Stop controls. Reopen with **Show recorder**; use Quit to stop and exit. Playback never starts automatically at launch. **Open…** and **Save…** load/export macro JSON files. The app remembers the latest macro, hours and repeat interval in `~/Library/Application Support/MUAutomator/screen-macro.json` and `screen-macro-settings.json`. Recordings contain input actions (including key codes), so save/export them only where you intend to keep that data. There is no network backend or automatic upload.

## Updating from the game/window version

The previous calibration, bank-balance tracking, recovery, mascot, and multi-window queue have been removed from the app and replaced by this single-screen workflow. Their old Application Support files are left untouched. **Record a fresh desktop macro:** old window-relative recordings cannot be safely converted without their window's original desktop position. The previous hours preference is reused when available; it can be changed in the new Hours field.

## Build on your Mac

Install Xcode 15+ and select its command-line tools. From this checkout:

```sh
swift test -j 2
bash scripts/build-macos.sh
open .build/xcode/Build/Products/Release/MUAutomator.app
```

You can also open `MUAutomator.xcodeproj` and run the shared MUAutomator scheme, or `swift run MUAutomator`. Keep using the same app bundle when granting macOS permissions. The build script runs tests, builds an Apple Silicon app, creates its icon, ad-hoc signs and verifies the bundle. Distribution signing/notarization requires your own Apple identity.

## Validation

The core recording format, balanced input, timers, persistence, and playback cancellation can be tested on Linux with the official pinned Swift image:

```sh
docker run --rm --network none -v "$PWD":/src -w /src \
  swift:6.0.3-jammy@sha256:b394f699c1844fabf5c01d8a5673639141dc007f500661a4fa56f4ba1f23d87b \
  swift test -j 2
```

On Linux only the portable core tests run. macOS also builds the executable and tests native event conversion, absolute event positions, cleanup and window hiding. Real recording/replay, permissions, keyboard layouts, trackpad scrolling and hotkeys require Mac acceptance testing; Linux results cannot establish those work. See [acceptance checks](docs/ACCEPTANCE.md).

Cloud tasks are already isolated. Use this checkout; do not create a Git worktree unless explicitly requested.

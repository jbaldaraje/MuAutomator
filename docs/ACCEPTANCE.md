# Whole-desktop macro acceptance

Run these on macOS 14+ using the built app bundle. They have not been validated by Linux tests.

1. Grant Accessibility and, if macOS requests it, Input Monitoring. Verify global keyboard capture and both global stop chords; reopen the app after changing permissions if required. Screen Recording permission must not be needed.
2. Record a short, harmless sequence on the desktop or in a text editor: left/right clicks, double click, movement, drag, typing, Shift and Command chords, a held key, repeated keys, and scrolling. Stop with Control–Option–Command–R. Verify that the stop chord is absent from replay and that a deliberate tail wait is preserved.
3. Replay for a short decimal duration. Confirm actions and waits, complete repeated cycles, and completion of the current cycle when the time limit expires. Verify the countdown does not consume the chosen hours.
4. During replay, physically move the cursor and change the focused window. Neither action may pause or cancel playback. Confirm subsequent mouse actions use their recorded desktop positions. Keyboard input follows the desktop focus; this is intentional whole-desktop behavior.
5. Stop during a held mouse button, held key, countdown and tail wait, from the UI, menu bar and Control–Option–Command–Escape. Confirm release occurs immediately and no future cycle/event executes. Confirm permission revocation produces a clear error without retries.
6. Record/replay on a secondary display with a negative origin. Restore the same arrangement for playback; adding/removing/rearranging displays must stop or reject playback with a useful message.
7. Use both Hide and the close button during replay; verify it keeps running and can reopen from the menu bar. Check the indicator shows PLAY while replaying, WAIT between replays, REC while recording and DONE/STOP/ERROR afterward. Open its popover and confirm the replay count, remaining time, next-replay countdown and Stop control update correctly while the main window is hidden. Quit during a hold and verify the release occurs before process exit.
8. Save/open a JSON macro, relaunch and check autosave/hours restoration. Try a malformed macro and confirm the existing recording is retained. Old window/game profile files must remain unchanged, and no old positional macro should be silently migrated.

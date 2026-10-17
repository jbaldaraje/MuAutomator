# Gameplay reference review

Source: user-uploaded `a.mov`, 71.465 seconds, 640 × 412 pixels. Reviewed one-second sampled frames across the clip plus individual helper, bank, and warp frames. Timing below is approximate; this is visual evidence, not a record of keyboard/mouse events.

| Time | Observed interface | Implementation implication |
| --- | --- | --- |
| 0–1 s | MU HELPER dialog, green START HELPER button | Calibrate title, opening control, start button, and a separate active indicator. Closing the dialog does not prove activation. |
| 2–7 s | Gameplay with enemies and combat effects | Effects and character occlusion are normal; neither establishes death. |
| 8–13 s | Inventory panel on right, equipment above item grid | Detect panel and grid separately; opening shortcut is not established. |
| 14–15 s | Jewel bank modal over inventory; Transfer all to bank left, Withdraw right | Distinguish buttons and exclude Withdraw from deposit targeting. At 15 s a Processing… message is visible; it is pending, not success. |
| 16–19 s | Bank closed, inventory remains visible; jewel-like items remain | Dialog closure alone does not prove all eligible jewels transferred. Item identity/count and post-transfer evidence require calibration. |
| 20–21 s | Jewel bank appears again; processing visible in sampled sequence | Do not infer a safe retry policy from repeated manual use. |
| 22–24 s | Inventory closes; Warp Command Window appears on left around 23 s, then disappears | Calibrate map selection and confirm destination separately. No shortcut or route is established. |
| 25–64 s | Changing character/scene positions, combat, bright effects and item labels | Useful movement reference; insufficient for a verified respawn-to-farming route or death detector. |
| 65–66 s | Background dimming followed by helper settings | Requires inspection of active state before invoking Start Helper. |
| 67–71 s | Gameplay, inventory, then Jewel bank near end | Banking recurs in the routine; an automatic trigger remains to be configured. |

## Saved reference frames

- [Helper at 0.5 s](reference/helper.png)
- [Bank at 15 s](reference/bank.png)
- [Warp list at 23 s](reference/warp.png)

These are source reference images, not labeled recognition tests or validated click templates. Coordinates must be calibrated against the selected live window and account for scale and browser chrome. Low-resolution text and quantities must not be treated as authoritative OCR ground truth.

## Required calibration

Inventory opener and panel, bank opener, modal title, transfer/withdraw regions, processing indicator, reliable transfer completion evidence, helper opener and running indicator, map entry and destination landmarks. Death, respawn, disconnection, and loading need separately labeled examples before enabling recovery.

Jewels-only mode means banking jewels already in inventory and stopping after verified completion; it does not include movement or ground-item pickup. Full automation remains gated on the configured modules' calibration and verification.

This review does not validate application execution, live input, or gameplay outcomes on the user's Mac.

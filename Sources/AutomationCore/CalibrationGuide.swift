import Foundation

public enum CalibrationTargetGroup: String, CaseIterable, Sendable {
    case setup = "1 · Game area & normal play"
    case inventory = "2 · Open inventory"
    case bank = "3 · Open bank & transfer"
    case verification = "4 · Verify the transfer"
    case closing = "5 · Close bank & inventory"
    case interruptions = "6 · Interruption states — strict recognition / recovery"
    case helper = "7 · Full mode: MU Helper"
    case monitoring = "8 · Full mode: monitoring & optional diagnostics"
    case recovery = "9 · Recovery & travel"
    case route = "10 · Optional route checkpoints"
}

public struct CalibrationTargetGuide: Sendable {
    public let title: String
    public let kind: String
    public let group: CalibrationTargetGroup
    public let instruction: String
}

public extension TargetRole {
    /// Teaching order only; saved raw values and region coordinates are unchanged.
    static var calibrationOrder: [TargetRole] {
        [.gameViewport, .normalGameplay, .inventoryControl, .inventoryPanel, .bankControl, .bankTitle, .transferButton, .withdrawExcluded, .processingIndicator, .transferSuccess, .inventoryCountText, .bankBalanceText, .bankClose, .inventoryClose, .disconnected, .loginScreen, .characterSelection, .browserLoading, .loadingTransition, .deathIndicator, .respawnIndicator, .helperControl, .helperPanel, .helperStart, .helperRunning, .bankingTrigger, .emptyInventoryGrid, .jewelSample, .inventoryGrid, .deathConfirmation, .destinationLandmark, .warpPanel, .mapControl, .mapDestination, .routeCheckpoint, .routeCheckpoint2, .routeCheckpoint3, .routeCheckpoint4, .routeCheckpoint5, .routeCheckpoint6, .routeCheckpoint7, .routeCheckpoint8, .routeCheckpoint9, .routeCheckpoint10]
    }

    var calibrationGuide: CalibrationTargetGuide {
        switch self {
        case .gameViewport:
            return .init(title: "Game area", kind: "Area", group: .setup,
                         instruction: "Draw around the entire playable game canvas, including every game button the workflow will click. Exclude Chrome tabs, the address bar and browser controls. This bounds clicks; it is not a gameplay-state indicator.")
        case .normalGameplay:
            return .init(title: "Normal gameplay", kind: "State", group: .setup,
                         instruction: "While alive and playing with inventory and other dialogs closed, mark a distinctive, stable HUD feature that identifies normal play. Avoid moving monsters, effects, changing numbers and featureless background.")
        case .inventoryControl:
            return .init(title: "Open inventory", kind: "Click", group: .inventory,
                         instruction: "With inventory closed, mark the visible inventory button or icon tightly enough that its center is safe to click. The workflow clicks it once when normal gameplay is verified.")
        case .inventoryPanel:
            return .init(title: "Inventory is open", kind: "State", group: .inventory,
                         instruction: "Manually open inventory, capture a new snapshot, then mark its unique title or fixed panel decoration. Avoid item slots: their contents change. This confirms opening and later closing inventory.")
        case .bankControl:
            return .init(title: "Open jewel bank", kind: "Click", group: .bank,
                         instruction: "With inventory open, mark the actual Jewel Bank button or icon used by this game version. Its center must be safe to click. No bank shortcut or position is assumed.")
        case .bankTitle:
            return .init(title: "Jewel bank is open", kind: "State", group: .bank,
                         instruction: "Manually open the Jewel Bank and mark its unique title or fixed header. It must distinguish this dialog from Helper and Warp. The bank must remain visible while transfer success is verified.")
        case .transferButton:
            return .init(title: "Transfer / deposit jewels", kind: "Click", group: .bank,
                         instruction: "Mark only the actual Transfer or Deposit button in the open bank. Its center must be inside the game area and outside the Withdraw exclusion. One click is sent; an uncertain result is never retried automatically.")
        case .withdrawExcluded:
            return .init(title: "Withdraw — excluded area", kind: "Exclude", group: .bank,
                         instruction: "Cover the entire Withdraw button and its clickable edges in the open bank. Keep it separate from Transfer. Automated clicks are rejected inside this region; this target is never clicked.")
        case .processingIndicator:
            return .init(title: "Transfer is processing", kind: "State", group: .verification,
                         instruction: "From an actual pending transfer, capture the Processing text or spinner and mark its distinctive region. Processing means wait, not success. Do not label a permanent bank heading as processing.")
        case .transferSuccess:
            return .init(title: "New transfer success message", kind: "Proof", group: .verification,
                         instruction: "Use only with newSuccessIndicator verification. Mark a real success message or indicator that is absent before transfer and newly visible afterward while the bank stays open. A static bank title or Processing label is not proof.")
        case .inventoryCountText:
            return .init(title: "Inventory jewel count", kind: "OCR proof", group: .verification,
                         instruction: "Alternative to a success message: choose inventoryCountDecrease in Workflows. Mark exactly one reliable numeric jewel count that is readable before and after transfer and decreases afterward. Exclude labels, icons and other numbers; select its numeric format in Workflows.")
        case .bankBalanceText:
            return .init(title: "Bank jewel balance", kind: "OCR proof", group: .verification,
                         instruction: "Alternative to a success message: choose bankBalanceIncrease in Workflows. Mark exactly one reliable numeric bank balance that is readable before and after transfer and increases afterward. Exclude labels, icons and other numbers; select its numeric format in Workflows.")
        case .bankClose:
            return .init(title: "Close jewel bank", kind: "Click", group: .closing,
                         instruction: "With the bank open, mark its own close button or X. Its center must be safe to click. After verified transfer, the workflow closes the bank and confirms inventory remains open.")
        case .inventoryClose:
            return .init(title: "Close inventory", kind: "Click", group: .closing,
                         instruction: "With inventory open and the bank closed, mark the inventory close button or X. After closing, the workflow must see normal gameplay and no inventory panel.")
        case .disconnected:
            return .init(title: "Disconnected", kind: "Stop state", group: .interruptions,
                         instruction: "Capture the actual disconnected or connection-lost dialog and mark its unique message. A match stops the workflow for manual intervention. Use a real example, not an ordinary HUD region.")
        case .loginScreen:
            return .init(title: "Login screen", kind: "Stop state", group: .interruptions,
                         instruction: "Capture the actual game login screen and mark a unique title or fixed login-screen feature. This distinguishes logged-out state from normal play and blocks input.")
        case .characterSelection:
            return .init(title: "Character selection", kind: "Stop state", group: .interruptions,
                         instruction: "Capture the actual character-selection screen and mark a unique heading or control that is absent during gameplay. Do not label the character model itself if it moves.")
        case .browserLoading:
            return .init(title: "Browser / page loading", kind: "Blocked state", group: .interruptions,
                         instruction: "Capture a real browser or game-page loading state and mark its distinctive loading indicator in the captured window. It must be absent from settled gameplay; a matching loading state blocks input.")
        case .loadingTransition:
            return .init(title: "Game loading transition", kind: "Blocked state", group: .interruptions,
                         instruction: "Capture the actual in-game map or scene loading transition and mark a unique loading message or graphic. Distinguish it from normal play, bank Processing and browser-page loading.")
        case .deathIndicator:
            return .init(title: "Character is dead", kind: "Blocked state", group: .interruptions,
                         instruction: "Capture an actual death screen and mark its distinctive death message or overlay. Low health and combat effects alone are not death evidence. Banking stops on death; full-mode recovery also needs deathConfirmation.")
        case .respawnIndicator:
            return .init(title: "Character has respawned", kind: "State", group: .interruptions,
                         instruction: "Capture the actual post-respawn state and mark a distinctive respawn/location indicator that is absent before death. An ordinary HUD element that is always visible will misclassify normal play as respawn.")
        case .helperControl:
            return .init(title: "Open MU Helper", kind: "Click", group: .helper,
                         instruction: "Full mode with Helper enabled: while playing normally, mark the game control that opens Helper settings. Do not assume a keyboard shortcut.")
        case .helperPanel:
            return .init(title: "Helper settings are open", kind: "State", group: .helper,
                         instruction: "Full mode with Helper enabled: open Helper manually and mark its unique settings-panel title or header. Distinguish it from the bank and Warp dialog.")
        case .helperStart:
            return .init(title: "Start MU Helper", kind: "Click", group: .helper,
                         instruction: "Full mode with Helper enabled: mark the actual Start control inside Helper settings. The workflow clicks it only when the separate helperRunning indicator is absent.")
        case .helperRunning:
            return .init(title: "MU Helper is running", kind: "State", group: .helper,
                         instruction: "Full mode with Helper enabled: mark a real active/running indicator visible after Helper starts and the settings panel closes. The Start button itself is not running-state evidence. Configure jewel looting inside the game Helper.")
        case .bankingTrigger:
            return .init(title: "Time to bank again", kind: "Trigger", group: .monitoring,
                         instruction: "Full mode with inventory monitoring enabled: mark a reliable visible condition that means another banking run is needed, such as an actual full-inventory warning. It triggers banking after the cooldown; occupancy estimates alone do not trigger it.")
        case .emptyInventoryGrid:
            return .init(title: "Empty inventory grid baseline", kind: "Diagnostic", group: .monitoring,
                         instruction: "Optional: empty the actual item grid, capture it, and mark the whole grid without its title, buttons or equipment slots. Set the correct row/column counts. Later snapshots are compared against this empty baseline to estimate occupancy.")
        case .jewelSample:
            return .init(title: "Example jewel item", kind: "Diagnostic", group: .monitoring,
                         instruction: "Optional: capture a known jewel in inventory and mark one item cell as a sample. Sample matches are uncertain diagnostics, not proof of jewel type, complete collection or successful transfer.")
        case .inventoryGrid:
            return .init(title: "Inventory grid reference", kind: "Optional", group: .monitoring,
                         instruction: "Optional reference region around the item-slot grid. Current occupancy estimates use emptyInventoryGrid and jewelSample instead; inventoryGrid alone does not count items or trigger banking.")
        case .deathConfirmation:
            return .init(title: "Independent death confirmation", kind: "State", group: .recovery,
                         instruction: "Full mode with recovery enabled: mark a second, independent death-only feature, such as a genuine revive control. It must agree with deathIndicator across fresh frames. Do not reuse the same rectangle or low-health indicator.")
        case .destinationLandmark:
            return .init(title: "Farming destination reached", kind: "State", group: .recovery,
                         instruction: "For recovery or route replay: at the real farming destination, mark a stable, unique location landmark or location text. Route completion requires this marker before Helper can restart; strict recognition also requires normalGameplay.")
        case .warpPanel:
            return .init(title: "Warp / travel dialog", kind: "State", group: .recovery,
                         instruction: "For routes that use travel: open the actual Warp dialog and mark its unique title or header. The app can recognize this state but does not choose a map or build a route automatically.")
        case .mapControl:
            return .init(title: "Open map / travel", kind: "Route click", group: .recovery,
                         instruction: "Optional route target: mark the actual map or travel button only if your configured route clicks it. Record and verify the real route; no map action is added merely by labeling this target.")
        case .mapDestination:
            return .init(title: "Choose map destination", kind: "Route click", group: .recovery,
                         instruction: "Optional route target: with the correct map/travel dialog open, mark the actual destination control your route should click. Labeling it does not select a destination automatically; add it to a verified route.")
        case .routeCheckpoint:
            return .init(title: "Route checkpoint 1", kind: "Route evidence", group: .route,
                         instruction: "Optional checkpoint 1: mark a stable scene feature used as a before/after condition in your recorded route. If you assign this role as a click target, its center must also be a safe clickable location inside the game area.")
        case .routeCheckpoint2:
            return .init(title: "Route checkpoint 2", kind: "Route evidence", group: .route,
                         instruction: "Optional checkpoint 2: mark a stable scene feature used as a before/after condition in your recorded route. If you assign this role as a click target, its center must also be a safe clickable location inside the game area.")
        case .routeCheckpoint3:
            return .init(title: "Route checkpoint 3", kind: "Route evidence", group: .route,
                         instruction: "Optional checkpoint 3: mark a stable scene feature used as a before/after condition in your recorded route. If you assign this role as a click target, its center must also be a safe clickable location inside the game area.")
        case .routeCheckpoint4:
            return .init(title: "Route checkpoint 4", kind: "Route evidence", group: .route,
                         instruction: "Optional checkpoint 4: mark a stable scene feature used as a before/after condition in your recorded route. If you assign this role as a click target, its center must also be a safe clickable location inside the game area.")
        case .routeCheckpoint5:
            return .init(title: "Route checkpoint 5", kind: "Route evidence", group: .route,
                         instruction: "Optional checkpoint 5: mark a stable scene feature used as a before/after condition in your recorded route. If you assign this role as a click target, its center must also be a safe clickable location inside the game area.")
        case .routeCheckpoint6:
            return .init(title: "Route checkpoint 6", kind: "Route evidence", group: .route,
                         instruction: "Optional checkpoint 6: mark a stable scene feature used as a before/after condition in your recorded route. If you assign this role as a click target, its center must also be a safe clickable location inside the game area.")
        case .routeCheckpoint7:
            return .init(title: "Route checkpoint 7", kind: "Route evidence", group: .route,
                         instruction: "Optional checkpoint 7: mark a stable scene feature used as a before/after condition in your recorded route. If you assign this role as a click target, its center must also be a safe clickable location inside the game area.")
        case .routeCheckpoint8:
            return .init(title: "Route checkpoint 8", kind: "Route evidence", group: .route,
                         instruction: "Optional checkpoint 8: mark a stable scene feature used as a before/after condition in your recorded route. If you assign this role as a click target, its center must also be a safe clickable location inside the game area.")
        case .routeCheckpoint9:
            return .init(title: "Route checkpoint 9", kind: "Route evidence", group: .route,
                         instruction: "Optional checkpoint 9: mark a stable scene feature used as a before/after condition in your recorded route. If you assign this role as a click target, its center must also be a safe clickable location inside the game area.")
        case .routeCheckpoint10:
            return .init(title: "Route checkpoint 10", kind: "Route evidence", group: .route,
                         instruction: "Optional checkpoint 10: mark a stable scene feature used as a before/after condition in your recorded route. If you assign this role as a click target, its center must also be a safe clickable location inside the game area.")
        }
    }
}

import XCTest
@testable import AutomationCore

final class CalibrationGuideTests: XCTestCase {
    func testStrictBankingFirstRequirementsAreTheSameInBothModesWithOtherModulesOff() {
        let expected: Set<TargetRole> = [
            .gameViewport, .normalGameplay, .inventoryControl, .inventoryPanel,
            .bankControl, .bankTitle, .transferButton, .withdrawExcluded,
            .processingIndicator, .transferSuccess, .bankClose, .inventoryClose,
            .disconnected, .loginScreen, .characterSelection, .browserLoading,
            .loadingTransition, .deathIndicator, .respawnIndicator
        ]
        var config = AutomationConfiguration()
        config.strictGameplayRecognition = true
        config.helperEnabled = false; config.skillsEnabled = false; config.recoveryEnabled = false
        for mode in AutomationMode.allCases {
            config.mode = mode
            XCTAssertEqual(CalibrationRequirements.roles(configuration: config, settings: .init()), expected)
        }
    }

    func testRelaxedBankingRequiresActionAndVerificationTargetsWithoutGeneralSceneLabels() {
        let expected: Set<TargetRole> = [.gameViewport, .inventoryControl, .inventoryPanel, .bankControl,
                                         .bankTitle, .transferButton, .withdrawExcluded, .processingIndicator,
                                         .transferSuccess, .bankClose, .inventoryClose]
        var config = AutomationConfiguration(); config.helperEnabled = false
        for mode in AutomationMode.allCases {
            config.mode = mode
            XCTAssertEqual(CalibrationRequirements.roles(configuration: config, settings: .init()), expected)
        }
    }

    func testSelectedBankingProofReplacesTheOtherProofOptions() {
        for verification in BankingVerificationMode.allCases {
            var settings = WorkflowSettings()
            settings.bankingVerification = verification
            let roles = CalibrationRequirements.roles(configuration: .init(), settings: settings)
            let proofs: Set<TargetRole> = [.transferSuccess, .inventoryCountText, .bankBalanceText]
            XCTAssertEqual(roles.intersection(proofs), [verification.countRole ?? .transferSuccess])
            XCTAssertTrue(roles.contains(.processingIndicator))
            XCTAssertTrue(roles.contains(.withdrawExcluded))
        }
    }

    func testFullModeAddsOnlyEnabledHelperRecoveryAndConfiguredEvidence() {
        var config = AutomationConfiguration()
        config.mode = .fullAutomation
        config.recoveryEnabled = true; config.skillsEnabled = true
        var settings = WorkflowSettings()
        settings.route.steps = [.init(action: .click(.mapControl), before: .warpPanel, after: .routeCheckpoint3)]
        var skill = SkillAction(); skill.verification = .routeCheckpoint8
        settings.skills = [skill]
        let roles = CalibrationRequirements.roles(configuration: config, settings: settings)
        let additions: Set<TargetRole> = [.helperControl, .helperPanel, .helperStart, .helperRunning,
                                         .deathConfirmation, .destinationLandmark, .mapControl,
                                         .warpPanel, .routeCheckpoint3, .routeCheckpoint8]
        XCTAssertTrue(additions.isSubset(of: roles))
        config.helperEnabled = false; config.recoveryEnabled = false; config.skillsEnabled = false
        let bankingFirst = CalibrationRequirements.roles(configuration: config, settings: settings)
        XCTAssertTrue(additions.isDisjoint(with: bankingFirst))
    }

    func testRouteReplayChecklistDoesNotRequireBankingOrHelperControls() {
        var config = AutomationConfiguration(); config.mode = .fullAutomation
        var settings = WorkflowSettings()
        settings.route.steps = [.init(action: .click(.mapDestination), before: .warpPanel, after: .destinationLandmark)]
        let roles = CalibrationRequirements.roles(configuration: config, settings: settings, routeTest: true)
        XCTAssertTrue(roles.contains(.mapDestination))
        XCTAssertTrue(roles.contains(.warpPanel))
        XCTAssertTrue(roles.contains(.deathConfirmation))
        XCTAssertFalse(roles.contains(.transferButton))
        XCTAssertFalse(roles.contains(.helperStart))
    }

    func testEverySavedTargetRemainsSelectableInTheCalibrationGuide() {
        XCTAssertEqual(Set(TargetRole.calibrationOrder), Set(TargetRole.allCases))
        XCTAssertEqual(TargetRole.calibrationOrder.count, Set(TargetRole.calibrationOrder).count)
    }
}

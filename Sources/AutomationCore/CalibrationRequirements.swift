import Foundation

public enum CalibrationRequirements {
    public static func roles(configuration: AutomationConfiguration, settings: WorkflowSettings,
                             routeTest: Bool = false) -> Set<TargetRole> {
        let recordedBank = settings.bankingEnabled && settings.bankingInputMode == .recordedInput && !routeTest
        let recordedRoute = settings.route.recording != nil && (configuration.recoveryEnabled || routeTest)
        var roles: Set<TargetRole> = []
        if !recordedBank && !recordedRoute { roles.insert(.gameViewport) }
        if configuration.strictGameplayRecognition {
            roles.formUnion([.normalGameplay, .disconnected, .loginScreen, .characterSelection,
                             .browserLoading, .loadingTransition, .deathIndicator, .respawnIndicator])
        }
        if settings.bankingEnabled && !routeTest && !recordedBank {
            roles.insert(.gameViewport)
            roles.formUnion([.inventoryControl, .inventoryPanel, .bankControl, .bankTitle, .transferButton,
                             .withdrawExcluded, .processingIndicator, .bankClose, .inventoryClose])
            roles.insert(settings.bankingVerification.countRole ?? .transferSuccess)
        }
        guard configuration.mode == .fullAutomation else { return roles }
        if configuration.helperEnabled && !routeTest { roles.formUnion([.gameViewport, .helperControl, .helperPanel, .helperStart, .helperRunning]) }
        if configuration.recoveryEnabled || routeTest {
            roles.formUnion([.deathIndicator, .deathConfirmation, .respawnIndicator, .destinationLandmark])
            if !recordedRoute { roles.insert(.gameViewport) }
            for step in recordedRoute ? [] : settings.route.steps {
                roles.formUnion([step.before, step.after])
                if case let .click(role) = step.action { roles.insert(role) }
            }
        }
        for skill in settings.skills where configuration.skillsEnabled && !routeTest {
            if let role = skill.verification { roles.insert(role) }
        }
        return roles
    }
}

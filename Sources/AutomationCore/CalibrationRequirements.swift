import Foundation

public enum CalibrationRequirements {
    public static func roles(configuration: AutomationConfiguration, settings: WorkflowSettings,
                             routeTest: Bool = false) -> Set<TargetRole> {
        var roles: Set<TargetRole> = [.gameViewport, .normalGameplay, .disconnected, .loginScreen, .characterSelection,
                                      .browserLoading, .loadingTransition, .deathIndicator, .respawnIndicator]
        if settings.bankingEnabled && !routeTest {
            roles.formUnion([.inventoryControl, .inventoryPanel, .bankControl, .bankTitle, .transferButton,
                             .withdrawExcluded, .processingIndicator, .bankClose, .inventoryClose])
            roles.insert(settings.bankingVerification.countRole ?? .transferSuccess)
        }
        guard configuration.mode == .fullAutomation else { return roles }
        if configuration.helperEnabled && !routeTest { roles.formUnion([.helperControl, .helperPanel, .helperStart, .helperRunning]) }
        if configuration.recoveryEnabled || routeTest {
            roles.formUnion([.deathIndicator, .deathConfirmation, .respawnIndicator, .destinationLandmark])
            for step in settings.route.steps {
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

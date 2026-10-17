import Foundation

public enum AutomationMode: String, Codable, CaseIterable, Sendable {
    case jewelsOnly, fullAutomation

    public var title: String {
        switch self {
        case .jewelsOnly: return "Jewels only"
        case .fullAutomation: return "Full automation"
        }
    }
}

public struct AutomationConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var mode: AutomationMode = .jewelsOnly
    public var dryRun = true
    public var helperEnabled = true
    public var recoveryEnabled = false
    public var skillsEnabled = false
    public var actionTimeoutSeconds = 10
    public var maximumRetries = 2

    public init() {}

    public func validate() throws {
        guard schemaVersion == 1 else { throw ConfigurationError.unsupportedVersion }
        guard (1...120).contains(actionTimeoutSeconds), (0...5).contains(maximumRetries) else {
            throw ConfigurationError.invalidLimits
        }
    }
}

public enum ConfigurationError: Error { case unsupportedVersion, invalidLimits }

public struct ConfigurationStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> AutomationConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let value = try JSONDecoder().decode(AutomationConfiguration.self, from: Data(contentsOf: url))
        try value.validate()
        return value
    }

    public func save(_ value: AutomationConfiguration) throws {
        try value.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

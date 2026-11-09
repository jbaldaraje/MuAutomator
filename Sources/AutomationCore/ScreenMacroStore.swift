import Foundation

public struct ScreenMacroSettings: Codable, Equatable, Sendable {
    public var hours: Double
    public var intervalSeconds: Double
    public init(hours: Double = 1, intervalSeconds: Double = 0) {
        self.hours = hours; self.intervalSeconds = intervalSeconds
    }
    private enum CodingKeys: String, CodingKey { case hours, intervalSeconds }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hours = try values.decode(Double.self, forKey: .hours)
        intervalSeconds = try values.decodeIfPresent(Double.self, forKey: .intervalSeconds) ?? 0
    }
    public func validate() throws {
        guard hours.isFinite, hours > 0, hours <= 8760 else {
            throw ScreenMacroError.invalid("Enter hours greater than zero and no more than 8,760. Decimals are supported.")
        }
        guard intervalSeconds.isFinite, (0...86400).contains(intervalSeconds) else {
            throw ScreenMacroError.invalid("Enter a repeat interval from 0 to 86,400 seconds. Decimals are supported.")
        }
    }
}

public struct ScreenMacroStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public var recordingURL: URL { directory.appendingPathComponent("screen-macro.json") }
    private var settingsURL: URL { directory.appendingPathComponent("screen-macro-settings.json") }
    public func load() throws -> ScreenMacro? {
        guard FileManager.default.fileExists(atPath: recordingURL.path) else { return nil }
        return try Self.read(recordingURL)
    }
    public static func read(_ url: URL) throws -> ScreenMacro {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64 * 1024 * 1024 else { throw ScreenMacroError.invalid("Macro files must be smaller than 64 MB.") }
        let macro = try JSONDecoder().decode(ScreenMacro.self, from: Data(contentsOf: url))
        try macro.validate()
        return macro
    }
    public static func write(_ macro: ScreenMacro, to url: URL) throws {
        try macro.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(macro).write(to: url, options: .atomic)
    }
    public func save(_ macro: ScreenMacro) throws { try Self.write(macro, to: recordingURL) }
    public func loadSettings() throws -> ScreenMacroSettings {
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let value = try JSONDecoder().decode(ScreenMacroSettings.self, from: Data(contentsOf: settingsURL))
            try value.validate(); return value
        }
        // Carry forward the hours preference, but never guess desktop positions from window-relative macros.
        struct Legacy: Decodable {
            struct Repetition: Decodable { var durationSeconds: Double? }
            var macroRepeat: Repetition?
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("workflow.json")),
           let legacy = try? JSONDecoder().decode(Legacy.self, from: data),
           let seconds = legacy.macroRepeat?.durationSeconds {
            let settings = ScreenMacroSettings(hours: seconds / 3600)
            if (try? settings.validate()) != nil { return settings }
        }
        return ScreenMacroSettings()
    }
    public func saveSettings(_ settings: ScreenMacroSettings) throws {
        try settings.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: settingsURL, options: .atomic)
    }
}

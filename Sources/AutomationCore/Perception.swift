import Foundation

public struct GrayImage: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width; self.height = height; self.pixels = pixels
    }
    public func validate() throws {
        guard (1...256).contains(width), (1...256).contains(height), pixels.count == width * height else {
            throw CalibrationError.invalidProfile
        }
    }
}

public enum TemplateMatcher {
    /// Contrast-sensitive correlation in the explicitly calibrated region.
    /// A score is similarity, not a calibrated probability of semantic correctness.
    public static func similarity(_ lhs: GrayImage, _ rhs: GrayImage) -> Double {
        guard (try? lhs.validate()) != nil, (try? rhs.validate()) != nil,
              lhs.width == rhs.width, lhs.height == rhs.height else { return 0 }
        let count = Double(lhs.pixels.count)
        let leftMean = lhs.pixels.reduce(0.0) { $0 + Double($1) } / count
        let rightMean = rhs.pixels.reduce(0.0) { $0 + Double($1) } / count
        var covariance = 0.0, leftVariance = 0.0, rightVariance = 0.0, difference = 0.0
        for (left, right) in zip(lhs.pixels, rhs.pixels) {
            let a = Double(left) - leftMean, b = Double(right) - rightMean
            covariance += a * b; leftVariance += a * a; rightVariance += b * b
            difference += abs(Double(left) - Double(right))
        }
        // Featureless patches must never count as visual evidence.
        guard leftVariance / count > 16, rightVariance / count > 16 else { return 0 }
        let correlation = covariance / sqrt(leftVariance * rightVariance)
        return max(0, min(1, correlation)) * (1 - difference / (255 * count))
    }
}

public enum GameState: String, Codable, Sendable {
    case unknown, browserLoading, loginScreen, characterSelection, normalGameplay
    case inventoryOpen, jewelBankOpen, warpWindowOpen, helperWindowOpen, helperRunning
    case possibleDeath, respawnScreen, disconnected, loadingTransition
}

public struct Observation: Sendable {
    public let timestamp: Date
    public let matches: [TargetRole: Double]
    public let text: [TargetRole: String]
    public let inventory: InventoryEstimate?
    public init(timestamp: Date = Date(), matches: [TargetRole: Double], text: [TargetRole: String] = [:], inventory: InventoryEstimate? = nil) {
        self.timestamp = timestamp; self.matches = matches; self.text = text; self.inventory = inventory
    }
    public func has(_ role: TargetRole) -> Bool {
        guard let score = matches[role] else { return false }
        return score.isFinite && (0.8...1).contains(score)
    }
    public var state: GameState {
        if has(.disconnected) { return .disconnected }
        if has(.loginScreen) { return .loginScreen }
        if has(.characterSelection) { return .characterSelection }
        if has(.browserLoading) { return .browserLoading }
        if has(.loadingTransition) { return .loadingTransition }
        if has(.deathIndicator) && has(.respawnIndicator) { return .unknown }
        if has(.deathIndicator) { return .possibleDeath }
        if has(.respawnIndicator) { return .respawnScreen }
        let modals = [has(.bankTitle), has(.helperPanel), has(.warpPanel)].filter { $0 }.count
        if modals > 1 { return .unknown }
        if has(.bankTitle) { return .jewelBankOpen }
        if has(.helperPanel) { return .helperWindowOpen }
        if has(.warpPanel) { return .warpWindowOpen }
        if has(.inventoryPanel) { return .inventoryOpen }
        if has(.helperRunning) { return .helperRunning }
        if has(.normalGameplay) { return .normalGameplay }
        return .unknown
    }
    public var blocksInput: Bool {
        [.unknown, .disconnected, .loginScreen, .characterSelection, .browserLoading, .loadingTransition, .possibleDeath, .respawnScreen].contains(state)
    }
}

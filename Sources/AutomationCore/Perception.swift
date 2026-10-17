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
    public let scores: [TargetRole: Double]
    public init(timestamp: Date = Date(), matches: [TargetRole: Double], text: [TargetRole: String] = [:],
                inventory: InventoryEstimate? = nil, scores: [TargetRole: Double] = [:]) {
        self.timestamp = timestamp; self.matches = matches; self.text = text; self.inventory = inventory
        self.scores = scores
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

    /// Relaxed recognition trusts a verified action target when the general
    /// gameplay classifier is unknown. Explicit interruption evidence still wins.
    public func permitsInput(strictGameplayRecognition: Bool, allowRespawn: Bool = false) -> Bool {
        if strictGameplayRecognition { return !blocksInput || (allowRespawn && state == .respawnScreen) }
        let interruptions: [TargetRole] = [.disconnected, .loginScreen, .characterSelection,
                                           .browserLoading, .loadingTransition, .deathIndicator]
        guard !interruptions.contains(where: has) else { return false }
        return allowRespawn || !has(.respawnIndicator)
    }
}

public struct OCRTextCandidate: Sendable {
    public let text: String
    public let confidence: Double
    public init(text: String, confidence: Double) { self.text = text; self.confidence = confidence }
}

public enum OCRTextMatcher {
    /// Confidence belongs to the matching phrase's lines, not unrelated OCR
    /// noise elsewhere in the same crop. Multi-line phrases keep the weakest
    /// confidence among the lines needed to form that phrase.
    public static func confidence(for expected: String, in candidates: [OCRTextCandidate]) -> Double {
        let phrase = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return 0 }
        var best = 0.0
        for start in candidates.indices {
            var text = "", score = 1.0
            for end in start..<candidates.count {
                let candidate = candidates[end]
                let confidence = candidate.confidence.isFinite ? max(0, min(1, candidate.confidence)) : 0
                text += (text.isEmpty ? "" : " ") + candidate.text
                score = min(score, confidence)
                if text.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    best = max(best, score)
                    break
                }
            }
        }
        return best
    }
}

public enum TargetRecognition {
    public static func score(template: Double?, ocr: Double?, numeric: Bool, strict: Bool) -> Double? {
        if numeric { return ocr }
        if !strict { return template ?? ocr }
        if let template, let ocr { return min(template, ocr) }
        return template ?? ocr
    }
}

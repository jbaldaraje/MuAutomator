import Foundation

public enum BankingVerificationMode: String, Codable, CaseIterable, Sendable {
    case newSuccessIndicator, inventoryCountDecrease, bankBalanceIncrease
    public var countRole: TargetRole? {
        switch self {
        case .newSuccessIndicator: return nil
        case .inventoryCountDecrease: return .inventoryCountText
        case .bankBalanceIncrease: return .bankBalanceText
        }
    }
}

public enum CountFormat: String, Codable, CaseIterable, Sendable {
    case digitsOnly, commaGrouped, spaceGrouped
    public func parse(_ raw: String) -> Int64? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator: String
        switch self {
        case .digitsOnly: separator = ""
        case .commaGrouped: separator = ","
        case .spaceGrouped: separator = " "
        }
        let pattern = separator.isEmpty ? "^[0-9]+$" : "^(?:[0-9]+|[0-9]{1,3}(?:\(separator)[0-9]{3})+)$"
        guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return Int64(separator.isEmpty ? text : text.replacingOccurrences(of: separator, with: ""))
    }
}

public enum BankingVerifier {
    public static func count(in observation: Observation, mode: BankingVerificationMode, format: CountFormat) -> Int64? {
        guard let role = mode.countRole, observation.has(role), let text = observation.text[role] else { return nil }
        return format.parse(text)
    }

    public static func verified(before: Observation, after: Observation,
                                mode: BankingVerificationMode, format: CountFormat) -> Bool {
        guard after.has(.bankTitle), !after.has(.processingIndicator) else { return false }
        if mode == .newSuccessIndicator {
            return !before.has(.transferSuccess) && after.has(.transferSuccess)
        }
        guard let first = count(in: before, mode: mode, format: format),
              let last = count(in: after, mode: mode, format: format) else { return false }
        return mode == .inventoryCountDecrease ? last < first : last > first
    }
}

/// An observed balance change, not independent proof that a deposit succeeded.
public struct BankBalanceReading: Equatable, Sendable {
    public let balance: Int64
    public let added: Int64?
    public let timestamp: Date
}

/// Requires two consecutive fresh, confident reads for each end of a collection.
/// Values are scoped to one collection; a previous collection is never a baseline.
public struct BankBalanceTracker: Sendable {
    private var candidate: Int64?
    private var candidateTime: Date?
    private var baseline: Int64?
    private var latest: (value: Int64, time: Date)?
    public init() {}

    public mutating func observe(_ frame: Observation, format: CountFormat) {
        guard frame.has(.bankTitle) else {
            candidate = nil; candidateTime = nil
            return
        }
        guard !frame.has(.processingIndicator),
              abs(frame.timestamp.timeIntervalSinceNow) < 2,
              let value = BankingVerifier.count(in: frame, mode: .bankBalanceIncrease, format: format) else {
            candidate = nil; candidateTime = nil; latest = nil
            return
        }
        if candidate == value, let previousTime = candidateTime, frame.timestamp > previousTime {
            if baseline == nil { baseline = value }
            latest = (value, frame.timestamp)
        } else {
            latest = nil
        }
        candidate = value; candidateTime = frame.timestamp
    }

    public var reading: BankBalanceReading? {
        guard let baseline, let latest, latest.value >= baseline else { return nil }
        return BankBalanceReading(balance: latest.value, added: latest.value > baseline ? latest.value - baseline : nil, timestamp: latest.time)
    }
}

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

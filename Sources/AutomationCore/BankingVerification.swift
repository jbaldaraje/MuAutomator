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
    /// Historical evidence survives subsequent unreadable/closing frames.
    /// `reading` still reports whether the latest visible evidence is usable.
    public private(set) var lastConfirmedReading: BankBalanceReading?
    public private(set) var diagnostic = "Bank was not recognized during this collection. Check bankTitle."
    public init() {}

    public mutating func observe(_ frame: Observation, format: CountFormat) {
        guard frame.has(.bankTitle) else {
            candidate = nil; candidateTime = nil
            return
        }
        let issue: String?
        if frame.has(.processingIndicator) { issue = "Bank was still processing at the last reading." }
        else if !(abs(frame.timestamp.timeIntervalSinceNow) < 2) { issue = "The captured balance frame was too old." }
        else if BankingVerifier.count(in: frame, mode: .bankBalanceIncrease, format: format) == nil {
            issue = "The number was unreadable or below the OCR confidence threshold."
        } else { issue = nil }
        if let issue {
            diagnostic = issue
            candidate = nil; candidateTime = nil; latest = nil
            return
        }
        guard let value = BankingVerifier.count(in: frame, mode: .bankBalanceIncrease, format: format) else { return }
        if candidate == value, let previousTime = candidateTime, frame.timestamp > previousTime {
            if baseline == nil { baseline = value }
            latest = (value, frame.timestamp)
            let first = baseline ?? value
            lastConfirmedReading = BankBalanceReading(balance: value, added: value > first ? value - first : nil,
                                                       timestamp: frame.timestamp)
            diagnostic = value < (baseline ?? value)
                ? "Balance decreased during collection; amount added could not be confirmed."
                : "Balance read successfully."
        } else {
            latest = nil
            diagnostic = "Only one matching number reading. Keep the bank visible longer before closing it."
        }
        candidate = value; candidateTime = frame.timestamp
    }

    public var reading: BankBalanceReading? {
        guard let baseline, let latest, latest.value >= baseline else { return nil }
        return BankBalanceReading(balance: latest.value, added: latest.value > baseline ? latest.value - baseline : nil, timestamp: latest.time)
    }
}


public struct NamedBankBalanceSample: Sendable {
    public let name: String
    public let text: String
    public let count: Int64?
    public let confidence: Double
    public let failureReason: String?
    public init(target: NamedBankBalanceTarget, text: String, confidence: Double, bankRecognized: Bool = true) {
        self.name = target.name; self.text = text; self.confidence = confidence
        if !bankRecognized {
            failureReason = "Bank not recognized. Check bankTitle."
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failureReason = "No text found in this jewel’s number region. Redraw it around the digits."
        } else if !confidence.isFinite || confidence < target.threshold || confidence > 1 {
            failureReason = "Number OCR confidence is below the saved threshold. Check the crop and text clarity."
        } else if target.format.parse(text) == nil {
            failureReason = "OCR text does not match \(target.format.rawValue). Check the format and exclude labels/icons."
        } else { failureReason = nil }
        count = failureReason == nil ? target.format.parse(text) : nil
    }
}

public struct NamedBankBalanceReading: Sendable {
    public let name: String
    public let reading: BankBalanceReading
}

/// Each jewel keeps independent evidence and its own collection baseline.
public struct NamedBankBalanceTracker: Sendable {
    private var trackers: [UUID: BankBalanceTracker] = [:]
    private var names: [UUID: String] = [:]
    private var numericIssues: [UUID: String] = [:]
    public init() {}
    public mutating func observe(_ frame: Observation) {
        for (id, sample) in frame.namedBankBalances {
            if trackers[id] == nil { trackers[id] = BankBalanceTracker() }
            names[id] = sample.name
            if frame.has(.bankTitle) {
                numericIssues[id] = !frame.has(.processingIndicator) && abs(frame.timestamp.timeIntervalSinceNow) < 2
                    ? sample.failureReason : nil
            }
        }
        for id in Array(trackers.keys) {
            let count = frame.namedBankBalances[id]?.count
            var matches = frame.matches
            matches[.bankBalanceText] = count == nil ? 0 : 1
            // Reuse the same freshness, processing and stable-read checks as the legacy balance.
            let numeric = Observation(timestamp: frame.timestamp, matches: matches,
                                      text: count.map { [.bankBalanceText: String($0)] } ?? [:])
            trackers[id]?.observe(numeric, format: .digitsOnly)
        }
    }
    public var issues: [UUID: String] {
        trackers.reduce(into: [:]) { result, pair in
            guard pair.value.reading == nil else { return }
            result[pair.key] = numericIssues[pair.key] ?? pair.value.diagnostic
        }
    }
    public var readings: [UUID: NamedBankBalanceReading] {
        trackers.compactMapValues { $0.lastConfirmedReading }.reduce(into: [:]) { result, pair in
            result[pair.key] = NamedBankBalanceReading(name: names[pair.key] ?? "Jewel", reading: pair.value)
        }
    }
}

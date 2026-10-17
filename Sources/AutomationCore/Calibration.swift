import Foundation

public enum TargetRole: String, Codable, CaseIterable, Sendable {
    case inventoryControl, inventoryPanel, inventoryGrid, bankControl, bankTitle
    case transferButton, withdrawExcluded, processingIndicator, transferSuccess
    case helperControl, helperPanel, helperStart, helperRunning, warpPanel
    case deathIndicator, respawnIndicator, destinationLandmark
    case normalGameplay, disconnected, loginScreen, characterSelection, browserLoading, loadingTransition
    case bankClose, inventoryClose, bankingTrigger, deathConfirmation, routeCheckpoint
    case routeCheckpoint2, routeCheckpoint3, routeCheckpoint4, routeCheckpoint5
    case routeCheckpoint6, routeCheckpoint7, routeCheckpoint8, routeCheckpoint9, routeCheckpoint10
    case emptyInventoryGrid, jewelSample
    case gameViewport, mapControl, mapDestination
    case inventoryCountText, bankBalanceText

    public var isClickControl: Bool {
        switch self {
        case .inventoryControl, .bankControl, .transferButton, .bankClose, .inventoryClose,
             .helperControl, .helperStart, .mapControl, .mapDestination: return true
        default: return false
        }
    }

    public var isNumericEvidence: Bool { self == .inventoryCountText || self == .bankBalanceText }
    public var isRecoveryEvidence: Bool {
        [.deathIndicator, .deathConfirmation, .respawnIndicator, .destinationLandmark,
         .routeCheckpoint, .routeCheckpoint2, .routeCheckpoint3, .routeCheckpoint4, .routeCheckpoint5,
         .routeCheckpoint6, .routeCheckpoint7, .routeCheckpoint8, .routeCheckpoint9, .routeCheckpoint10].contains(self)
    }
}

/// Window-relative, top-left origin. Independent of Retina pixel density.
public struct NormalizedRegion: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) throws {
        guard [x, y, width, height].allSatisfy({ $0.isFinite }),
              x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1, y + height <= 1 else { throw CalibrationError.invalidRegion }
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public func validate() throws {
        _ = try Self(x: x, y: y, width: width, height: height)
    }

    public func overlaps(_ other: Self) -> Bool {
        x < other.x + other.width && other.x < x + width && y < other.y + other.height && other.y < y + height
    }

    public func contains(x: Double, y: Double) -> Bool {
        x >= self.x && x < self.x + width && y >= self.y && y < self.y + height
    }
}

public enum CalibrationError: Error { case invalidRegion, invalidProfile }

/// A click position measured in the actual window, independent of screenshot padding.
public struct CalibratedClickPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw CalibrationError.invalidRegion
        }
        self.x = x; self.y = y
    }
    public func validate() throws { _ = try Self(x: x, y: y) }
}

public struct CalibratedTarget: Codable, Identifiable, Sendable {
    public var id: TargetRole { role }
    public let role: TargetRole
    public let region: NormalizedRegion
    public var template: GrayImage?
    public var expectedText: String?
    public var threshold: Double = 0.95
    public var clickPoint: CalibratedClickPoint?
    public var effectiveClickPoint: CalibratedClickPoint {
        // Regions have already been validated by the profile before live input.
        get throws { try clickPoint ?? CalibratedClickPoint(x: region.x + region.width / 2, y: region.y + region.height / 2) }
    }
    public init(role: TargetRole, region: NormalizedRegion, template: GrayImage? = nil,
                expectedText: String? = nil, threshold: Double = 0.95, clickPoint: CalibratedClickPoint? = nil) {
        self.role = role; self.region = region; self.template = template
        self.expectedText = expectedText; self.threshold = threshold
        self.clickPoint = clickPoint
    }

    private enum CodingKeys: String, CodingKey { case role, region, template, expectedText, threshold, clickPoint }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        role = try values.decode(TargetRole.self, forKey: .role)
        region = try values.decode(NormalizedRegion.self, forKey: .region)
        template = try values.decodeIfPresent(GrayImage.self, forKey: .template)
        expectedText = try values.decodeIfPresent(String.self, forKey: .expectedText)
        threshold = try values.decodeIfPresent(Double.self, forKey: .threshold) ?? 0.95
        clickPoint = try values.decodeIfPresent(CalibratedClickPoint.self, forKey: .clickPoint)
    }
}

public struct CalibrationProfile: Codable, Sendable {
    public var schemaVersion = 1
    public var targets: [CalibratedTarget] = []
    public var windowAspectRatio: Double?
    public var inventoryColumns: Int? = 8
    public var inventoryRows: Int? = 8
    public init() {}

    public func validate() throws {
        guard schemaVersion == 1, Set(targets.map(\.role)).count == targets.count else {
            throw CalibrationError.invalidProfile
        }
        if let ratio = windowAspectRatio, !ratio.isFinite || ratio <= 0 {
            throw CalibrationError.invalidProfile
        }
        guard (1...16).contains(inventoryColumns ?? 8), (1...16).contains(inventoryRows ?? 8) else { throw CalibrationError.invalidProfile }
        for target in targets {
            try target.region.validate()
            try target.clickPoint?.validate()
            guard target.threshold.isFinite, (0.8...1).contains(target.threshold) else { throw CalibrationError.invalidProfile }
            try target.template?.validate()
        }
    }
}

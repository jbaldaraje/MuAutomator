import XCTest
@testable import AutomationCore

final class CalibrationTests: XCTestCase {
    func testCursorClickOverrideRoundTripsWithoutChangingRecognitionRegion() throws {
        let region = try NormalizedRegion(x: 0.2, y: 0.3, width: 0.1, height: 0.1)
        var profile = CalibrationProfile()
        profile.targets = [.init(role: .inventoryControl, region: region, expectedText: "Inventory")]
        XCTAssertEqual(try profile.targets[0].effectiveClickPoint.x, 0.25, accuracy: 0.000001)
        profile.targets[0].clickPoint = try CalibratedClickPoint(x: 0.8, y: 0.9)
        let loaded = try JSONDecoder().decode(CalibrationProfile.self, from: JSONEncoder().encode(profile))
        try loaded.validate()
        XCTAssertEqual(try loaded.targets[0].effectiveClickPoint, try CalibratedClickPoint(x: 0.8, y: 0.9))
        XCTAssertEqual(loaded.targets[0].region, region)
        XCTAssertEqual(loaded.targets[0].expectedText, "Inventory")
    }

    func testLegacyTargetUsesRegionCenterAndInvalidDecodedPointIsRejected() throws {
        let legacy = Data(#"{"role":"inventoryControl","region":{"x":0.1,"y":0.2,"width":0.2,"height":0.2}}"#.utf8)
        var target = try JSONDecoder().decode(CalibratedTarget.self, from: legacy)
        XCTAssertNil(target.clickPoint)
        XCTAssertEqual(try target.effectiveClickPoint.y, 0.3, accuracy: 0.000001)
        target.clickPoint = try JSONDecoder().decode(CalibratedClickPoint.self, from: Data(#"{"x":1.5,"y":0.2}"#.utf8))
        var profile = CalibrationProfile(); profile.targets = [target]
        XCTAssertThrowsError(try profile.validate())
        XCTAssertThrowsError(try CalibratedClickPoint(x: .nan, y: 0))
    }

    func testRejectsUnsafeRegions() {
        for values in [(-0.1, 0.0, 0.2, 0.2), (0.9, 0.0, 0.2, 0.2),
                       (0.0, 0.0, 0.0, 0.2), (Double.nan, 0.0, 0.2, 0.2)] {
            XCTAssertThrowsError(try NormalizedRegion(x: values.0, y: values.1, width: values.2, height: values.3))
        }
    }

    func testProfileRoundTripAndDuplicateRejection() throws {
        let region = try NormalizedRegion(x: 0.2, y: 0.3, width: 0.1, height: 0.1)
        var profile = CalibrationProfile()
        profile.targets = [.init(role: .transferButton, region: region)]
        let decoded = try JSONDecoder().decode(CalibrationProfile.self, from: JSONEncoder().encode(profile))
        try decoded.validate()
        XCTAssertEqual(decoded.targets.first?.region, region)
        profile.targets.append(.init(role: .transferButton, region: region))
        XCTAssertThrowsError(try profile.validate())
    }

    func testDecodedRegionStillRequiresValidation() throws {
        let data = Data(#"{"x":0.9,"y":0,"width":0.5,"height":0.2}"#.utf8)
        let region = try JSONDecoder().decode(NormalizedRegion.self, from: data)
        XCTAssertThrowsError(try region.validate())
    }
    func testNamedBalancesRoundTripAndLegacyProfilesRemainReadable() throws {
        let legacy = Data(#"{"schemaVersion":1,"targets":[],"inventoryColumns":8,"inventoryRows":8}"#.utf8)
        var profile = try JSONDecoder().decode(CalibrationProfile.self, from: legacy)
        XCTAssertTrue(profile.namedBankBalances.isEmpty)
        let first = try NormalizedRegion(x: 0.2, y: 0.2, width: 0.1, height: 0.05)
        let second = try NormalizedRegion(x: 0.2, y: 0.3, width: 0.1, height: 0.05)
        profile.namedBankBalances = [.init(name: "Jewel A", region: first),
                                     .init(name: "Jewel B", region: second, format: .commaGrouped, threshold: 0.9)]
        try profile.validate()
        let loaded = try JSONDecoder().decode(CalibrationProfile.self, from: JSONEncoder().encode(profile))
        try loaded.validate()
        XCTAssertEqual(loaded.namedBankBalances.map(\.id), profile.namedBankBalances.map(\.id))
        XCTAssertEqual(loaded.namedBankBalances.map(\.name), ["Jewel A", "Jewel B"])
        XCTAssertEqual(loaded.namedBankBalances[1].format, .commaGrouped)
        XCTAssertEqual(loaded.namedBankBalances[1].threshold, 0.9)
        XCTAssertEqual(loaded.namedBankBalances[1].region, second)
    }

    func testNamedBalancesRejectDuplicateNamesIdentitiesAndOverlappingRegions() throws {
        let first = try NormalizedRegion(x: 0.2, y: 0.2, width: 0.1, height: 0.05)
        let second = try NormalizedRegion(x: 0.2, y: 0.3, width: 0.1, height: 0.05)
        var profile = CalibrationProfile()
        let a = NamedBankBalanceTarget(name: "Jewel A", region: first)
        for b in [NamedBankBalanceTarget(name: " jewel a ", region: second),
                  NamedBankBalanceTarget(id: a.id, name: "Jewel B", region: second),
                  NamedBankBalanceTarget(name: "Jewel B", region: first),
                  NamedBankBalanceTarget(name: " ", region: second),
                  NamedBankBalanceTarget(name: "Jewel B", region: second, threshold: .nan)] {
            profile.namedBankBalances = [a, b]
            XCTAssertThrowsError(try profile.validate())
        }
    }

}

import XCTest
@testable import AutomationCore

final class CalibrationTests: XCTestCase {
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
}

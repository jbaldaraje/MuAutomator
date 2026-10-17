import XCTest
@testable import AutomationCore

final class InventoryTests: XCTestCase {
    func testEmptyOccupiedAndUncertainCells() throws {
        let empty = GrayImage(width: 4, height: 2, pixels: Array(repeating: 0, count: 8))
        let current = GrayImage(width: 4, height: 2, pixels: [0,255,15,0, 0,255,15,0])
        let result = try XCTUnwrap(InventoryAnalyzer.estimate(empty: empty, current: current, columns: 4, rows: 1))
        XCTAssertEqual(result.total, 4)
        XCTAssertEqual(result.occupied, 1)
        XCTAssertEqual(result.uncertain, 1)
        XCTAssertEqual(result.confidence, 0.75)
    }

    func testMismatchedGridAndInvalidParametersAreRejected() {
        let image = GrayImage(width: 2, height: 2, pixels: [0,0,0,0])
        XCTAssertNil(InventoryAnalyzer.estimate(empty: image, current: image, columns: 0, rows: 1))
        XCTAssertNil(InventoryAnalyzer.estimate(empty: image, current: image, columns: 3, rows: 1))
    }

    func testLegacyRegionOnlyCalibrationCanBeReadWithoutPretendingToDetect() throws {
        let data = Data(#"{"role":"bankTitle","region":{"x":0,"y":0,"width":0.2,"height":0.2}}"#.utf8)
        let target = try JSONDecoder().decode(CalibratedTarget.self, from: data)
        XCTAssertNil(target.template)
        XCTAssertEqual(target.threshold, 0.95)
    }
}

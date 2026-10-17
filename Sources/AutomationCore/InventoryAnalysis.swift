import Foundation

public struct InventoryEstimate: Sendable {
    public let occupied: Int
    public let uncertain: Int
    public let total: Int
    public let jewelMatches: Int
    public var confidence: Double { 1 - Double(uncertain) / Double(max(1, total)) }
}

public enum InventoryAnalyzer {
    /// Diagnostic only: compare a calibrated empty grid against the current grid.
    /// Occupancy is not item identity and is never by itself proof of a transfer.
    public static func estimate(empty: GrayImage, current: GrayImage, columns: Int, rows: Int,
                                jewel: GrayImage? = nil) -> InventoryEstimate? {
        guard (try? empty.validate()) != nil, (try? current.validate()) != nil,
              empty.width == current.width, empty.height == current.height,
              (1...16).contains(columns), (1...16).contains(rows),
              current.width >= columns, current.height >= rows else { return nil }
        var occupied = 0, uncertain = 0, jewels = 0
        for row in 0..<rows {
            for column in 0..<columns {
                let x0 = column * current.width / columns, x1 = (column + 1) * current.width / columns
                let y0 = row * current.height / rows, y1 = (row + 1) * current.height / rows
                var sum = 0.0, pixels: [UInt8] = []
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let index = y * current.width + x
                        sum += abs(Double(current.pixels[index]) - Double(empty.pixels[index])) / 255
                        pixels.append(current.pixels[index])
                    }
                }
                let difference = sum / Double(max(1, pixels.count))
                if difference > 0.10 { occupied += 1 }
                else if difference > 0.03 { uncertain += 1 }
                if let jewel, jewel.width == x1 - x0, jewel.height == y1 - y0,
                   TemplateMatcher.similarity(jewel, .init(width: x1 - x0, height: y1 - y0, pixels: pixels)) >= 0.95 {
                    jewels += 1
                }
            }
        }
        return InventoryEstimate(occupied: occupied, uncertain: uncertain, total: columns * rows, jewelMatches: jewels)
    }
}

import CoreGraphics
import Vision
import AutomationCore
import Foundation

enum VisionService {
    static func preview(_ gray: GrayImage) -> CGImage? {
        guard (try? gray.validate()) != nil,
              let provider = CGDataProvider(data: Data(gray.pixels) as CFData) else { return nil }
        return CGImage(width: gray.width, height: gray.height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: gray.width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    static func crop(_ image: CGImage, region: AutomationCore.NormalizedRegion) -> CGImage? {
        image.cropping(to: CGRect(x: region.x * Double(image.width), y: region.y * Double(image.height),
                                 width: region.width * Double(image.width), height: region.height * Double(image.height)).integral)
    }

    static func gray(_ image: CGImage, width: Int = 48, height: Int = 32) -> GrayImage? {
        var bytes = [UInt8](repeating: 0, count: width * height)
        let success = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return success ? GrayImage(width: width, height: height, pixels: bytes) : nil
    }

    static func detect(image: CGImage, profile: CalibrationProfile, timestamp: Date) throws -> Observation {
        try profile.validate()
        var matches: [TargetRole: Double] = [:]
        var texts: [TargetRole: String] = [:]
        for target in profile.targets {
            guard let cropped = crop(image, region: target.region) else { continue }
            var score: Double?
            if let template = target.template, let candidate = gray(cropped, width: template.width, height: template.height) {
                score = TemplateMatcher.similarity(template, candidate)
            }
            let expected = target.expectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let numeric = target.role == .inventoryCountText || target.role == .bankBalanceText
            if !expected.isEmpty || numeric {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: cropped, options: [:]).perform([request])
                let candidates = (request.results ?? []).compactMap { $0.topCandidates(1).first }
                let text = candidates.map(\.string).joined(separator: " ")
                texts[target.role] = text
                let contains = numeric || text.range(of: expected, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                let ocrScore = contains ? Double(candidates.map(\.confidence).min() ?? 0) : 0
                score = numeric ? ocrScore : min(score ?? 1, ocrScore)
            }
            if let score, score >= target.threshold { matches[target.role] = score }
        }
        var inventory: InventoryEstimate?
        if matches[.inventoryPanel] != nil,
           let baseline = profile.targets.first(where: { $0.role == .emptyInventoryGrid }),
           let empty = baseline.template, let crop = crop(image, region: baseline.region),
           let current = gray(crop, width: empty.width, height: empty.height) {
            inventory = InventoryAnalyzer.estimate(empty: empty, current: current,
                columns: profile.inventoryColumns ?? 8, rows: profile.inventoryRows ?? 8,
                jewel: profile.targets.first(where: { $0.role == .jewelSample })?.template)
        }
        return Observation(timestamp: timestamp, matches: matches, text: texts, inventory: inventory)
    }
}

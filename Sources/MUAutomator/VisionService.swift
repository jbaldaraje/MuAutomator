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

    static func recognize(_ cropped: CGImage) throws -> [AutomationCore.OCRTextCandidate] {
        // Render a standalone bitmap so Vision receives this target's pixels,
        // independent of a cropped CGImage's parent backing store/row stride.
        guard let context = CGContext(data: nil, width: cropped.width, height: cropped.height,
                                      bitsPerComponent: 8, bytesPerRow: cropped.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        guard let image = context.makeImage() else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first }.map {
            AutomationCore.OCRTextCandidate(text: $0.string, confidence: Double($0.confidence))
        }
    }

    static func detect(image: CGImage, profile: CalibrationProfile, timestamp: Date,
                       strictRecognition: Bool = true, includeOCRDiagnostics: Bool = true) throws -> Observation {
        try profile.validate()
        var matches: [TargetRole: Double] = [:]
        var scores: [TargetRole: Double] = [:]
        var texts: [TargetRole: String] = [:]
        for target in profile.targets {
            guard let cropped = crop(image, region: target.region) else { continue }
            var score: Double?
            if let template = target.template, let candidate = gray(cropped, width: template.width, height: template.height) {
                score = TemplateMatcher.similarity(template, candidate)
            }
            let expected = target.expectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let numeric = target.role.isNumericEvidence
            let recoveryOCR = target.role.isRecoveryEvidence && !expected.isEmpty
            let needsOCR = numeric || (!expected.isEmpty && (strictRecognition || recoveryOCR || score == nil || includeOCRDiagnostics))
            if needsOCR {
                let candidates = try recognize(cropped)
                let text = candidates.map(\.text).joined(separator: " ")
                texts[target.role] = text
                let ocrScore = numeric ? (candidates.map(\.confidence).min() ?? 0)
                    : AutomationCore.OCRTextMatcher.confidence(for: expected, in: candidates)
                score = AutomationCore.TargetRecognition.score(template: score, ocr: ocrScore, numeric: numeric,
                                                               strict: strictRecognition, preferOCR: recoveryOCR)
            }
            if let score { scores[target.role] = score }
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
        var namedBalances: [UUID: NamedBankBalanceSample] = [:]
        for target in profile.namedBankBalances {
            let candidates: [OCRTextCandidate]
            if (matches[.bankTitle] != nil || includeOCRDiagnostics), let cropped = crop(image, region: target.region) {
                candidates = try recognize(cropped)
            }
            else { candidates = [] }
            namedBalances[target.id] = NamedBankBalanceSample(target: target,
                text: candidates.map(\.text).joined(separator: " "),
                confidence: candidates.map(\.confidence).min() ?? 0,
                bankRecognized: matches[.bankTitle] != nil)
        }
        return Observation(timestamp: timestamp, matches: matches, text: texts, inventory: inventory,
                           scores: scores, namedBankBalances: namedBalances)
    }
}

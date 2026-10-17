import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fatalError("Could not create icon bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let p = CGFloat(pixels)
        NSColor(calibratedRed: 0.06, green: 0.10, blue: 0.20, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: p * 0.04, y: p * 0.04, width: p * 0.92, height: p * 0.92),
                     xRadius: p * 0.18, yRadius: p * 0.18).fill()
        let jewel = NSBezierPath()
        jewel.move(to: NSPoint(x: p * 0.20, y: p * 0.62))
        jewel.line(to: NSPoint(x: p * 0.34, y: p * 0.78))
        jewel.line(to: NSPoint(x: p * 0.66, y: p * 0.78))
        jewel.line(to: NSPoint(x: p * 0.80, y: p * 0.62))
        jewel.line(to: NSPoint(x: p * 0.50, y: p * 0.20)); jewel.close()
        NSColor(calibratedRed: 0.28, green: 0.82, blue: 0.95, alpha: 1).setFill(); jewel.fill()
        NSColor.white.withAlphaComponent(0.8).setStroke()
        let facets = NSBezierPath(); facets.lineWidth = max(1, p * 0.015)
        facets.move(to: NSPoint(x: p * 0.20, y: p * 0.62)); facets.line(to: NSPoint(x: p * 0.80, y: p * 0.62))
        facets.move(to: NSPoint(x: p * 0.34, y: p * 0.78)); facets.line(to: NSPoint(x: p * 0.40, y: p * 0.62))
        facets.line(to: NSPoint(x: p * 0.50, y: p * 0.20)); facets.line(to: NSPoint(x: p * 0.60, y: p * 0.62))
        facets.line(to: NSPoint(x: p * 0.66, y: p * 0.78)); facets.stroke()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode icon") }
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try data.write(to: output.appendingPathComponent(name))
    }
}

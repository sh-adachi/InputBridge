import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
func render(_ size: Int, name: String) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = AffineTransform(scale: CGFloat(size) / 1024)
    (transform as NSAffineTransform).concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 198, yRadius: 198)
    NSGradient(starting: NSColor(calibratedRed: 0.22, green: 0.56, blue: 1, alpha: 1), ending: NSColor(calibratedRed: 0.09, green: 0.21, blue: 0.55, alpha: 1))!.draw(in: background, angle: -90)
    func screen(_ rect: NSRect, main: Bool) {
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.18); shadow.shadowBlurRadius = 20; shadow.shadowOffset = NSSize(width: 0, height: -14)
        NSGraphicsContext.saveGraphicsState(); shadow.set()
        NSColor.white.withAlphaComponent(main ? 1 : 0.84).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 23, yRadius: 23).fill()
        NSGraphicsContext.restoreGraphicsState()
        let inner = rect.insetBy(dx: 15, dy: 15)
        NSColor(calibratedRed: 0.15, green: 0.38, blue: 0.78, alpha: 1).setFill()
        NSBezierPath(roundedRect: inner, xRadius: 10, yRadius: 10).fill()
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.midX - 12, y: rect.minY - 57, width: 24, height: 57), xRadius: 3, yRadius: 3).fill()
        NSBezierPath(roundedRect: NSRect(x: rect.midX - 66, y: rect.minY - 66, width: 132, height: 15), xRadius: 7, yRadius: 7).fill()
    }
    screen(NSRect(x: 167, y: 365, width: 313, height: 235), main: false)
    screen(NSRect(x: 512, y: 365, width: 343, height: 258), main: true)
    let path = NSBezierPath(); path.move(to: NSPoint(x: 603, y: 486)); path.line(to: NSPoint(x: 658, y: 438)); path.line(to: NSPoint(x: 760, y: 546))
    NSColor(calibratedRed: 0.6, green: 1, blue: 0.87, alpha: 1).setStroke(); path.lineWidth = 22; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
}
for points in [16, 32, 128, 256, 512] {
    try render(points, name: "icon_\(points)x\(points).png")
    try render(points * 2, name: "icon_\(points)x\(points)@2x.png")
}

import AppKit
import Foundation

let sizes = [20, 29, 40, 58, 60, 76, 80, 87, 120, 152, 167, 180, 1024]
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Relay/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: nil)

for size in sizes {
    let canvas = CGFloat(size)
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()

    NSColor(calibratedRed: 0.075, green: 0.075, blue: 0.075, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: canvas, height: canvas)).fill()

    let path = NSBezierPath()
    path.lineWidth = max(2, canvas * 0.075)
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: NSPoint(x: canvas * 0.29, y: canvas * 0.66))
    path.line(to: NSPoint(x: canvas * 0.51, y: canvas * 0.50))
    path.line(to: NSPoint(x: canvas * 0.29, y: canvas * 0.34))
    path.move(to: NSPoint(x: canvas * 0.55, y: canvas * 0.34))
    path.line(to: NSPoint(x: canvas * 0.72, y: canvas * 0.34))
    NSColor.white.setStroke()
    path.stroke()

    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not render icon \(size)")
    }
    try png.write(to: output.appendingPathComponent("icon-\(size).png"))
}

print("Generated \(sizes.count) Relay app icons.")

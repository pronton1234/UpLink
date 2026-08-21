// Draws the Mac app icon.
//
// A script rather than a checked-in binary blob, so the mark can be adjusted
// and regenerated rather than redrawn by hand — and so the geometry is
// reviewable like anything else.
//
//   swift scripts/make-mac-icon.swift <output-dir>
//
// The mark is the same chevron the iOS icon uses, with signal arcs added above
// it. The chevron alone reads as an upward arrow; the arcs are what make it
// read as broadcasting, which is what the Mac now does — it hosts the network
// rather than waiting on a cable.
import AppKit

let side = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

let image = NSImage(size: NSSize(width: side, height: side))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// macOS icons sit inside a rounded square with breathing room, unlike iOS
// where the system masks a full-bleed image.
let inset = side * 0.08
let plate = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
let platePath = CGPath(roundedRect: plate, cornerWidth: side * 0.185, cornerHeight: side * 0.185, transform: nil)
ctx.addPath(platePath)
ctx.setFillColor(NSColor(red: 0.055, green: 0.055, blue: 0.075, alpha: 1).cgColor)
ctx.fillPath()

ctx.addPath(platePath)
ctx.clip()

let blue = NSColor(red: 0.35, green: 0.62, blue: 0.98, alpha: 1).cgColor
let violet = NSColor(red: 0.55, green: 0.42, blue: 0.98, alpha: 1).cgColor
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [blue, violet] as CFArray, locations: [0, 1]
)!

/// Strokes a path with the brand gradient by clipping to the stroked shape.
func strokeGradient(_ path: CGPath, width: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: side * 0.25, y: side * 0.85),
        end: CGPoint(x: side * 0.75, y: side * 0.2),
        options: []
    )
    ctx.restoreGState()
}

// The chevron, sitting low so the arcs have room above it.
let chevron = CGMutablePath()
chevron.move(to: CGPoint(x: side * 0.28, y: side * 0.30))
chevron.addLine(to: CGPoint(x: side * 0.50, y: side * 0.53))
chevron.addLine(to: CGPoint(x: side * 0.72, y: side * 0.30))
strokeGradient(chevron, width: side * 0.105)

// Three arcs, widening upward: the signal leaving the machine.
for (i, radius) in [0.20, 0.30, 0.40].enumerated() {
    let arc = CGMutablePath()
    arc.addArc(
        center: CGPoint(x: side * 0.50, y: side * 0.50),
        radius: side * radius,
        startAngle: .pi * 0.18, endAngle: .pi * 0.82,
        clockwise: false
    )
    // Thinner as they travel, so the eye reads direction rather than a target.
    strokeGradient(arc, width: side * (0.075 - Double(i) * 0.013))
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: "\(out)/icon-1024.png"))
print("wrote \(out)/icon-1024.png")

// Generates the app icon PNG (1024x1024): a juice glass whose fill level echoes
// the "how much is left" metaphor. Usage: swift make-icon.swift <output.png>
//
// To rebuild AppIcon.icns from the PNG:
//   mkdir AppIcon.iconset
//   for s in 16 32 128 256 512; do
//     sips -z $s $s icon-1024.png --out AppIcon.iconset/icon_${s}x${s}.png
//     sips -z $((s*2)) $((s*2)) icon-1024.png --out AppIcon.iconset/icon_${s}x${s}@2x.png
//   done
//   iconutil -c icns AppIcon.iconset -o AppIcon.icns
import AppKit

let size = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Rounded-rect tile, macOS icon grid (~10% inset)
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1).setFill()  // terracotta
tilePath.fill()

let cream = NSColor(calibratedRed: 1.0, green: 0.96, blue: 0.92, alpha: 1)

// Glass: a slightly tapered cup (y-up coordinates)
func cupPath(inset: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: 352 + inset, y: 750 - inset))
    p.line(to: NSPoint(x: 672 - inset, y: 750 - inset))
    p.line(to: NSPoint(x: 634 - inset, y: 366 + inset))
    p.curve(to: NSPoint(x: 594 - inset, y: 330 + inset),
            controlPoint1: NSPoint(x: 632 - inset, y: 344 + inset),
            controlPoint2: NSPoint(x: 616 - inset, y: 330 + inset))
    p.line(to: NSPoint(x: 430 + inset, y: 330 + inset))
    p.curve(to: NSPoint(x: 390 + inset, y: 366 + inset),
            controlPoint1: NSPoint(x: 408 + inset, y: 330 + inset),
            controlPoint2: NSPoint(x: 392 + inset, y: 344 + inset))
    p.close()
    return p
}

// Juice fill: clip to the cup interior, fill up to ~65%, wavy surface
NSGraphicsContext.saveGraphicsState()
cupPath(inset: 34).setClip()
let level: CGFloat = 592
let juice = NSBezierPath()
juice.move(to: NSPoint(x: 340, y: level))
juice.curve(to: NSPoint(x: 512, y: level),
            controlPoint1: NSPoint(x: 400, y: level + 26),
            controlPoint2: NSPoint(x: 455, y: level + 26))
juice.curve(to: NSPoint(x: 684, y: level),
            controlPoint1: NSPoint(x: 570, y: level - 26),
            controlPoint2: NSPoint(x: 626, y: level - 26))
juice.line(to: NSPoint(x: 684, y: 300))
juice.line(to: NSPoint(x: 340, y: 300))
juice.close()
cream.setFill()
juice.fill()
NSGraphicsContext.restoreGraphicsState()

// Straw, drawn under the glass rim stroke
let straw = NSBezierPath()
straw.move(to: NSPoint(x: 566, y: 640))
straw.line(to: NSPoint(x: 692, y: 884))
straw.lineWidth = 42
straw.lineCapStyle = .round
cream.setStroke()
straw.stroke()

// Glass outline on top
let cup = cupPath(inset: 0)
cup.lineWidth = 34
cup.lineJoinStyle = .round
cream.setStroke()
cup.stroke()

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

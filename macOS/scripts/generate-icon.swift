import AppKit

// Draws the Prism app icon: the mark on an Ink tile, in the macOS icon grid (824pt tile, 22% radius).
// Mark geometry matches PrismMark in Sources/RelioApp/Theme.swift.
guard CommandLine.arguments.count == 2 else { fatalError("Usage: generate-icon.swift output.png") }
let size = 1024
guard let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
      let graphics = NSGraphicsContext(bitmapImageRep: representation) else { fatalError("Could not create icon bitmap") }

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
color(0x0E0F14).setFill()
NSBezierPath(roundedRect: tile, xRadius: 824 * 0.22, yRadius: 824 * 0.22).fill()

// The mark takes 58% of the tile's height, centered, as on the brand card.
let markHeight = tile.height * 0.58
let markWidth = markHeight * 184 / 202
let origin = CGPoint(x: tile.midX - markWidth / 2, y: tile.midY - markHeight / 2)
// Unit coordinates are top-down; AppKit's y axis points up.
func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * markWidth, y: origin.y + (1 - y) * markHeight) }
let apex = point(0.5, 0), left = point(0, 0.797), right = point(1, 0.797)
let center = point(0.5, 0.545), bottom = point(0.5, 1)
func face(_ points: [CGPoint], _ fill: NSColor) {
    let path = NSBezierPath()
    path.move(to: points[0])
    points.dropFirst().forEach { path.line(to: $0) }
    path.close()
    fill.setFill()
    path.fill()
}
face([apex, left, center], color(0xFFC233))   // Amber
face([apex, right, center], color(0xFF6B57))  // Coral
face([left, center, right], color(0x3FA9F5))  // Sky
face([left, right, bottom], color(0x3996DA))  // Sky with 12% Ink
graphics.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = representation.representation(using: .png, properties: [:]) else { fatalError("Could not encode icon") }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)

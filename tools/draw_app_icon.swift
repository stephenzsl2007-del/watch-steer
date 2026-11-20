import AppKit
let destination = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(calibratedRed: 0.10, green: 0.18, blue: 0.13, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 20, y: 20, width: 984, height: 984), xRadius: 220, yRadius: 220).fill()
NSColor(calibratedRed: 0.77, green: 0.96, blue: 0.64, alpha: 1).setStroke()
let ring = NSBezierPath(ovalIn: NSRect(x: 200, y: 200, width: 624, height: 624)); ring.lineWidth = 66; ring.stroke()
for angle in [Double.pi/6, Double.pi*5/6, -Double.pi/2] {
 let p = NSBezierPath(); p.move(to: NSPoint(x: 512, y: 512)); p.line(to: NSPoint(x: 512 + cos(angle)*280, y: 512 + sin(angle)*280)); p.lineWidth = 46; p.lineCapStyle = .round; p.stroke()
}
NSColor(calibratedRed: 0.77, green: 0.96, blue: 0.64, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 432, y: 432, width: 160, height: 160)).fill()
image.unlockFocus()
try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))

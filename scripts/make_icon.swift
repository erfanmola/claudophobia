import AppKit

// Generates the Claudophobia app icon (gradient tile + usage ring) as an
// .iconset, ready for `iconutil -c icns`.
//
// Usage: make_icon <output-iconset-dir>

func drawIcon(size: CGFloat) -> NSImage {
   let image = NSImage(size: NSSize(width: size, height: size))
   image.lockFocus()

   let rect = NSRect(x: 0, y: 0, width: size, height: size)
   let corner = size * 0.2237
   let tile = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)

   let gradient = NSGradient(colors: [
      NSColor(calibratedRed: 0.93, green: 0.55, blue: 0.38, alpha: 1),
      NSColor(calibratedRed: 0.78, green: 0.38, blue: 0.28, alpha: 1),
   ])!
   gradient.draw(in: tile, angle: -55)

   let center = NSPoint(x: size * 0.5, y: size * 0.5)
   let radius = size * 0.29
   let lineWidth = size * 0.06

   // Track
   let track = NSBezierPath(
      ovalIn: NSRect(
         x: center.x - radius, y: center.y - radius,
         width: radius * 2, height: radius * 2
      ))
   track.lineWidth = lineWidth
   NSColor.white.withAlphaComponent(0.22).setStroke()
   track.stroke()

   // Progress arc (65%)
   let progress: CGFloat = 0.65
   let arc = NSBezierPath()
   arc.appendArc(
      withCenter: center, radius: radius,
      startAngle: 90, endAngle: 90 - progress * 360,
      clockwise: true
   )
   arc.lineWidth = lineWidth
   arc.lineCapStyle = .round
   NSColor.white.withAlphaComponent(0.95).setStroke()
   arc.stroke()

   // Center dot
   let dotSize = size * 0.045
   let dot = NSBezierPath(
      ovalIn: NSRect(
         x: center.x - dotSize / 2, y: center.y - dotSize / 2,
         width: dotSize, height: dotSize
      ))
   NSColor.white.setFill()
   dot.fill()

   image.unlockFocus()
   return image
}

func writePNG(_ image: NSImage, to url: URL) {
   guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
   else {
      fputs("failed to encode \(url.path)\n", stderr)
      return
   }
   try? png.write(to: url)
}

guard CommandLine.arguments.count == 2 else {
   fputs("usage: make_icon <output-iconset-dir>\n", stderr)
   exit(1)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let sizes: [(name: String, points: CGFloat)] = [
   ("icon_16x16", 16),
   ("icon_16x16@2x", 32),
   ("icon_32x32", 32),
   ("icon_32x32@2x", 64),
   ("icon_128x128", 128),
   ("icon_128x128@2x", 256),
   ("icon_256x256", 256),
   ("icon_256x256@2x", 512),
   ("icon_512x512", 512),
   ("icon_512x512@2x", 1024),
]

for item in sizes {
   let image = drawIcon(size: item.points)
   writePNG(image, to: outDir.appendingPathComponent("\(item.name).png"))
}

print("wrote iconset to \(outDir.path)")

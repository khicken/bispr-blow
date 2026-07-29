// Renders icon-1024.png (Bluejay-blue squircle + white mark, macOS 10% inset).
//   swift make-icon.swift
//   mkdir AppIcon.iconset
//   for s in 16 32 128 256 512; do
//     sips -z $s $s icon-1024.png --out AppIcon.iconset/icon_${s}x${s}.png
//     sips -z $((s*2)) $((s*2)) icon-1024.png --out AppIcon.iconset/icon_${s}x${s}@2x.png
//   done
//   iconutil -c icns AppIcon.iconset -o AppIcon.icns && rm -rf AppIcon.iconset
import AppKit

let S = 1024
let side = CGFloat(S)
let inset = side * 0.10
let plate = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)

// Explicit 1024x1024 bitmap — NSImage.lockFocus would give a 2x retina rep.
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
let ctx = NSGraphicsContext.current!.cgContext

let squircle = NSBezierPath(roundedRect: plate,
                           xRadius: plate.width * 0.224,
                           yRadius: plate.width * 0.224)

// No baked plate shadow — macOS draws its own behind app icons.
squircle.addClip()

// Vertical brand gradient: #0B2A45 bottom → #1FA2FF top.
NSGradient(colors: [NSColor(srgbRed: 0.043, green: 0.165, blue: 0.271, alpha: 1),
                    NSColor(srgbRed: 0.122, green: 0.635, blue: 1.0, alpha: 1)],
           atLocations: [0, 1], colorSpace: .sRGB)!
    .draw(in: plate, angle: 96)

// Restrained sheen across the top edge.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)],
           atLocations: [0, 1], colorSpace: .sRGB)!
    .draw(in: plate, relativeCenterPosition: NSPoint(x: -0.2, y: 0.9))

// Mark, centered, with a soft lift.
let svg = URL(fileURLWithPath: "Sources/BluejayWispr/Resources/Symbol_White.svg")
guard let mark = NSImage(contentsOf: svg) else { fatalError("missing \(svg.path)") }
let w = plate.width * 0.58
let h = w * (mark.size.height / mark.size.width)
ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.006), blur: side * 0.022,
              color: NSColor(srgbRed: 0, green: 0.06, blue: 0.15, alpha: 0.32).cgColor)
mark.draw(in: NSRect(x: plate.midX - w / 2, y: plate.midY - h / 2, width: w, height: h))

NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "icon-1024.png"))
print("wrote icon-1024.png (\(S)x\(S))")

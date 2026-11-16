// Renders design/logo/icon-tile-blue.svg at every .iconset size and builds AppIcon.icns.
//   swift make-icon.swift
// Each size is drawn from the vector, not downscaled from 1024, so 16 and 32 stay sharp.
import AppKit

let svg = URL(fileURLWithPath: "design/logo/icon-tile-blue.svg")
guard let tile = NSImage(contentsOf: svg) else { fatalError("missing \(svg.path)") }
let set = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

for s in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = s * scale
        // Explicit bitmap: NSImage.lockFocus would give a 2x retina rep.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current!.imageInterpolation = .high
        tile.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(s)x\(s)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!
            .write(to: set.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", set.path, "-o", "AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try FileManager.default.removeItem(at: set)
print("wrote AppIcon.icns")

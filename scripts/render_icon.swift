import Cocoa

guard CommandLine.arguments.count >= 4 else {
    FileHandle.standardError.write("Usage: render_icon <svg> <size> <out.png>\n".data(using: .utf8)!)
    exit(1)
}

let svgURL = URL(fileURLWithPath: CommandLine.arguments[1])
let size = Int(CommandLine.arguments[2]) ?? 1024
let outURL = URL(fileURLWithPath: CommandLine.arguments[3])

guard let img = NSImage(contentsOf: svgURL) else {
    FileHandle.standardError.write("Failed to load SVG\n".data(using: .utf8)!)
    exit(1)
}
img.size = NSSize(width: size, height: size)

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }

bitmap.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
img.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
         from: .zero, operation: .copy, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: outURL)
print("wrote \(outURL.path) (\(size)x\(size))")

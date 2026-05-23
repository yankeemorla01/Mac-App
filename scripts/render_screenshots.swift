import Cocoa
import CoreGraphics
import CoreText

// MARK: - Canvas constants

let CANVAS_W: CGFloat = 2880
let CANVAS_H: CGFloat = 1800

// Brand colors
let NAVY     = NSColor(srgbRed: 0x1e/255.0, green: 0x3a/255.0, blue: 0x8a/255.0, alpha: 1)
let DEEP     = NSColor(srgbRed: 0x3b/255.0, green: 0x82/255.0, blue: 0xf6/255.0, alpha: 1)
let BLACK_T  = NSColor(srgbRed: 0.02, green: 0.04, blue: 0.10, alpha: 1)
let LIGHT_FG = NSColor(srgbRed: 0xe6/255.0, green: 0xeb/255.0, blue: 0xf5/255.0, alpha: 1)
let SUBTITLE = NSColor(srgbRed: 0x9a/255.0, green: 0xa3/255.0, blue: 0xb8/255.0, alpha: 1)

// Path inputs
let outDir = "/Users/josecasadogenao/Mac App/assets/appstore/needed"
let iconPath = "/Users/josecasadogenao/Mac App/site/img/icon-512.png"

// MARK: - Helpers

func makeContext() -> (NSBitmapImageRep, CGContext) {
    let w = Int(CANVAS_W)
    let h = Int(CANVAS_H)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("Failed to make bitmap") }
    let gc = NSGraphicsContext(bitmapImageRep: bitmap)!
    let cg = gc.cgContext
    return (bitmap, cg)
}

func push(_ cg: CGContext) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
    cg.saveGState()
}
func pop(_ cg: CGContext) {
    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
}

func drawBackground(_ cg: CGContext) {
    // Vertical gradient: deep navy top -> near-black bottom
    let cs = CGColorSpaceCreateDeviceRGB()
    let topColor    = NSColor(srgbRed: 0.08, green: 0.13, blue: 0.30, alpha: 1).cgColor
    let midColor    = NSColor(srgbRed: 0.04, green: 0.07, blue: 0.18, alpha: 1).cgColor
    let bottomColor = NSColor(srgbRed: 0.01, green: 0.02, blue: 0.06, alpha: 1).cgColor
    let grad = CGGradient(colorsSpace: cs,
                          colors: [topColor, midColor, bottomColor] as CFArray,
                          locations: [0.0, 0.55, 1.0])!
    cg.drawLinearGradient(grad,
                          start: CGPoint(x: CANVAS_W/2, y: CANVAS_H),
                          end:   CGPoint(x: CANVAS_W/2, y: 0),
                          options: [])

    // Radial accent — soft blue glow from upper-right
    let glow = CGGradient(colorsSpace: cs,
                          colors: [
                              NSColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 0.35).cgColor,
                              NSColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 0.0).cgColor
                          ] as CFArray,
                          locations: [0.0, 1.0])!
    cg.drawRadialGradient(glow,
                          startCenter: CGPoint(x: CANVAS_W * 0.78, y: CANVAS_H * 0.78),
                          startRadius: 0,
                          endCenter:   CGPoint(x: CANVAS_W * 0.78, y: CANVAS_H * 0.78),
                          endRadius:   1300,
                          options: [])
    // Secondary glow lower-left
    let glow2 = CGGradient(colorsSpace: cs,
                           colors: [
                               NSColor(srgbRed: 0.12, green: 0.25, blue: 0.65, alpha: 0.28).cgColor,
                               NSColor(srgbRed: 0.12, green: 0.25, blue: 0.65, alpha: 0.0).cgColor
                           ] as CFArray,
                           locations: [0.0, 1.0])!
    cg.drawRadialGradient(glow2,
                          startCenter: CGPoint(x: CANVAS_W * 0.15, y: CANVAS_H * 0.18),
                          startRadius: 0,
                          endCenter:   CGPoint(x: CANVAS_W * 0.15, y: CANVAS_H * 0.18),
                          endRadius:   1100,
                          options: [])
}

func drawTitle(_ cg: CGContext, title: String, subtitle: String) {
    let titleFont = NSFont.systemFont(ofSize: 96, weight: .bold)
    let subFont   = NSFont.systemFont(ofSize: 38, weight: .regular)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    shadow.shadowOffset = NSSize(width: 0, height: -4)
    shadow.shadowBlurRadius = 20

    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: titleFont,
        .foregroundColor: NSColor.white,
        .kern: -1.2,
        .shadow: shadow
    ]
    let subAttrs: [NSAttributedString.Key: Any] = [
        .font: subFont,
        .foregroundColor: SUBTITLE,
        .kern: 0.2
    ]

    let titleStr = NSAttributedString(string: title, attributes: titleAttrs)
    let subStr   = NSAttributedString(string: subtitle, attributes: subAttrs)

    push(cg)
    // Title sits near the top of canvas, above the MacBook frame
    let titleSize = titleStr.size()
    let subSize   = subStr.size()
    // Place title baseline so top of title is around y = CANVAS_H - 120
    let titleY = CANVAS_H - 120 - titleSize.height
    let subY   = titleY - subSize.height - 20
    titleStr.draw(at: NSPoint(x: (CANVAS_W - titleSize.width)/2, y: titleY))
    subStr.draw(at: NSPoint(x: (CANVAS_W - subSize.width)/2, y: subY))
    pop(cg)
}

func drawShadowedRect(_ cg: CGContext, rect: CGRect, radius: CGFloat,
                      fill: NSColor, shadowOpacity: CGFloat = 0.55,
                      shadowBlur: CGFloat = 60, shadowOffset: CGSize = CGSize(width: 0, height: -18)) {
    push(cg)
    cg.setShadow(offset: shadowOffset,
                 blur: shadowBlur,
                 color: NSColor.black.withAlphaComponent(shadowOpacity).cgColor)
    cg.setFillColor(fill.cgColor)
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    cg.addPath(path)
    cg.fillPath()
    pop(cg)
}

func clipToRoundedRect(_ cg: CGContext, rect: CGRect, radius: CGFloat) {
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    cg.addPath(path)
    cg.clip()
}

func drawText(_ s: String, at p: CGPoint, font: NSFont, color: NSColor, kern: CGFloat = 0) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: color, .kern: kern
    ]
    NSAttributedString(string: s, attributes: attrs).draw(at: p)
}

func drawTextRight(_ s: String, rightX: CGFloat, y: CGFloat, font: NSFont, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let str = NSAttributedString(string: s, attributes: attrs)
    let sz = str.size()
    str.draw(at: NSPoint(x: rightX - sz.width, y: y))
}

func writePNG(_ bitmap: NSBitmapImageRep, to path: String) {
    // Drop alpha for App Store (no transparency)
    guard let cgImage = bitmap.cgImage else { fatalError("no cgImage") }
    let w = cgImage.width
    let h = cgImage.height
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: w, height: h,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
    let finalCG = ctx.makeImage()!
    let finalBitmap = NSBitmapImageRep(cgImage: finalCG)
    guard let data = finalBitmap.representation(using: .png, properties: [.interlaced: false]) else {
        fatalError("PNG encode failed")
    }
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(w)x\(h), \(data.count) bytes)")
}

// MARK: - MacBook frame

/// Layout returned by drawMacBookFrame so screen content can be drawn inside.
struct MacBookLayout {
    let screenContentRect: CGRect      // The drawable area inside the screen bezel
    let screenBezelRect: CGRect        // The whole black bezel including notch
    let bodyRect: CGRect               // The whole lid rect (silver)
    let baseRect: CGRect               // The trapezoidal keyboard base footprint
}

/// Draws a MacBook (closed-style laptop, lid open, viewed head-on) centered at `centerX`
/// with the lid's bottom-edge at `bottomY`. Returns the inner screen content rect for caller to draw into.
@discardableResult
func drawMacBookFrame(_ cg: CGContext, centerX: CGFloat, bottomY: CGFloat, lidWidth: CGFloat) -> MacBookLayout {
    // Proportions roughly match a MacBook Pro 14"/16"
    let aspect: CGFloat = 0.66            // lid height / lid width
    let lidH = lidWidth * aspect
    let lidX = centerX - lidWidth/2
    let lidRect = CGRect(x: lidX, y: bottomY, width: lidWidth, height: lidH)

    // Ground shadow (large soft ellipse beneath the laptop)
    push(cg)
    let shadowRect = CGRect(x: lidRect.minX - 80,
                            y: bottomY - 60,
                            width: lidRect.width + 160,
                            height: 90)
    cg.setShadow(offset: CGSize(width: 0, height: -10),
                 blur: 80,
                 color: NSColor.black.withAlphaComponent(0.55).cgColor)
    cg.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
    cg.fillEllipse(in: shadowRect)
    pop(cg)

    // Keyboard base (a trapezoid + thin lip) drawn just below the lid
    let baseTopY = bottomY                // top of base flush with bottom of lid
    let baseH: CGFloat = lidWidth * 0.022 // overall base height (thin slab)
    let baseInset: CGFloat = lidWidth * 0.020
    let basePath = CGMutablePath()
    let baseTopL = CGPoint(x: lidRect.minX - 8, y: baseTopY)
    let baseTopR = CGPoint(x: lidRect.maxX + 8, y: baseTopY)
    let baseBotL = CGPoint(x: lidRect.minX - 8 - baseInset, y: baseTopY - baseH)
    let baseBotR = CGPoint(x: lidRect.maxX + 8 + baseInset, y: baseTopY - baseH)
    basePath.move(to: baseTopL)
    basePath.addLine(to: baseTopR)
    basePath.addLine(to: baseBotR)
    basePath.addLine(to: baseBotL)
    basePath.closeSubpath()

    push(cg)
    // Aluminum gradient for base (slightly darker than lid, gives perspective)
    let cs = CGColorSpaceCreateDeviceRGB()
    let baseGrad = CGGradient(colorsSpace: cs, colors: [
        NSColor(srgbRed: 0.78, green: 0.78, blue: 0.80, alpha: 1).cgColor,
        NSColor(srgbRed: 0.62, green: 0.62, blue: 0.65, alpha: 1).cgColor,
        NSColor(srgbRed: 0.50, green: 0.50, blue: 0.54, alpha: 1).cgColor
    ] as CFArray, locations: [0.0, 0.55, 1.0])!
    cg.addPath(basePath)
    cg.clip()
    cg.drawLinearGradient(baseGrad,
                          start: CGPoint(x: 0, y: baseTopY),
                          end:   CGPoint(x: 0, y: baseTopY - baseH),
                          options: [])
    pop(cg)

    // Indent (the small notch in the keyboard-base front lip where you open the lid)
    push(cg)
    let indentW = lidWidth * 0.10
    let indentH: CGFloat = 8
    let indentRect = CGRect(x: centerX - indentW/2,
                            y: baseTopY - 2,
                            width: indentW, height: indentH)
    cg.setFillColor(NSColor(srgbRed: 0.42, green: 0.42, blue: 0.46, alpha: 1).cgColor)
    cg.addPath(CGPath(roundedRect: indentRect, cornerWidth: 3, cornerHeight: 3, transform: nil))
    cg.fillPath()
    pop(cg)

    // --- Lid: aluminum body with rounded corners ---
    let lidRadius: CGFloat = 22
    push(cg)
    cg.setShadow(offset: CGSize(width: 0, height: -24),
                 blur: 90,
                 color: NSColor.black.withAlphaComponent(0.50).cgColor)
    let lidGrad = CGGradient(colorsSpace: cs, colors: [
        NSColor(srgbRed: 0.85, green: 0.85, blue: 0.87, alpha: 1).cgColor,
        NSColor(srgbRed: 0.78, green: 0.78, blue: 0.80, alpha: 1).cgColor,
        NSColor(srgbRed: 0.72, green: 0.72, blue: 0.75, alpha: 1).cgColor
    ] as CFArray, locations: [0.0, 0.5, 1.0])!
    let lidPath = CGPath(roundedRect: lidRect, cornerWidth: lidRadius, cornerHeight: lidRadius, transform: nil)
    cg.addPath(lidPath)
    cg.clip()
    cg.drawLinearGradient(lidGrad,
                          start: CGPoint(x: lidRect.minX, y: lidRect.maxY),
                          end:   CGPoint(x: lidRect.maxX, y: lidRect.minY),
                          options: [])
    pop(cg)

    // Subtle top highlight on the lid (specular)
    push(cg)
    cg.addPath(CGPath(roundedRect: lidRect, cornerWidth: lidRadius, cornerHeight: lidRadius, transform: nil))
    cg.clip()
    let hiGrad = CGGradient(colorsSpace: cs, colors: [
        NSColor.white.withAlphaComponent(0.25).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor
    ] as CFArray, locations: [0.0, 1.0])!
    cg.drawLinearGradient(hiGrad,
                          start: CGPoint(x: 0, y: lidRect.maxY),
                          end:   CGPoint(x: 0, y: lidRect.maxY - 60),
                          options: [])
    pop(cg)

    // Outer rim stroke
    push(cg)
    cg.setStrokeColor(NSColor.black.withAlphaComponent(0.30).cgColor)
    cg.setLineWidth(1.5)
    cg.addPath(CGPath(roundedRect: lidRect, cornerWidth: lidRadius, cornerHeight: lidRadius, transform: nil))
    cg.strokePath()
    pop(cg)

    // --- Black bezel inside the lid ---
    let bezelInset: CGFloat = lidWidth * 0.022
    let bezelRect = lidRect.insetBy(dx: bezelInset, dy: bezelInset)
    let bezelRadius: CGFloat = 14
    push(cg)
    cg.setFillColor(NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).cgColor)
    cg.addPath(CGPath(roundedRect: bezelRect, cornerWidth: bezelRadius, cornerHeight: bezelRadius, transform: nil))
    cg.fillPath()
    pop(cg)

    // Notch at the top center of the bezel (MacBook Pro 14"/16" 2021+)
    let notchW: CGFloat = 220
    let notchH: CGFloat = 32
    let notchRect = CGRect(x: bezelRect.midX - notchW/2,
                           y: bezelRect.maxY - notchH,
                           width: notchW, height: notchH)
    push(cg)
    cg.setFillColor(NSColor(srgbRed: 0.06, green: 0.06, blue: 0.07, alpha: 1).cgColor)
    // Notch is rounded only on the bottom (it cuts into the bezel)
    let notchPath = CGMutablePath()
    let nr: CGFloat = 12
    notchPath.move(to: CGPoint(x: notchRect.minX, y: notchRect.maxY))
    notchPath.addLine(to: CGPoint(x: notchRect.maxX, y: notchRect.maxY))
    notchPath.addLine(to: CGPoint(x: notchRect.maxX, y: notchRect.minY + nr))
    notchPath.addQuadCurve(to: CGPoint(x: notchRect.maxX - nr, y: notchRect.minY),
                           control: CGPoint(x: notchRect.maxX, y: notchRect.minY))
    notchPath.addLine(to: CGPoint(x: notchRect.minX + nr, y: notchRect.minY))
    notchPath.addQuadCurve(to: CGPoint(x: notchRect.minX, y: notchRect.minY + nr),
                           control: CGPoint(x: notchRect.minX, y: notchRect.minY))
    notchPath.closeSubpath()
    cg.addPath(notchPath); cg.fillPath()
    // tiny camera dot
    cg.setFillColor(NSColor(srgbRed: 0.15, green: 0.15, blue: 0.18, alpha: 1).cgColor)
    cg.fillEllipse(in: CGRect(x: notchRect.midX - 4, y: notchRect.midY - 4, width: 8, height: 8))
    pop(cg)

    // --- Screen content area (live UI goes here) ---
    // Screen content fills the bezel except a few px inset for the inner glass edge.
    let glassInset: CGFloat = 6
    let screenContentRect = bezelRect.insetBy(dx: glassInset, dy: glassInset)

    return MacBookLayout(
        screenContentRect: screenContentRect,
        screenBezelRect: bezelRect,
        bodyRect: lidRect,
        baseRect: CGRect(x: baseBotL.x, y: baseBotL.y,
                         width: baseBotR.x - baseBotL.x, height: baseH)
    )
}

// MARK: - Fake desktop wallpaper drawn INSIDE the laptop screen

func drawScreenWallpaper(_ cg: CGContext, in rect: CGRect) {
    push(cg)
    clipToRoundedRect(cg, rect: rect, radius: 8)
    let cs = CGColorSpaceCreateDeviceRGB()
    // Base gradient: dark navy → black, like macOS Sonoma "Macintosh" wallpaper-ish
    let g = CGGradient(colorsSpace: cs, colors: [
        NSColor(srgbRed: 0.08, green: 0.10, blue: 0.20, alpha: 1).cgColor,
        NSColor(srgbRed: 0.03, green: 0.04, blue: 0.10, alpha: 1).cgColor
    ] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(g,
                          start: CGPoint(x: rect.minX, y: rect.maxY),
                          end:   CGPoint(x: rect.maxX, y: rect.minY),
                          options: [])
    // Soft purple+blue radial accents
    let g1 = CGGradient(colorsSpace: cs, colors: [
        NSColor(srgbRed: 0.30, green: 0.45, blue: 0.95, alpha: 0.55).cgColor,
        NSColor(srgbRed: 0.10, green: 0.18, blue: 0.45, alpha: 0.0).cgColor
    ] as CFArray, locations: [0, 1])!
    cg.drawRadialGradient(g1,
                          startCenter: CGPoint(x: rect.minX + rect.width*0.3, y: rect.minY + rect.height*0.4),
                          startRadius: 0,
                          endCenter:   CGPoint(x: rect.minX + rect.width*0.3, y: rect.minY + rect.height*0.4),
                          endRadius:   rect.width*0.5, options: [])
    let g2 = CGGradient(colorsSpace: cs, colors: [
        NSColor(srgbRed: 0.55, green: 0.25, blue: 0.85, alpha: 0.40).cgColor,
        NSColor(srgbRed: 0.10, green: 0.05, blue: 0.30, alpha: 0.0).cgColor
    ] as CFArray, locations: [0, 1])!
    cg.drawRadialGradient(g2,
                          startCenter: CGPoint(x: rect.minX + rect.width*0.75, y: rect.minY + rect.height*0.65),
                          startRadius: 0,
                          endCenter:   CGPoint(x: rect.minX + rect.width*0.75, y: rect.minY + rect.height*0.65),
                          endRadius:   rect.width*0.45, options: [])
    pop(cg)
}

// MARK: - Camera icon (the menu bar icon)

func drawCameraIcon(_ cg: CGContext, in rect: CGRect, color: NSColor = NSColor.white) {
    push(cg)
    cg.setStrokeColor(color.cgColor)
    cg.setFillColor(color.cgColor)
    let body = CGRect(x: rect.minX + rect.width*0.05,
                      y: rect.minY + rect.height*0.18,
                      width: rect.width*0.9,
                      height: rect.height*0.65)
    let path = CGMutablePath()
    path.addRoundedRect(in: body, cornerWidth: rect.width*0.10, cornerHeight: rect.width*0.10)
    cg.addPath(path)
    cg.fillPath()

    cg.setFillColor(NAVY.cgColor)
    let lensR = rect.width * 0.20
    let cx = rect.midX
    let cy = rect.midY - rect.height*0.02
    cg.fillEllipse(in: CGRect(x: cx - lensR, y: cy - lensR, width: lensR*2, height: lensR*2))

    cg.setFillColor(color.cgColor)
    let lensR2 = lensR * 0.40
    cg.fillEllipse(in: CGRect(x: cx - lensR2, y: cy - lensR2, width: lensR2*2, height: lensR2*2))

    cg.setFillColor(color.cgColor)
    let bumpW = rect.width*0.28
    let bumpH = rect.height*0.10
    let bumpRect = CGRect(x: rect.midX - bumpW/2,
                          y: rect.minY + rect.height*0.78,
                          width: bumpW, height: bumpH)
    let bp = CGPath(roundedRect: bumpRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
    cg.addPath(bp)
    cg.fillPath()
    pop(cg)
}

// MARK: - Status bar drawn inside a screen rect (top of macOS screen)

func drawMacOSStatusBar(_ cg: CGContext, in screenRect: CGRect, height: CGFloat,
                        highlightClipShot: Bool) {
    push(cg)
    let barRect = CGRect(x: screenRect.minX, y: screenRect.maxY - height,
                         width: screenRect.width, height: height)
    cg.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
    cg.fill(barRect)

    let menuFont = NSFont.systemFont(ofSize: height * 0.42, weight: .regular)
    let boldFont = NSFont.systemFont(ofSize: height * 0.42, weight: .semibold)
    let textColor = NSColor.white.withAlphaComponent(0.95)

    let baseY = barRect.minY + (height - menuFont.pointSize) / 2 - 2
    var x = screenRect.minX + 22
    // Apple logo
    drawText("\u{f8ff}", at: NSPoint(x: x, y: baseY - 2),
             font: NSFont.systemFont(ofSize: height * 0.55, weight: .regular),
             color: textColor)
    x += 38
    drawText("Finder", at: NSPoint(x: x, y: baseY), font: boldFont, color: textColor); x += 92
    drawText("File", at: NSPoint(x: x, y: baseY), font: menuFont, color: textColor); x += 56
    drawText("Edit", at: NSPoint(x: x, y: baseY), font: menuFont, color: textColor); x += 56
    drawText("View", at: NSPoint(x: x, y: baseY), font: menuFont, color: textColor); x += 64
    drawText("Go", at: NSPoint(x: x, y: baseY), font: menuFont, color: textColor); x += 40
    drawText("Window", at: NSPoint(x: x, y: baseY), font: menuFont, color: textColor); x += 100
    drawText("Help", at: NSPoint(x: x, y: baseY), font: menuFont, color: textColor)

    // Right cluster: wifi dots, battery, time
    let smallFont = NSFont.systemFont(ofSize: height * 0.40, weight: .regular)
    drawTextRight("Fri 12:34", rightX: screenRect.maxX - 22, y: baseY,
                  font: smallFont, color: textColor)
    drawTextRight("100%", rightX: screenRect.maxX - 160, y: baseY,
                  font: smallFont, color: textColor)
    drawTextRight("\u{2022}\u{2022}\u{2022}", rightX: screenRect.maxX - 250, y: baseY,
                  font: smallFont, color: textColor)

    // ClipShot status item position
    let iconSize: CGFloat = height * 0.62
    let iconX = screenRect.maxX - 360
    let iconRect = CGRect(x: iconX, y: barRect.midY - iconSize/2,
                          width: iconSize, height: iconSize)
    if highlightClipShot {
        push(cg)
        let hp = CGPath(roundedRect: iconRect.insetBy(dx: -6, dy: -4),
                        cornerWidth: 6, cornerHeight: 6, transform: nil)
        cg.setFillColor(NSColor.white.withAlphaComponent(0.25).cgColor)
        cg.addPath(hp); cg.fillPath()
        pop(cg)
    }
    drawCameraIcon(cg, in: iconRect, color: NSColor.white)
    pop(cg)
}

// MARK: - Screenshot 1: Menu bar with history dropdown (inside MacBook)

func renderScreenshot1() {
    let (bitmap, cg) = makeContext()
    push(cg)
    drawBackground(cg)

    // Title overlay (drawn first, so we can place MacBook below it)
    drawTitle(cg,
              title: "Your history, in the menu bar",
              subtitle: "Every screenshot, ready to re-copy in one click.")

    // MacBook frame — large, centered, fills most of remaining canvas
    let lidWidth: CGFloat = 1900
    let lidBottomY: CGFloat = 220
    let layout = drawMacBookFrame(cg, centerX: CANVAS_W/2, bottomY: lidBottomY, lidWidth: lidWidth)
    let screen = layout.screenContentRect

    // Draw the desktop wallpaper inside the screen
    drawScreenWallpaper(cg, in: screen)

    push(cg)
    clipToRoundedRect(cg, rect: screen, radius: 8)

    // Status bar at top of macOS screen
    let barH: CGFloat = 56
    drawMacOSStatusBar(cg, in: screen, height: barH, highlightClipShot: true)

    // ClipShot status item anchor (right side, mirror of drawMacOSStatusBar)
    let barRectMinY = screen.maxY - barH
    let iconAnchorX = screen.maxX - 360 + (barH * 0.62)/2

    // Dropdown menu under the status icon
    let menuW: CGFloat = 720
    let rowH: CGFloat = 88
    let headerH: CGFloat = 70
    let footerH: CGFloat = 300
    let menuH: CGFloat = headerH + rowH * 6 + footerH
    let menuX = iconAnchorX - menuW + 60
    let menuY = barRectMinY - menuH - 14

    // Triangle pointer
    push(cg)
    cg.setFillColor(NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1.0).cgColor)
    let tri = CGMutablePath()
    tri.move(to: CGPoint(x: iconAnchorX - 12, y: menuY + menuH))
    tri.addLine(to: CGPoint(x: iconAnchorX + 12, y: menuY + menuH))
    tri.addLine(to: CGPoint(x: iconAnchorX, y: menuY + menuH + 14))
    tri.closeSubpath()
    cg.addPath(tri); cg.fillPath()
    pop(cg)

    // Menu background
    drawShadowedRect(cg,
                     rect: CGRect(x: menuX, y: menuY, width: menuW, height: menuH),
                     radius: 16,
                     fill: NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1.0),
                     shadowOpacity: 0.55,
                     shadowBlur: 70,
                     shadowOffset: CGSize(width: 0, height: -20))

    push(cg)
    let menuRect = CGRect(x: menuX, y: menuY, width: menuW, height: menuH)
    clipToRoundedRect(cg, rect: menuRect, radius: 16)

    let labelColor = NSColor(srgbRed: 0.12, green: 0.14, blue: 0.20, alpha: 1)
    let dimColor   = NSColor(srgbRed: 0.40, green: 0.44, blue: 0.52, alpha: 1)
    let headerFont = NSFont.systemFont(ofSize: 20, weight: .semibold)
    let rowFont    = NSFont.systemFont(ofSize: 22, weight: .regular)
    let timeFont   = NSFont.systemFont(ofSize: 18, weight: .regular)
    let footerFont = NSFont.systemFont(ofSize: 22, weight: .regular)

    let headerY = menuY + menuH - 44
    drawText("ClipShot — Screenshot history",
             at: NSPoint(x: menuX + 26, y: headerY),
             font: headerFont, color: dimColor)

    push(cg)
    cg.setFillColor(NSColor.black.withAlphaComponent(0.08).cgColor)
    cg.fill(CGRect(x: menuX + 14, y: headerY - 16, width: menuW - 28, height: 1))
    pop(cg)

    // 6 history rows with English-locale timestamps
    let thumbW: CGFloat = 112
    let thumbH: CGFloat = 70
    let rowStartY = headerY - 16 - 12

    let times: [(String, NSColor)] = [
        ("5/23/26, 4:32:18 PM", NSColor(srgbRed: 0.28, green: 0.48, blue: 0.90, alpha: 1)),
        ("5/23/26, 4:18:02 PM", NSColor(srgbRed: 0.55, green: 0.30, blue: 0.85, alpha: 1)),
        ("5/23/26, 3:47:55 PM", NSColor(srgbRed: 0.22, green: 0.65, blue: 0.55, alpha: 1)),
        ("5/23/26, 2:11:09 PM", NSColor(srgbRed: 0.90, green: 0.55, blue: 0.20, alpha: 1)),
        ("5/23/26, 12:04:38 PM", NSColor(srgbRed: 0.35, green: 0.50, blue: 0.80, alpha: 1)),
        ("5/23/26, 9:58:21 AM", NSColor(srgbRed: 0.60, green: 0.20, blue: 0.40, alpha: 1)),
    ]

    for i in 0..<6 {
        let y = rowStartY - CGFloat(i) * rowH - thumbH
        let (timeStr, tint) = times[i]
        if i == 0 {
            push(cg)
            cg.setFillColor(NSColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 0.16).cgColor)
            cg.fill(CGRect(x: menuX + 12, y: y - 10, width: menuW - 24, height: rowH - 12))
            pop(cg)
        }

        let thumbRect = CGRect(x: menuX + 26, y: y, width: thumbW, height: thumbH)
        push(cg)
        clipToRoundedRect(cg, rect: thumbRect, radius: 8)
        let cs = CGColorSpaceCreateDeviceRGB()
        let lighter = tint.blended(withFraction: 0.45, of: .white) ?? tint
        let darker  = tint.blended(withFraction: 0.30, of: .black) ?? tint
        let grad = CGGradient(colorsSpace: cs,
                              colors: [lighter.cgColor, darker.cgColor] as CFArray,
                              locations: [0, 1])!
        cg.drawLinearGradient(grad,
                              start: CGPoint(x: thumbRect.minX, y: thumbRect.maxY),
                              end:   CGPoint(x: thumbRect.maxX, y: thumbRect.minY),
                              options: [])
        cg.setFillColor(NSColor.white.withAlphaComponent(0.45).cgColor)
        cg.fill(CGRect(x: thumbRect.minX + 9, y: thumbRect.maxY - 14, width: 72, height: 5))
        cg.setFillColor(NSColor.white.withAlphaComponent(0.30).cgColor)
        cg.fill(CGRect(x: thumbRect.minX + 9, y: thumbRect.maxY - 28, width: 96, height: 4))
        cg.fill(CGRect(x: thumbRect.minX + 9, y: thumbRect.maxY - 40, width: 78, height: 4))
        pop(cg)
        push(cg)
        cg.setStrokeColor(NSColor.black.withAlphaComponent(0.10).cgColor)
        cg.setLineWidth(1)
        cg.addPath(CGPath(roundedRect: thumbRect, cornerWidth: 8, cornerHeight: 8, transform: nil))
        cg.strokePath()
        pop(cg)

        let textX = thumbRect.maxX + 22
        let textY = thumbRect.midY - 14
        drawText(timeStr,
                 at: NSPoint(x: textX, y: textY + 6),
                 font: rowFont, color: labelColor)
        drawText("Full screen · PNG",
                 at: NSPoint(x: textX, y: textY - 26),
                 font: timeFont, color: dimColor)
    }

    // Footer separator
    let footerTopY = menuY + footerH - 10
    push(cg)
    cg.setFillColor(NSColor.black.withAlphaComponent(0.08).cgColor)
    cg.fill(CGRect(x: menuX + 14, y: footerTopY, width: menuW - 28, height: 1))
    pop(cg)

    // Footer items — ENGLISH
    let items = [
        "Open History Folder",
        "Clear History\u{2026}",
        "Preferences  \u{25B8}",
        "About ClipShot",
        "Quit"
    ]
    var fy = footerTopY - 42
    for (idx, t) in items.enumerated() {
        if idx == 2 {
            push(cg)
            cg.setFillColor(NSColor.black.withAlphaComponent(0.08).cgColor)
            cg.fill(CGRect(x: menuX + 14, y: fy + 36, width: menuW - 28, height: 1))
            pop(cg)
        }
        drawText(t, at: NSPoint(x: menuX + 26, y: fy),
                 font: footerFont, color: labelColor)
        if idx == 0 {
            drawTextRight("\u{2318}O", rightX: menuX + menuW - 26,
                          y: fy, font: footerFont, color: dimColor)
        }
        fy -= 46
    }

    pop(cg) // end menu clip
    pop(cg) // end screen clip

    pop(cg)
    writePNG(bitmap, to: "\(outDir)/screenshot_1_menu.png")
}

// MARK: - Screenshot 2: Floating thumbnail inside MacBook screen

func renderScreenshot2() {
    let (bitmap, cg) = makeContext()
    push(cg)
    drawBackground(cg)

    drawTitle(cg,
              title: "A floating preview, exactly when you need it",
              subtitle: "Click to edit in Markup, or drag straight into any app.")

    let lidWidth: CGFloat = 1900
    let lidBottomY: CGFloat = 220
    let layout = drawMacBookFrame(cg, centerX: CANVAS_W/2, bottomY: lidBottomY, lidWidth: lidWidth)
    let screen = layout.screenContentRect

    drawScreenWallpaper(cg, in: screen)

    push(cg)
    clipToRoundedRect(cg, rect: screen, radius: 8)

    // Status bar at top of screen
    let barH: CGFloat = 56
    drawMacOSStatusBar(cg, in: screen, height: barH, highlightClipShot: false)

    // A faux document window centered on the screen (background context)
    let docW = screen.width * 0.72
    let docH = screen.height * 0.74
    let docRect = CGRect(x: screen.midX - docW/2,
                         y: screen.minY + screen.height*0.10,
                         width: docW, height: docH)
    push(cg)
    cg.setShadow(offset: CGSize(width: 0, height: -8),
                 blur: 36, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    cg.setFillColor(NSColor(srgbRed: 0.95, green: 0.96, blue: 0.98, alpha: 0.94).cgColor)
    cg.addPath(CGPath(roundedRect: docRect, cornerWidth: 18, cornerHeight: 18, transform: nil))
    cg.fillPath()
    pop(cg)
    push(cg)
    clipToRoundedRect(cg, rect: docRect, radius: 18)
    // titlebar
    cg.setFillColor(NSColor(srgbRed: 0.88, green: 0.90, blue: 0.93, alpha: 1).cgColor)
    cg.fill(CGRect(x: docRect.minX, y: docRect.maxY - 48, width: docRect.width, height: 48))
    // traffic lights
    let lights: [(NSColor, CGFloat)] = [
        (NSColor(srgbRed: 1.0, green: 0.36, blue: 0.32, alpha: 1), 0),
        (NSColor(srgbRed: 1.0, green: 0.74, blue: 0.20, alpha: 1), 1),
        (NSColor(srgbRed: 0.16, green: 0.78, blue: 0.30, alpha: 1), 2),
    ]
    for (color, i) in lights {
        cg.setFillColor(color.cgColor)
        cg.fillEllipse(in: CGRect(x: docRect.minX + 18 + i*22,
                                   y: docRect.maxY - 32,
                                   width: 12, height: 12))
    }
    // content lines
    cg.setFillColor(NSColor(srgbRed: 0.78, green: 0.82, blue: 0.88, alpha: 1).cgColor)
    var ly = docRect.maxY - 90
    for w in [420, 600, 360, 520, 400, 320, 480, 560, 380, 440, 500, 360, 540, 420] {
        cg.fill(CGRect(x: docRect.minX + 56, y: ly, width: CGFloat(w), height: 10))
        ly -= 36
        if ly < docRect.minY + 40 { break }
    }
    pop(cg)

    // Floating thumbnail card in the lower-right corner of the screen
    let cardW: CGFloat = screen.width * 0.28
    let cardH: CGFloat = cardW * 0.63
    let cardX = screen.maxX - cardW - screen.width * 0.05
    let cardY = screen.minY + screen.height * 0.08

    drawShadowedRect(cg,
                     rect: CGRect(x: cardX, y: cardY, width: cardW, height: cardH),
                     radius: 18,
                     fill: NSColor.white,
                     shadowOpacity: 0.70,
                     shadowBlur: 70,
                     shadowOffset: CGSize(width: 0, height: -24))

    push(cg)
    let cardRect = CGRect(x: cardX, y: cardY, width: cardW, height: cardH)
    clipToRoundedRect(cg, rect: cardRect, radius: 18)

    let cs = CGColorSpaceCreateDeviceRGB()
    let g = CGGradient(colorsSpace: cs, colors: [
        NSColor(srgbRed: 0.85, green: 0.91, blue: 0.99, alpha: 1).cgColor,
        NSColor(srgbRed: 0.55, green: 0.72, blue: 0.95, alpha: 1).cgColor
    ] as CFArray, locations: [0,1])!
    cg.drawLinearGradient(g,
                          start: CGPoint(x: cardRect.minX, y: cardRect.maxY),
                          end:   CGPoint(x: cardRect.maxX, y: cardRect.minY),
                          options: [])

    // Inner faux window
    let innerW = cardW * 0.80
    let innerH = cardH * 0.74
    let innerRect = CGRect(x: cardRect.midX - innerW/2,
                           y: cardRect.midY - innerH/2,
                           width: innerW, height: innerH)
    cg.setShadow(offset: CGSize(width: 0, height: -4), blur: 16,
                 color: NSColor.black.withAlphaComponent(0.25).cgColor)
    cg.setFillColor(NSColor.white.cgColor)
    cg.addPath(CGPath(roundedRect: innerRect, cornerWidth: 10, cornerHeight: 10, transform: nil))
    cg.fillPath()

    push(cg)
    clipToRoundedRect(cg, rect: innerRect, radius: 10)
    cg.setFillColor(NSColor(srgbRed: 0.92, green: 0.94, blue: 0.97, alpha: 1).cgColor)
    cg.fill(CGRect(x: innerRect.minX, y: innerRect.maxY - 28,
                   width: innerRect.width, height: 28))
    for i in 0..<3 {
        let colors: [NSColor] = [
            NSColor(srgbRed: 1.0, green: 0.36, blue: 0.32, alpha: 1),
            NSColor(srgbRed: 1.0, green: 0.74, blue: 0.20, alpha: 1),
            NSColor(srgbRed: 0.16, green: 0.78, blue: 0.30, alpha: 1)
        ]
        cg.setFillColor(colors[i].cgColor)
        cg.fillEllipse(in: CGRect(x: innerRect.minX + 10 + CGFloat(i)*14,
                                   y: innerRect.maxY - 20,
                                   width: 8, height: 8))
    }
    cg.setFillColor(NSColor(srgbRed: 0.85, green: 0.88, blue: 0.92, alpha: 1).cgColor)
    var iy = innerRect.maxY - 46
    let widths: [CGFloat] = [140, 200, 130, 170, 230, 150, 190]
    for w in widths {
        cg.fill(CGRect(x: innerRect.minX + 16, y: iy, width: w, height: 6))
        iy -= 16
        if iy < innerRect.minY + 12 { break }
    }
    pop(cg)
    pop(cg)

    // Border around card
    push(cg)
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
    cg.setLineWidth(2)
    cg.addPath(CGPath(roundedRect: CGRect(x: cardX, y: cardY, width: cardW, height: cardH),
                      cornerWidth: 18, cornerHeight: 18, transform: nil))
    cg.strokePath()
    pop(cg)

    // "Copied!" badge near the card
    let badgeStr = "Copied!"
    let badgeFont = NSFont.systemFont(ofSize: 22, weight: .semibold)
    let badgeAttrs: [NSAttributedString.Key: Any] = [
        .font: badgeFont, .foregroundColor: NSColor.white
    ]
    let badgeText = NSAttributedString(string: badgeStr, attributes: badgeAttrs)
    let bsz = badgeText.size()
    let padX: CGFloat = 18, padY: CGFloat = 10
    let badgeRect = CGRect(x: cardX + cardW - bsz.width - padX*2 - 14,
                           y: cardY + cardH + 18,
                           width: bsz.width + padX*2,
                           height: bsz.height + padY*2)
    push(cg)
    cg.setShadow(offset: CGSize(width: 0, height: -3), blur: 10,
                 color: NSColor.black.withAlphaComponent(0.45).cgColor)
    cg.setFillColor(NSColor(srgbRed: 0.16, green: 0.65, blue: 0.30, alpha: 1).cgColor)
    cg.addPath(CGPath(roundedRect: badgeRect, cornerWidth: badgeRect.height/2,
                      cornerHeight: badgeRect.height/2, transform: nil))
    cg.fillPath()
    pop(cg)
    badgeText.draw(at: NSPoint(x: badgeRect.midX - bsz.width/2,
                                y: badgeRect.midY - bsz.height/2))

    // Cursor pointer near card
    let curX = cardX + cardW - 24
    let curY = cardY + 28
    push(cg)
    cg.setShadow(offset: CGSize(width: 0, height: -2), blur: 5,
                 color: NSColor.black.withAlphaComponent(0.55).cgColor)
    cg.setFillColor(NSColor.white.cgColor)
    let cur = CGMutablePath()
    cur.move(to: CGPoint(x: curX, y: curY))
    cur.addLine(to: CGPoint(x: curX + 22, y: curY - 6))
    cur.addLine(to: CGPoint(x: curX + 11, y: curY - 11))
    cur.addLine(to: CGPoint(x: curX + 14, y: curY - 30))
    cur.addLine(to: CGPoint(x: curX + 6,  y: curY - 30))
    cur.addLine(to: CGPoint(x: curX + 3,  y: curY - 18))
    cur.closeSubpath()
    cg.addPath(cur); cg.fillPath()
    cg.setStrokeColor(NSColor.black.withAlphaComponent(0.30).cgColor)
    cg.setLineWidth(1.5)
    cg.addPath(cur); cg.strokePath()
    pop(cg)

    pop(cg) // end screen clip

    pop(cg)
    writePNG(bitmap, to: "\(outDir)/screenshot_2_thumbnail.png")
}

// MARK: - Screenshot 3: Welcome / Privacy step inside MacBook

func renderScreenshot3() {
    let (bitmap, cg) = makeContext()
    push(cg)
    drawBackground(cg)

    drawTitle(cg,
              title: "Private by design",
              subtitle: "100% local. No accounts. No servers. No telemetry.")

    let lidWidth: CGFloat = 1900
    let lidBottomY: CGFloat = 220
    let layout = drawMacBookFrame(cg, centerX: CANVAS_W/2, bottomY: lidBottomY, lidWidth: lidWidth)
    let screen = layout.screenContentRect

    drawScreenWallpaper(cg, in: screen)

    push(cg)
    clipToRoundedRect(cg, rect: screen, radius: 8)

    // Status bar at top
    let barH: CGFloat = 56
    drawMacOSStatusBar(cg, in: screen, height: barH, highlightClipShot: false)

    // Welcome window centered inside the screen, slightly smaller than the screen
    let winW: CGFloat = screen.width * 0.66
    let winH: CGFloat = screen.height * 0.78
    let winX = screen.midX - winW/2
    let winY = screen.minY + (screen.height - barH - winH)/2 + 10

    drawShadowedRect(cg,
                     rect: CGRect(x: winX, y: winY, width: winW, height: winH),
                     radius: 18,
                     fill: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1.0),
                     shadowOpacity: 0.65,
                     shadowBlur: 80,
                     shadowOffset: CGSize(width: 0, height: -28))

    push(cg)
    let winRect = CGRect(x: winX, y: winY, width: winW, height: winH)
    clipToRoundedRect(cg, rect: winRect, radius: 18)

    // Traffic lights
    let lights: [NSColor] = [
        NSColor(srgbRed: 1.0, green: 0.36, blue: 0.32, alpha: 1),
        NSColor(srgbRed: 1.0, green: 0.74, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.16, green: 0.78, blue: 0.30, alpha: 1)
    ]
    for (i, c) in lights.enumerated() {
        cg.setFillColor(c.cgColor)
        let r = CGRect(x: winRect.minX + 26 + CGFloat(i)*26,
                       y: winRect.maxY - 44,
                       width: 16, height: 16)
        cg.fillEllipse(in: r)
    }

    // Shield icon (green) — centered top
    let shieldSize: CGFloat = 110
    let shieldRect = CGRect(x: winRect.midX - shieldSize/2,
                            y: winRect.maxY - 180,
                            width: shieldSize, height: shieldSize)
    let shieldColor = NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
    push(cg)
    cg.setFillColor(shieldColor.cgColor)
    let shield = CGMutablePath()
    let sx = shieldRect.midX
    let sy = shieldRect.maxY
    shield.move(to: CGPoint(x: sx, y: sy))
    shield.addCurve(to: CGPoint(x: shieldRect.maxX, y: sy - 26),
                    control1: CGPoint(x: sx + 22, y: sy - 3),
                    control2: CGPoint(x: shieldRect.maxX, y: sy - 14))
    shield.addLine(to: CGPoint(x: shieldRect.maxX, y: shieldRect.minY + 40))
    shield.addCurve(to: CGPoint(x: sx, y: shieldRect.minY),
                    control1: CGPoint(x: shieldRect.maxX, y: shieldRect.minY + 15),
                    control2: CGPoint(x: sx + 30, y: shieldRect.minY))
    shield.addCurve(to: CGPoint(x: shieldRect.minX, y: shieldRect.minY + 40),
                    control1: CGPoint(x: sx - 30, y: shieldRect.minY),
                    control2: CGPoint(x: shieldRect.minX, y: shieldRect.minY + 15))
    shield.addLine(to: CGPoint(x: shieldRect.minX, y: sy - 26))
    shield.addCurve(to: CGPoint(x: sx, y: sy),
                    control1: CGPoint(x: shieldRect.minX, y: sy - 14),
                    control2: CGPoint(x: sx - 22, y: sy - 3))
    shield.closeSubpath()
    cg.addPath(shield); cg.fillPath()
    cg.setFillColor(NSColor.white.cgColor)
    let lockBodyW: CGFloat = 36
    let lockBodyH: CGFloat = 28
    let lockBody = CGRect(x: sx - lockBodyW/2, y: shieldRect.midY - lockBodyH/2 - 3,
                          width: lockBodyW, height: lockBodyH)
    cg.addPath(CGPath(roundedRect: lockBody, cornerWidth: 4, cornerHeight: 4, transform: nil))
    cg.fillPath()
    cg.setStrokeColor(NSColor.white.cgColor)
    cg.setLineWidth(6)
    cg.beginPath()
    cg.addArc(center: CGPoint(x: sx, y: lockBody.maxY + 3),
              radius: 12,
              startAngle: .pi, endAngle: 0, clockwise: false)
    cg.strokePath()
    pop(cg)

    // Title "Your privacy"
    let titleStr = "Your privacy"
    let titleFont = NSFont.systemFont(ofSize: 40, weight: .bold)
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: titleFont,
        .foregroundColor: NSColor(srgbRed: 0.10, green: 0.12, blue: 0.18, alpha: 1)
    ]
    let tstr = NSAttributedString(string: titleStr, attributes: titleAttrs)
    let tsz = tstr.size()
    tstr.draw(at: NSPoint(x: winRect.midX - tsz.width/2,
                          y: shieldRect.minY - tsz.height - 14))

    // Body bullets — ENGLISH (mirrors welcome.step5.body in en.lproj/Localizable.strings)
    let bodyFont    = NSFont.systemFont(ofSize: 22, weight: .regular)
    let strongFont  = NSFont.systemFont(ofSize: 22, weight: .semibold)
    let bodyColor   = NSColor(srgbRed: 0.14, green: 0.16, blue: 0.22, alpha: 1)
    let strongColor = NSColor(srgbRed: 0.10, green: 0.12, blue: 0.18, alpha: 1)

    let bulletLines: [String] = [
        "ClipShot runs 100% on your Mac.",
        "",
        "  \u{2022}  Your screenshots and any image you copy to the clipboard are saved locally in the ClipShot folder.",
        "  \u{2022}  Nothing is ever sent to the internet. Ever.",
        "  \u{2022}  The developers have no access to your images or your activity.",
        "  \u{2022}  No accounts, no servers, no telemetry.",
        "  \u{2022}  You can clear your history at any time from the menu.",
        "",
        "It's yours, and only yours."
    ]

    var by = shieldRect.minY - tsz.height - 56
    for (idx, line) in bulletLines.enumerated() {
        if line.isEmpty { by -= 16; continue }
        let strong = (idx == 0 || idx == bulletLines.count - 1)
        let color: NSColor = strong ? strongColor : bodyColor
        let font: NSFont = strong ? strongFont : bodyFont
        let lineAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color
        ]
        let s = NSAttributedString(string: line, attributes: lineAttrs)
        let sz = s.size()
        if strong {
            s.draw(at: NSPoint(x: winRect.midX - sz.width/2, y: by - sz.height))
        } else {
            s.draw(at: NSPoint(x: winRect.minX + 100, y: by - sz.height))
        }
        by -= sz.height + 10
    }

    // Pagination dots (6 total, dot index 4 active = privacy step)
    let dotsY = winRect.minY + 80
    let dotCount = 6
    let activeIdx = 4
    let dotSize: CGFloat = 10
    let dotSpacing: CGFloat = 12
    let totalDotsW = CGFloat(dotCount) * dotSize + CGFloat(dotCount-1) * dotSpacing
    var dx = winRect.midX - totalDotsW/2
    for i in 0..<dotCount {
        let active = i == activeIdx
        cg.setFillColor((active ? NSColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1)
                                 : NSColor(white: 0.7, alpha: 1)).cgColor)
        cg.fillEllipse(in: CGRect(x: dx, y: dotsY, width: dotSize, height: dotSize))
        dx += dotSize + dotSpacing
    }

    // Buttons row: Skip (left), Back, Next (right) — ENGLISH
    let btnY = winRect.minY + 28
    let skipFont = NSFont.systemFont(ofSize: 18, weight: .regular)
    drawText("Skip",
             at: NSPoint(x: winRect.minX + 44, y: btnY),
             font: skipFont, color: NSColor(srgbRed: 0.45, green: 0.48, blue: 0.55, alpha: 1))

    let backRect = CGRect(x: winRect.maxX - 260, y: btnY - 6, width: 100, height: 36)
    cg.setFillColor(NSColor(white: 0.92, alpha: 1).cgColor)
    cg.addPath(CGPath(roundedRect: backRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
    cg.fillPath()
    let backStr = NSAttributedString(string: "Back", attributes: [
        .font: NSFont.systemFont(ofSize: 18, weight: .regular),
        .foregroundColor: NSColor(srgbRed: 0.20, green: 0.22, blue: 0.28, alpha: 1)
    ])
    let backSz = backStr.size()
    backStr.draw(at: NSPoint(x: backRect.midX - backSz.width/2,
                              y: backRect.midY - backSz.height/2))

    let nextRect = CGRect(x: winRect.maxX - 150, y: btnY - 6, width: 110, height: 36)
    cg.setFillColor(NSColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1).cgColor)
    cg.addPath(CGPath(roundedRect: nextRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
    cg.fillPath()
    let nextStr = NSAttributedString(string: "Next", attributes: [
        .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
        .foregroundColor: NSColor.white
    ])
    let nextSz = nextStr.size()
    nextStr.draw(at: NSPoint(x: nextRect.midX - nextSz.width/2,
                              y: nextRect.midY - nextSz.height/2))

    pop(cg) // end window clip
    pop(cg) // end screen clip

    pop(cg)
    writePNG(bitmap, to: "\(outDir)/screenshot_3_welcome.png")
}

// MARK: - Main

renderScreenshot1()
renderScreenshot2()
renderScreenshot3()
print("DONE")

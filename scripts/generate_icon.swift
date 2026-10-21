import Cocoa
import CoreGraphics

func createIcon(pixels: Int) -> NSImage {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)

    let img = NSImage(size: NSSize(width: pixels, height: pixels))
    img.addRepresentation(rep)
    img.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        img.unlockFocus()
        return img
    }

    let size = CGFloat(pixels)
    let scale = size / 1024.0

    // Overall squircle bounds (macOS app icon standard: 824x824 at 1024x1024, centered)
    let margin: CGFloat = 100.0 * scale
    let iconSize: CGFloat = size - 2 * margin
    let rect = CGRect(x: margin, y: margin, width: iconSize, height: iconSize)
    let cornerRadius: CGFloat = 185.0 * scale

    // Shadow
    ctx.saveGState()
    let shadowColor = NSColor.black.withAlphaComponent(0.45).cgColor
    ctx.setShadow(offset: CGSize(width: 0, height: -18 * scale), blur: 32 * scale, color: shadowColor)

    // Base Squircle Path
    let squirclePath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(squirclePath)
    ctx.setFillColor(NSColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1.0).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Background Gradient inside squircle
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        NSColor(red: 0.14, green: 0.17, blue: 0.24, alpha: 1.0).cgColor,
        NSColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 1.0).cgColor
    ] as CFArray
    let bgLocations: [CGFloat] = [0.0, 1.0]
    if let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: bgLocations) {
        ctx.drawLinearGradient(bgGradient,
                               start: CGPoint(x: rect.midX, y: rect.maxY),
                               end: CGPoint(x: rect.midX, y: rect.minY),
                               options: [])
    }

    // Border stroke (Apple subtle border)
    ctx.addPath(squirclePath)
    ctx.setLineWidth(3.0 * scale)
    ctx.setStrokeColor(NSColor(red: 0.35, green: 0.45, blue: 0.60, alpha: 0.35).cgColor)
    ctx.strokePath()

    // Metallic Drive Enclosure Graphic
    let driveWidth = 560.0 * scale
    let driveHeight = 420.0 * scale
    let driveX = (size - driveWidth) / 2.0
    let driveY = (size - driveHeight) / 2.0 - 20 * scale
    let driveRect = CGRect(x: driveX, y: driveY, width: driveWidth, height: driveHeight)
    let driveCorner = 36.0 * scale

    // Drive shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 20 * scale, color: NSColor.black.withAlphaComponent(0.5).cgColor)
    let drivePath = CGPath(roundedRect: driveRect, cornerWidth: driveCorner, cornerHeight: driveCorner, transform: nil)
    ctx.addPath(drivePath)
    ctx.setFillColor(NSColor(red: 0.18, green: 0.22, blue: 0.29, alpha: 1.0).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Drive body gradient (brushed dark aluminum)
    ctx.saveGState()
    ctx.addPath(drivePath)
    ctx.clip()
    let driveColors = [
        NSColor(red: 0.25, green: 0.30, blue: 0.38, alpha: 1.0).cgColor,
        NSColor(red: 0.13, green: 0.16, blue: 0.21, alpha: 1.0).cgColor
    ] as CFArray
    if let driveGradient = CGGradient(colorsSpace: colorSpace, colors: driveColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(driveGradient,
                               start: CGPoint(x: driveRect.midX, y: driveRect.maxY),
                               end: CGPoint(x: driveRect.midX, y: driveRect.minY),
                               options: [])
    }

    // Drive edge highlight
    ctx.addPath(drivePath)
    ctx.setLineWidth(2.0 * scale)
    ctx.setStrokeColor(NSColor(red: 0.45, green: 0.55, blue: 0.70, alpha: 0.5).cgColor)
    ctx.strokePath()

    // Drive Front Face / Slot
    let slotHeight = 60.0 * scale
    let slotRect = CGRect(x: driveRect.minX + 24 * scale,
                          y: driveRect.minY + 24 * scale,
                          width: driveRect.width - 48 * scale,
                          height: slotHeight)
    let slotPath = CGPath(roundedRect: slotRect, cornerWidth: 14 * scale, cornerHeight: 14 * scale, transform: nil)
    ctx.addPath(slotPath)
    ctx.setFillColor(NSColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1.0).cgColor)
    ctx.fillPath()

    // Glowing LED on drive
    let ledRadius = 10.0 * scale
    let ledCenter = CGPoint(x: slotRect.minX + 30 * scale, y: slotRect.midY)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 14 * scale, color: NSColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 0.9).cgColor)
    ctx.setFillColor(NSColor(red: 0.0, green: 0.82, blue: 1.0, alpha: 1.0).cgColor)
    ctx.fillEllipse(in: CGRect(x: ledCenter.x - ledRadius, y: ledCenter.y - ledRadius, width: ledRadius * 2, height: ledRadius * 2))
    ctx.restoreGState()

    // Activity lines on slot
    let lineX = slotRect.maxX - 100 * scale
    for i in 0..<3 {
        let lx = lineX + CGFloat(i) * 24 * scale
        let lRect = CGRect(x: lx, y: slotRect.midY - 12 * scale, width: 4 * scale, height: 24 * scale)
        ctx.setFillColor(NSColor(white: 0.3, alpha: 0.7).cgColor)
        ctx.fill(lRect)
    }

    ctx.restoreGState() // unclip drive

    // "NTFS" Typography Badge in Center
    let text = "NTFS"
    let fontSize = 110.0 * scale
    let font = NSFont.systemFont(ofSize: fontSize, weight: .black)
    let textAttrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white
    ]
    let attrStr = NSAttributedString(string: text, attributes: textAttrs)
    let textSize = attrStr.size()
    let textPoint = CGPoint(x: (size - textSize.width) / 2.0, y: driveRect.midY + 18 * scale)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -3 * scale), blur: 8 * scale, color: NSColor.black.withAlphaComponent(0.6).cgColor)
    attrStr.draw(at: textPoint)
    ctx.restoreGState()

    // Subtitle badge "Mac"
    let macBadgeRect = CGRect(x: (size - 130 * scale) / 2.0, y: textPoint.y + textSize.height + 6 * scale, width: 130 * scale, height: 32 * scale)
    let macBadgePath = CGPath(roundedRect: macBadgeRect, cornerWidth: 16 * scale, cornerHeight: 16 * scale, transform: nil)
    ctx.addPath(macBadgePath)
    ctx.setFillColor(NSColor(red: 0.0, green: 0.44, blue: 0.89, alpha: 0.9).cgColor) // Apple Blue
    ctx.fillPath()

    let macText = "PURE SWIFT"
    let macFont = NSFont.systemFont(ofSize: 14.0 * scale, weight: .bold)
    let macAttrs: [NSAttributedString.Key: Any] = [
        .font: macFont,
        .foregroundColor: NSColor.white
    ]
    let macStr = NSAttributedString(string: macText, attributes: macAttrs)
    let macSize = macStr.size()
    macStr.draw(at: CGPoint(x: macBadgeRect.midX - macSize.width / 2.0, y: macBadgeRect.midY - macSize.height / 2.0))

    ctx.restoreGState() // unclip squircle

    img.unlockFocus()
    return img
}

func savePNG(image: NSImage, path: String) {
    if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

let iconsetDir = "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, px) in sizes {
    let img = createIcon(pixels: px)
    savePNG(image: img, path: "\(iconsetDir)/\(name)")
}

print("Iconset created at \(iconsetDir)")

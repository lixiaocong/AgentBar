import AppKit
import Foundation

struct IconSpec {
    let fileName: String
    let size: Int
}

enum IconGenerationError: Error {
    case renderFailed(Int)
    case iconutilFailed(Int32)
}

let specs = [
    IconSpec(fileName: "icon_16x16.png", size: 16),
    IconSpec(fileName: "icon_16x16@2x.png", size: 32),
    IconSpec(fileName: "icon_32x32.png", size: 32),
    IconSpec(fileName: "icon_32x32@2x.png", size: 64),
    IconSpec(fileName: "icon_128x128.png", size: 128),
    IconSpec(fileName: "icon_128x128@2x.png", size: 256),
    IconSpec(fileName: "icon_256x256.png", size: 256),
    IconSpec(fileName: "icon_256x256@2x.png", size: 512),
    IconSpec(fileName: "icon_512x512.png", size: 512),
    IconSpec(fileName: "icon_512x512@2x.png", size: 1024)
]

let fileManager = FileManager.default
let projectURL = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
let resourcesURL = projectURL.appendingPathComponent("Resources", isDirectory: true)
let iconsetURL = resourcesURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let icnsURL = resourcesURL.appendingPathComponent("AppIcon.icns")
let previewURL = resourcesURL.appendingPathComponent("AppIcon-preview.png")

try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
if fileManager.fileExists(atPath: iconsetURL.path) {
    try fileManager.removeItem(at: iconsetURL)
}
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

for spec in specs {
    guard let data = renderIcon(size: spec.size) else {
        throw IconGenerationError.renderFailed(spec.size)
    }
    try data.write(to: iconsetURL.appendingPathComponent(spec.fileName))

    if spec.size == 1024 {
        try data.write(to: previewURL)
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try iconutil.run()
iconutil.waitUntilExit()

guard iconutil.terminationStatus == 0 else {
    throw IconGenerationError.iconutilFailed(iconutil.terminationStatus)
}

print("Generated \(icnsURL.path)")

func renderIcon(size: Int) -> Data? {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )

    guard let bitmap else { return nil }
    bitmap.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current = context
    context?.cgContext.interpolationQuality = .high
    context?.cgContext.setAllowsAntialiasing(true)

    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    drawBackground(in: canvas)
    drawPanel(in: canvas)
    drawHeader(in: canvas)
    drawQuotaBars(in: canvas)

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

func drawBackground(in canvas: NSRect) {
    let unit = canvas.width / 1024
    let iconRect = canvas.insetBy(dx: 68 * unit, dy: 68 * unit)
    let path = NSBezierPath(roundedRect: iconRect, xRadius: 228 * unit, yRadius: 228 * unit)

    NSGraphicsContext.saveGraphicsState()
    path.addClip()

    let baseGradient = NSGradient(colors: [
        NSColor(srgbRed: 0.06, green: 0.08, blue: 0.12, alpha: 1),
        NSColor(srgbRed: 0.11, green: 0.16, blue: 0.22, alpha: 1)
    ])
    baseGradient?.draw(in: path, angle: -90)

    NSColor(srgbRed: 0.40, green: 0.74, blue: 0.98, alpha: 0.12).setFill()
    NSBezierPath(ovalIn: NSRect(
        x: iconRect.minX - 180 * unit,
        y: iconRect.maxY - 420 * unit,
        width: 640 * unit,
        height: 640 * unit
    )).fill()

    NSColor(srgbRed: 1, green: 0.72, blue: 0.28, alpha: 0.10).setFill()
    NSBezierPath(ovalIn: NSRect(
        x: iconRect.maxX - 420 * unit,
        y: iconRect.minY - 60 * unit,
        width: 520 * unit,
        height: 520 * unit
    )).fill()

    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.10).setStroke()
    path.lineWidth = 6 * unit
    path.stroke()
}

func drawPanel(in canvas: NSRect) {
    let unit = canvas.width / 1024
    let panelRect = canvas.insetBy(dx: 154 * unit, dy: 154 * unit)
    let panelPath = NSBezierPath(roundedRect: panelRect, xRadius: 148 * unit, yRadius: 148 * unit)

    NSColor(srgbRed: 0.10, green: 0.13, blue: 0.19, alpha: 0.92).setFill()
    panelPath.fill()

    NSColor.white.withAlphaComponent(0.08).setStroke()
    panelPath.lineWidth = 4 * unit
    panelPath.stroke()
}

func drawHeader(in canvas: NSRect) {
    let unit = canvas.width / 1024
    let headerRect = NSRect(
        x: canvas.midX - 212 * unit,
        y: canvas.maxY - 266 * unit,
        width: 424 * unit,
        height: 40 * unit
    )
    let headerPath = NSBezierPath(roundedRect: headerRect, xRadius: 20 * unit, yRadius: 20 * unit)

    let gradient = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.78),
        NSColor.white.withAlphaComponent(0.34)
    ])
    gradient?.draw(in: headerPath, angle: -90)
}

func drawQuotaBars(in canvas: NSRect) {
    let unit = canvas.width / 1024
    let trackHeight = 432 * unit
    let trackWidth = 132 * unit
    let spacing = 44 * unit
    let baseY = canvas.minY + 250 * unit
    let totalWidth = trackWidth * 3 + spacing * 2
    let startX = canvas.midX - totalWidth / 2

    let fills: [CGFloat] = [0.82, 0.58, 0.36]
    let colors = [
        (top: NSColor(srgbRed: 0.54, green: 0.84, blue: 1.00, alpha: 1),
         bottom: NSColor(srgbRed: 0.27, green: 0.66, blue: 0.99, alpha: 1)),
        (top: NSColor(srgbRed: 0.47, green: 0.94, blue: 0.71, alpha: 1),
         bottom: NSColor(srgbRed: 0.22, green: 0.78, blue: 0.50, alpha: 1)),
        (top: NSColor(srgbRed: 1.00, green: 0.80, blue: 0.44, alpha: 1),
         bottom: NSColor(srgbRed: 0.98, green: 0.64, blue: 0.19, alpha: 1))
    ]

    for index in 0..<3 {
        let x = startX + CGFloat(index) * (trackWidth + spacing)
        let trackRect = NSRect(x: x, y: baseY, width: trackWidth, height: trackHeight)
        drawTrack(in: trackRect, unit: unit)
        drawFill(in: trackRect, fraction: fills[index], colors: colors[index], unit: unit)
    }
}

func drawTrack(in rect: NSRect, unit: CGFloat) {
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
    shadow.shadowBlurRadius = 24 * unit
    shadow.shadowOffset = NSSize(width: 0, height: -8 * unit)

    NSGraphicsContext.saveGraphicsState()
    shadow.set()

    let path = NSBezierPath(roundedRect: rect, xRadius: 42 * unit, yRadius: 42 * unit)
    NSColor.white.withAlphaComponent(0.10).setFill()
    path.fill()

    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.12).setStroke()
    path.lineWidth = 4 * unit
    path.stroke()
}

func drawFill(
    in trackRect: NSRect,
    fraction: CGFloat,
    colors: (top: NSColor, bottom: NSColor),
    unit: CGFloat
) {
    let inset = 12 * unit
    let availableHeight = trackRect.height - inset * 2
    let fillHeight = max(56 * unit, availableHeight * fraction)
    let fillRect = NSRect(
        x: trackRect.minX + inset,
        y: trackRect.minY + inset,
        width: trackRect.width - inset * 2,
        height: fillHeight
    )
    let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 30 * unit, yRadius: 30 * unit)

    let gradient = NSGradient(colors: [colors.bottom, colors.top])
    gradient?.draw(in: fillPath, angle: 90)

    NSColor.white.withAlphaComponent(0.18).setStroke()
    fillPath.lineWidth = 3 * unit
    fillPath.stroke()

    let sheenRect = NSRect(
        x: fillRect.minX + 10 * unit,
        y: fillRect.maxY - 26 * unit,
        width: fillRect.width - 20 * unit,
        height: 12 * unit
    )
    let sheenPath = NSBezierPath(roundedRect: sheenRect, xRadius: 6 * unit, yRadius: 6 * unit)
    NSColor.white.withAlphaComponent(0.34).setFill()
    sheenPath.fill()
}

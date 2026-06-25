// Renders the PrismaX app icon to PNGs in the sizes the macOS asset catalog
// expects. Run via the build script, or directly:
//   swift scripts/render_app_icon.swift
//
// Concept: a glass prism refracting a beam into layered data layers — a nod to
// "Prisma" (prism) and to database/workflow management. Big Sur "squircle"
// styling: full-bleed indigo gradient background, white prism, spectrum beam.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Brand colors
let indigoDark = NSColor(srgbRed: 0.27, green: 0.27, blue: 0.66, alpha: 1)   // #4545A8
let indigoLight = NSColor(srgbRed: 0.45, green: 0.46, blue: 0.85, alpha: 1)  // #7376D9
let prismGlass = NSColor.white.withAlphaComponent(0.95)
let prismEdge = NSColor(srgbRed: 0.70, green: 0.72, blue: 1.0, alpha: 1)

// Spectrum layers (refracted beam) — the "data" columns.
let spectrum: [NSColor] = [
    NSColor(srgbRed: 0.40, green: 0.85, blue: 0.95, alpha: 1),  // cyan
    NSColor(srgbRed: 0.55, green: 0.80, blue: 0.98, alpha: 1),  // azure
    NSColor(srgbRed: 0.75, green: 0.70, blue: 1.00, alpha: 1)   // violet
]

// MARK: - Drawing

/// Draws the icon artwork into a square graphics context of side `S` (points).
/// Coordinates are flipped to a top-left origin for intuitive layout.
func drawIcon(in ctx: CGContext, size S: CGFloat) {
    // Top-left origin.
    ctx.translateBy(x: 0, y: S)
    ctx.scaleBy(x: 1, y: -1)

    let r = CGRect(x: 0, y: 0, width: S, height: S)

    // Background: diagonal indigo gradient, full bleed.
    let grad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [indigoDark.cgColor, indigoLight.cgColor] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.saveGState()
    ctx.addRect(r)
    ctx.clip()
    ctx.drawLinearGradient(
        grad,
        start: CGPoint(x: 0, y: 0),
        end: CGPoint(x: S, y: S),
        options: []
    )
    // Subtle vignette for depth.
    let darkOverlay = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(white: 0, alpha: 0.0).cgColor,
            NSColor(white: 0, alpha: 0.18).cgColor
        ] as CFArray,
        locations: [0.5, 1.0]
    )!
    ctx.drawLinearGradient(
        darkOverlay,
        start: CGPoint(x: 0, y: S * 0.5),
        end: CGPoint(x: 0, y: S),
        options: []
    )
    ctx.restoreGState()

    // Geometry: center the artwork with padding.
    let cx = S * 0.5
    let cy = S * 0.5
    let prismH = S * 0.46
    let prismW = S * 0.34

    // A triangle prism pointing right (apex on the right).
    let apex = CGPoint(x: cx + prismW * 0.55, y: cy)
    let baseTop = CGPoint(x: cx - prismW * 0.5, y: cy + prismH * 0.5)
    let baseBottom = CGPoint(x: cx - prismW * 0.5, y: cy - prismH * 0.5)

    // Incoming beam (left → prism), brighter and thicker to read as light.
    ctx.saveGState()
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(S * 0.06)
    ctx.setLineCap(.round)
    let beamStart = CGPoint(x: S * 0.10, y: cy)
    let prismEntry = CGPoint(x: cx - prismW * 0.5, y: cy)
    ctx.move(to: beamStart)
    ctx.addLine(to: prismEntry)
    ctx.setShadow(offset: .init(width: 0, height: 0), blur: S * 0.05,
                  color: NSColor.white.withAlphaComponent(0.85).cgColor)
    ctx.strokePath()
    ctx.restoreGState()

    // The prism: translucent glass triangle.
    ctx.saveGState()
    ctx.beginPath()
    ctx.move(to: apex)
    ctx.addLine(to: baseTop)
    ctx.addLine(to: baseBottom)
    ctx.closePath()

    // Glass fill — a faint white gradient for a glassy look.
    let glassGrad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(white: 1, alpha: 0.40).cgColor,
            NSColor(white: 1, alpha: 0.12).cgColor
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.addRect(r)
    ctx.clip()
    ctx.drawLinearGradient(glassGrad,
                           start: CGPoint(x: cx - prismW, y: cy - prismH * 0.5),
                           end: CGPoint(x: cx + prismW, y: cy + prismH * 0.5),
                           options: [])
    ctx.restoreGState()

    // Refracted spectrum — three horizontal "data layer" bars to the right of
    // the prism, stacked vertically and evenly spaced (aligned, not fanned),
    // with a single beam line fanning from the apex to each bar's left edge.
    ctx.saveGState()
    let barsX = cx + prismW * 0.55
    let barW = S * 0.30
    let barH = S * 0.075
    let barGap = S * 0.035
    let stackH = CGFloat(spectrum.count) * barH + CGFloat(spectrum.count - 1) * barGap
    var barCY = cy + stackH / 2 - barH / 2
    for (i, color) in spectrum.enumerated() {
        let barLeft = CGPoint(x: barsX, y: barCY)

        // Beam line from apex to this bar's left edge.
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(S * 0.03)
        ctx.setLineCap(.round)
        ctx.move(to: apex)
        ctx.addLine(to: barLeft)
        ctx.setShadow(offset: .init(width: 0, height: 0), blur: S * 0.025,
                      color: color.withAlphaComponent(0.6).cgColor)
        ctx.strokePath()

        // Rounded "data layer" bar.
        let barRect = CGRect(x: barsX, y: barCY - barH / 2, width: barW, height: barH)
        let barPath = CGPath(roundedRect: barRect,
                             cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil)
        ctx.setFillColor(color.cgColor)
        ctx.addPath(barPath)
        ctx.fillPath()
        _ = i

        barCY -= (barH + barGap)
    }
    ctx.restoreGState()

    // Bright prism outline on top so the triangle reads clearly.
    ctx.saveGState()
    ctx.beginPath()
    ctx.move(to: apex)
    ctx.addLine(to: baseTop)
    ctx.addLine(to: baseBottom)
    ctx.closePath()
    ctx.setStrokeColor(prismEdge.cgColor)
    ctx.setLineWidth(S * 0.022)
    ctx.setLineJoin(.round)
    ctx.setShadow(offset: .init(width: 0, height: 0), blur: S * 0.03,
                  color: NSColor.white.withAlphaComponent(0.55).cgColor)
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - PNG export

func renderPNG(size S: CGFloat, to url: URL) {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: Int(S), height: Int(S),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Could not create bitmap context") }
    drawIcon(in: ctx, size: S)
    guard let img = ctx.makeImage() else { fatalError("Could not make image") }
    let bmp = NSBitmapImageRep(cgImage: img)
    guard let pngData = bmp.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode PNG")
    }
    try! pngData.write(to: url)
    print("  ✓ \(url.lastPathComponent) (\(Int(S))×\(Int(S)))")
}

// MARK: - Main

let fm = FileManager.default
let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
                    ? CommandLine.arguments[1]
                    : "PrismaX/Resources/Assets.xcassets/AppIcon.appiconset")

// mac app icon sizes (points): 16,32,64,128,256,512,1024 (×2 scales).
let sizes: [(name: String, px: CGFloat)] = [
    ("icon_16.png", 16),
    ("icon_16@2x.png", 32),
    ("icon_32.png", 32),
    ("icon_32@2x.png", 64),
    ("icon_128.png", 128),
    ("icon_128@2x.png", 256),
    ("icon_256.png", 256),
    ("icon_256@2x.png", 512),
    ("icon_512.png", 512),
    ("icon_512@2x.png", 1024)
]

print("Rendering PrismaX app icon → \(outputDir.path)")
for (name, px) in sizes {
    renderPNG(size: px, to: outputDir.appendingPathComponent(name))
}
print("Done.")

#!/usr/bin/env swift
// Generates Lume's app icon: a luminous crescent over a night-gradient squircle.
// Renders every macOS iconset size, then `iconutil` packs them into Lume.icns.
//
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift tools/make-appicon.swift
//
import AppKit

// MARK: - Helpers

func hex(_ s: String, _ a: CGFloat = 1) -> CGColor {
    var v: UInt64 = 0
    Scanner(string: s.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
    return CGColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                   green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space,
               colors: stops.map { $0.0 } as CFArray,
               locations: stops.map { $0.1 })!
}

/// A continuous-corner rounded rect ("squircle"), close to Apple's icon grid.
func squircle(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - Draw

func drawIcon(_ S: CGFloat) -> CGImage {
    let px = Int(S)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high

    // Tile silhouette (small transparent margin, like native macOS icons).
    let m = S * 0.055
    let tile = CGRect(x: m, y: m, width: S - 2*m, height: S - 2*m)
    let radius = tile.width * 0.2237
    let path = squircle(tile, radius)

    // Soft drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012),
                  blur: S * 0.03, color: hex("#000000", 0.35))
    ctx.addPath(path); ctx.setFillColor(hex("#0C0A24")); ctx.fillPath()
    ctx.restoreGState()

    // Clip to the tile for all interior art.
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()

    // Night gradient background (rich violet top → deep indigo bottom).
    ctx.drawLinearGradient(
        gradient([(hex("#5942C8"), 0), (hex("#33237E"), 0.5), (hex("#100B30"), 1)]),
        start: CGPoint(x: tile.midX, y: tile.maxY),
        end: CGPoint(x: tile.midX, y: tile.minY), options: [])

    // Crescent geometry.
    let R = tile.width * 0.265
    let cc = CGPoint(x: tile.midX - tile.width*0.02, y: tile.midY + tile.height*0.05)
    let outer = CGRect(x: cc.x - R, y: cc.y - R, width: 2*R, height: 2*R)
    let bite = CGRect(x: cc.x - R + R*0.50, y: cc.y - R + R*0.34,
                      width: 2*R*0.94, height: 2*R*0.94)

    // Soft luminous halo hugging the bright (left) limb of the crescent — the
    // "lume". Kept off the opening so the moon reads clean against night sky.
    let glowC = CGPoint(x: cc.x - R*0.78, y: cc.y - R*0.05)
    ctx.drawRadialGradient(
        gradient([(hex("#CFE0FF", 0.38), 0), (hex("#9FC0FF", 0.10), 0.55), (hex("#9FC0FF", 0), 1)]),
        startCenter: glowC, startRadius: 0,
        endCenter: glowC, endRadius: R * 0.9, options: [])

    // Crescent glow rim.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: S * 0.04, color: hex("#BBD4FF", 0.9))
    ctx.beginPath()
    ctx.addEllipse(in: outer)
    ctx.addEllipse(in: bite)
    ctx.clip(using: .evenOdd)
    ctx.drawLinearGradient(
        gradient([(hex("#F2F7FF"), 0), (hex("#BBD2FF"), 0.6), (hex("#8FB6FF"), 1)]),
        start: CGPoint(x: cc.x, y: cc.y + R),
        end: CGPoint(x: cc.x, y: cc.y - R), options: [])
    ctx.restoreGState()

    // A few stars for depth.
    let stars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (0.72, 0.74, 0.012, 0.95), (0.80, 0.60, 0.008, 0.7),
        (0.66, 0.30, 0.007, 0.6),  (0.30, 0.78, 0.006, 0.55),
        (0.78, 0.40, 0.010, 0.85),
    ]
    for (fx, fy, fr, fa) in stars {
        let r = S * fr
        let c = CGPoint(x: tile.minX + tile.width*fx, y: tile.minY + tile.height*fy)
        ctx.setFillColor(hex("#FFFFFF", fa))
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2*r, height: 2*r))
    }

    ctx.restoreGState()

    // Subtle top inner highlight on the tile edge.
    ctx.saveGState()
    ctx.addPath(squircle(tile.insetBy(dx: S*0.004, dy: S*0.004), radius))
    ctx.setStrokeColor(hex("#FFFFFF", 0.10)); ctx.setLineWidth(S * 0.006)
    ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

// MARK: - Emit iconset + icns

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = root.appendingPathComponent("tools/Lume.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in variants {
    let img = drawIcon(size)
    let rep = NSBitmapImageRep(cgImage: img)
    rep.size = NSSize(width: Int(size), height: Int(size))
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: iconset.appendingPathComponent("\(name).png"))
}

// Also drop a 512 preview for eyeballing.
let preview = NSBitmapImageRep(cgImage: drawIcon(512))
try! preview.representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("tools/icon-preview.png"))

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path, "-o",
                  root.appendingPathComponent("Sources/LumeApp/Resources/Lume.icns").path]
try! proc.run(); proc.waitUntilExit()
print(proc.terminationStatus == 0 ? "✓ Lume.icns written" : "✗ iconutil failed")

import AppKit
import Foundation
import Metal
import simd

// Renders AppIcon.icns from code — no design tool, and no binary asset to keep in sync with
// the app's own look.
//
// The mark is the orb itself, drawn by `OrbRenderer` — the same renderer, shaders and tuned
// parameters the HUD and the record button use. It is compiled in rather than approximated,
// so the icon cannot drift from the thing it depicts: retune the orb and the next
// `make icon` follows. That is the whole reason this is a compiled tool now and no longer a
// single interpreted file.
//
// Run: make icon

// MARK: - The orb, rendered once at full size

/// How large the orb is drawn, before being scaled down for each icon variant.
let orbPixels = 1024

/// Rendered at one size and downsampled, unlike the tile around it.
///
/// The orb's dot size is absolute in pixels, so a 32px render is not a small version of a
/// 1024px one — it is a handful of dots with nothing between them. Drawing it once, large,
/// and letting the resampler take it down is what keeps the 16pt icon reading as a sphere.
func renderOrb() -> CGImage? {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let renderer = try? OrbRenderer(device: device, outputFormat: .bgra8Unorm)
    else { return nil }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: orbPixels, height: orbPixels, mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor),
          let commands = queue.makeCommandBuffer()
    else { return nil }

    renderer.render(
        into: texture,
        commandBuffer: commands,
        // Lit, not idle. A still orb is a flat disc of points; this is the shape it takes
        // when it is actually hearing you, which is what the app is for.
        level: 0.58,
        // Fixed, so two runs of `make icon` produce identical bytes.
        time: 3.0,
        yaw: 0.6,
        pitch: -0.15,
        // Point size is multiplied by this in the shader, so it is what keeps the dots in
        // proportion at a resolution far above the one the orb was tuned at. The HUD draws
        // 150pt at 2x, which is this same ratio.
        contentScale: Float(orbPixels) / 150
    )
    commands.commit()
    commands.waitUntilCompleted()

    var bytes = [UInt8](repeating: 0, count: orbPixels * orbPixels * 4)
    texture.getBytes(
        &bytes,
        bytesPerRow: orbPixels * 4,
        from: MTLRegionMake2D(0, 0, orbPixels, orbPixels),
        mipmapLevel: 0
    )

    // Metal hands back BGRA; CoreGraphics is told so rather than the channels being
    // shuffled by hand.
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        .union(.byteOrder32Little)
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
        width: orbPixels, height: orbPixels,
        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: orbPixels * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
        provider: provider, decode: nil, shouldInterpolate: true,
        intent: .defaultIntent
    )
}

/// Rendered once, at load, and shared by every variant.
let orb: CGImage = {
    guard let image = renderOrb() else {
        print("could not render the orb — no Metal device?")
        exit(1)
    }
    return image
}()

// MARK: - The tile

/// The window's own ground, so the icon is a piece of the app rather than a picture of it.
let groundCore = NSColor(srgbRed: 0.106, green: 0.090, blue: 0.180, alpha: 1)
let groundEdge = NSColor(srgbRed: 0.043, green: 0.039, blue: 0.071, alpha: 1)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // macOS Big Sur+ icon grid: art occupies the middle ~82%, leaving the shadow gutter
    // the system expects.
    let inset = size * 0.09
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    // Apple's squircle is ~22.37% of the tile's edge.
    let radius = rect.width * 0.2237
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * 0.012),
        blur: size * 0.035,
        color: NSColor.black.withAlphaComponent(0.30).cgColor
    )
    ctx.addPath(squircle)
    ctx.setFillColor(groundEdge.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // The ground, lifted slightly where the orb sits so it reads as lit from within rather
    // than pasted on.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [groundCore.cgColor, groundEdge.cgColor] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0,
            endCenter: CGPoint(x: rect.midX, y: rect.midY), endRadius: rect.width * 0.72,
            options: []
        )
    }

    // A glow under the orb, carrying the mark at the sizes the dots cannot.
    //
    // The orb is a cloud of individual points. Downsampled to 32px they average into a dim
    // smudge — every dot is there and none of them reads. Apple's own icons simplify at
    // small sizes for the same reason, so this does too: the glow is a faint lift at 512px
    // and most of what you see at 16, where a sphere of light is the honest simplification
    // of a sphere of lit points.
    let orbSide = rect.width * 0.86
    let glowAlpha: CGFloat = size <= 32 ? 0.95 : (size <= 64 ? 0.62 : (size <= 128 ? 0.34 : 0.20))
    if let glow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(srgbRed: 1.00, green: 0.90, blue: 0.86, alpha: glowAlpha).cgColor,
            NSColor(srgbRed: 1.00, green: 0.44, blue: 0.66, alpha: glowAlpha * 0.72).cgColor,
            NSColor(srgbRed: 0.62, green: 0.53, blue: 1.00, alpha: glowAlpha * 0.34).cgColor,
            NSColor(srgbRed: 0.62, green: 0.53, blue: 1.00, alpha: 0).cgColor,
        ] as CFArray,
        locations: [0, 0.42, 0.72, 1]
    ) {
        ctx.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0,
            endCenter: CGPoint(x: rect.midX, y: rect.midY), endRadius: orbSide * 0.46,
            options: []
        )
    }

    ctx.draw(orb, in: CGRect(
        x: rect.midX - orbSide / 2,
        y: rect.midY - orbSide / 2,
        width: orbSide,
        height: orbSide
    ))
    ctx.restoreGState()

    // A lit top edge, the same hairline the app draws on its own cards.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    ctx.setLineWidth(max(1, size * 0.004))
    ctx.strokePath()
    ctx.restoreGState()

    image.unlockFocus()
    return image
}

// MARK: - The iconset

func png(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // The tile is redrawn at native pixel size rather than one render being scaled — it
    // keeps the small sizes crisp. Only the orb inside it is resampled, because it has to be.
    drawIcon(size: CGFloat(pixels)).draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero, operation: .sourceOver, fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

// Compiled rather than interpreted — see the Makefile — so the entry point is explicit.
@main
struct MakeIcon {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath)
        let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
        try? fm.removeItem(at: iconset)
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

        // (point size, scale) pairs iconutil expects.
        let variants: [(Int, Int)] = [
            (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
            (256, 1), (256, 2), (512, 1), (512, 2),
        ]

        for (points, scale) in variants {
            let pixels = points * scale
            guard let data = png(pixels: pixels) else {
                print("failed at \(pixels)px"); exit(1)
            }
            let suffix = scale == 2 ? "@2x" : ""
            try data.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
        }

        print("wrote \(variants.count) PNGs to Resources/AppIcon.iconset")
    }
}

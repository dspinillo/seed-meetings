// Gera o Seed.iconset (squircle verde + folha) e imprime o caminho.
// Uso: swiftc -o /tmp/mkicon scripts/make-icon.swift && /tmp/mkicon <saida.iconset>
import AppKit

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "Seed.iconset"
let outURL = URL(fileURLWithPath: outPath)
try? FileManager.default.removeItem(at: outURL)
try! FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

func draw(size: Int, scale: Int, name: String) {
    let pixels = size * scale
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    let s = CGFloat(pixels)
    // margem padrão de ícone macOS (~10% de respiro)
    let inset = s * 0.09
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = rect.width * 0.225
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // fundo: gradiente verde dessaturado (BSystem-like)
    let top = NSColor(calibratedRed: 0.42, green: 0.56, blue: 0.45, alpha: 1)
    let bottom = NSColor(calibratedRed: 0.19, green: 0.31, blue: 0.23, alpha: 1)
    squircle.addClip()
    NSGradient(starting: top, ending: bottom)!.draw(in: rect, angle: -90)

    // brilho sutil no topo (gradiente suave, sem borda dura)
    let glossRect = CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
    NSGradient(
        starting: NSColor.white.withAlphaComponent(0.0),
        ending: NSColor.white.withAlphaComponent(0.10)
    )!.draw(in: glossRect, angle: 90)

    cg.resetClip()

    // folha (SF Symbol) branca centralizada
    let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.52, weight: .medium)
    if let leaf = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: leaf.size, flipped: false) { r in
            leaf.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let leafSize = tinted.size
        let scaleFactor = (rect.width * 0.58) / max(leafSize.width, leafSize.height)
        let w = leafSize.width * scaleFactor
        let h = leafSize.height * scaleFactor
        let leafRect = CGRect(
            x: rect.midX - w / 2,
            y: rect.midY - h / 2,
            width: w, height: h
        )
        tinted.draw(in: leafRect, from: .zero, operation: .sourceOver, fraction: 0.96)
    }

    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: outURL.appendingPathComponent(name))
}

let sizes = [16, 32, 128, 256, 512]
for size in sizes {
    draw(size: size, scale: 1, name: "icon_\(size)x\(size).png")
    draw(size: size, scale: 2, name: "icon_\(size)x\(size)@2x.png")
}
print(outURL.path)

// Compose native simulator captures with store artwork. The app UI is unchanged.
// Usage: xcrun swift scripts/render-store-screenshots.swift <input-dir> <output-dir> [ipad]
import AppKit
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
precondition(args.count >= 3, "Provide input and output directories")
let input = URL(fileURLWithPath: args[1], isDirectory: true)
let output = URL(fileURLWithPath: args[2], isDirectory: true)
let ipad = args.count > 3 && args[3] == "ipad"
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let size = CGSize(width: ipad ? 2064 : 1320, height: ipad ? 2752 : 2868)
let titles: [(String, String, String)] = [
    ("01-overview", "See what’s left.", "All your AI accounts in one view."),
    ("02-widgets", "Six accounts.\nOne widget.", "Check remaining usage from your Home Screen."),
    ("03-compact", "Keep it compact.", "Limits and reset times in less space."),
    ("04-charts", "Compare your usage.", "History across accounts and providers."),
    ("05-activity", "Find your patterns.", "See activity by day and account."),
    ("06-rings", "Usage and resets.", "Track each allowance and its next reset.")
]
func text(_ value: String, rect: CGRect, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let style = NSMutableParagraphStyle(); style.lineSpacing = 4; style.lineBreakMode = .byWordWrapping
    (value as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style], context: nil)
}
for (id, title, subtitle) in titles {
    let path = input.appendingPathComponent(id + ".png")
    guard let source = NSImage(contentsOf: path) else { if id == "02-widgets" && ipad { continue }; fatalError("Missing \(path.path)") }
    let nativePixels = source.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    if id != "02-widgets" {
        let background = NSBitmapImageRep(cgImage: nativePixels).colorAt(x: 16, y: nativePixels.height / 2)!.usingColorSpace(.sRGB)!
        let bitmap = NSBitmapImageRep(cgImage: nativePixels)
        var low: CGFloat = 1; var high: CGFloat = 0
        for row in 0..<24 { for column in 0..<24 {
            let pixel = bitmap.colorAt(x: nativePixels.width * (column + 1) / 26, y: nativePixels.height * (row + 6) / 36)!.usingColorSpace(.sRGB)!
            let light = max(pixel.redComponent, pixel.greenComponent, pixel.blueComponent)
            low = min(low, light); high = max(high, light)
        } }
        precondition(high - low > 0.025, "Capture has no visible app content: \(path.path)")
        precondition(max(background.redComponent, background.greenComponent, background.blueComponent) < 0.3, "Capture is not the dark app screen: \(path.path)")
    }
    let cg = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let context = NSGraphicsContext(cgContext: cg, flipped: false)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    context.cgContext.translateBy(x: 0, y: size.height); context.cgContext.scaleBy(x: 1, y: -1)
    let cream = NSColor(srgbRed: 0.95, green: 0.96, blue: 0.93, alpha: 1)
    let ink = NSColor(srgbRed: 0.10, green: 0.14, blue: 0.09, alpha: 1)
    cream.setFill(); NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
    NSColor(srgbRed: 0.73, green: 0.94, blue: 0.46, alpha: 1).setFill()
    NSBezierPath(ovalIn: CGRect(x: size.width - 560, y: size.height - 640, width: 1000, height: 1000)).fill()
    // A flipped NSGraphicsContext keeps text and native images upright.
    let flipped = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    NSGraphicsContext.current = flipped
    let margin: CGFloat = ipad ? 112 : 94
    text("REQUOTA", rect: CGRect(x: margin, y: 60, width: 700, height: 58), size: 39, weight: .semibold, color: ink.withAlphaComponent(0.65))
    text(title, rect: CGRect(x: margin, y: 147, width: size.width - margin * 2, height: 225), size: ipad ? 101 : 91, weight: .bold, color: ink)
    let subtitleY: CGFloat = title.contains("\n") ? 385 : 282
    text(subtitle, rect: CGRect(x: margin, y: subtitleY, width: size.width - margin * 2, height: 82), size: ipad ? 42 : 37, weight: .regular, color: ink.withAlphaComponent(0.75))
    let frameY: CGFloat = id == "02-widgets" ? 1120 : subtitleY + 118
    let available = CGSize(width: id == "02-widgets" ? 700 : size.width - (ipad ? 170 : 270), height: size.height - frameY - 110)
    let scale = min(available.width / source.size.width, available.height / source.size.height)
    let imageSize = CGSize(width: source.size.width * scale, height: source.size.height * scale)
    let rect = CGRect(x: (size.width - imageSize.width) / 2, y: frameY, width: imageSize.width, height: imageSize.height)
    let edge = NSBezierPath(roundedRect: rect.insetBy(dx: -8, dy: -8), xRadius: 66, yRadius: 66)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.20); shadow.shadowBlurRadius = 35; shadow.shadowOffset = CGSize(width: 0, height: -14); shadow.set()
    ink.setFill(); edge.fill(); NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: rect, xRadius: 58, yRadius: 58).addClip()
    source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
    if id == "02-widgets", !ipad {
        // A close-up of the running widget, alongside the full unaltered Home Screen.
        // Coordinates are pixels in the committed 1320 × 2868 native capture.
        let crop = nativePixels.cropping(to: CGRect(x: 117, y: 284, width: 1086, height: 506))!
        let widget = NSImage(cgImage: crop, size: CGSize(width: 1086, height: 506))
        let closeUp = CGRect(x: 94, y: 535, width: size.width - 188, height: (size.width - 188) * 506 / 1086)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: closeUp, xRadius: 92, yRadius: 92).addClip()
        widget.draw(in: closeUp, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
    }
    text("Illustrative account data", rect: CGRect(x: margin, y: size.height - 54, width: size.width - margin * 2, height: 34), size: 23, weight: .regular, color: ink.withAlphaComponent(0.55))
    NSGraphicsContext.restoreGraphicsState()
    let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(id + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, cg.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
    print("Rendered \(id): \(Int(size.width)) × \(Int(size.height))")
}

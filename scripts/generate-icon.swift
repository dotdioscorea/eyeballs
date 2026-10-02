#!/usr/bin/env swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(NSColor(srgbRed: 16/255, green: 18/255, blue: 17/255, alpha: 1).cgColor)
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
context.setLineCap(.round)
func ring(radius: CGFloat, color: NSColor, progress: CGFloat, width: CGFloat) {
    context.setStrokeColor(color.withAlphaComponent(0.12).cgColor)
    context.setLineWidth(width)
    context.strokeEllipse(in: CGRect(x: 512-radius, y: 512-radius, width: radius*2, height: radius*2))
    context.setStrokeColor(color.cgColor)
    context.addArc(center: CGPoint(x: 512, y: 512), radius: radius, startAngle: .pi/2, endAngle: .pi/2-progress*2 * .pi, clockwise: true)
    context.strokePath()
}
let lime = NSColor(srgbRed: 185/255, green: 245/255, blue: 119/255, alpha: 1)
ring(radius: 365, color: lime, progress: 0.79, width: 34)
ring(radius: 313, color: NSColor(srgbRed: 170/255, green: 165/255, blue: 255/255, alpha: 1), progress: 0.42, width: 24)
context.setStrokeColor(lime.cgColor)
context.setLineWidth(22)
for center in [CGFloat(399), CGFloat(625)] {
    context.strokeEllipse(in: CGRect(x: center-88, y: 406, width: 176, height: 212))
    context.setFillColor(lime.cgColor)
    context.fillEllipse(in: CGRect(x: center-28, y: 475, width: 60, height: 80))
}
let output = URL(fileURLWithPath: "App/Eyeballs/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent("AppIcon.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Icon export failed") }
try Data("""
{"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
""".utf8).write(to: output.appendingPathComponent("Contents.json"))
print("Generated Eyeballs icon")

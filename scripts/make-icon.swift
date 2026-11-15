import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [("icon_16x16",16), ("icon_16x16@2x",32), ("icon_32x32",32), ("icon_32x32@2x",64), ("icon_128x128",128), ("icon_128x128@2x",256), ("icon_256x256",256), ("icon_256x256@2x",512), ("icon_512x512",512), ("icon_512x512@2x",1024)]
let colors = CGColorSpaceCreateDeviceRGB()
for (name, size) in sizes {
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: colors, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("context") }
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = CGPath(roundedRect: CGRect(x: 32, y: 32, width: 960, height: 960), cornerWidth: 220, cornerHeight: 220, transform: nil)
    context.addPath(tile); context.clip()
    let background = CGGradient(colorsSpace: colors, colors: [CGColor(red: 0.015, green: 0.07, blue: 0.16, alpha: 1), CGColor(red: 0.04, green: 0.025, blue: 0.12, alpha: 1), CGColor(red: 0.22, green: 0.04, blue: 0.42, alpha: 1)] as CFArray, locations: [0, 0.68, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 130, y: 900), end: CGPoint(x: 900, y: 80), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.addPath(tile); context.setStrokeColor(CGColor(red: 0.19, green: 0.55, blue: 1, alpha: 0.85)); context.setLineWidth(12); context.strokePath()
    let gradient = CGGradient(colorsSpace: colors, colors: [CGColor(red: 0.15, green: 0.85, blue: 0.97, alpha: 1), CGColor(red: 0.20, green: 0.43, blue: 1, alpha: 1), CGColor(red: 0.70, green: 0.25, blue: 0.96, alpha: 1)] as CFArray, locations: [0, 0.55, 1])!
    // Use the same SF Symbol as the in-app brand mark, rendered into an alpha mask.
    let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)!.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 470, weight: .bold))!
    let maskContext = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: colors, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    maskContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: maskContext, flipped: false)
    symbol.draw(in: CGRect(x: 265, y: 265, width: 494, height: 494), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.current = previous
    if let mask = maskContext.makeImage() {
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: 1024, height: 1024), mask: mask)
        context.drawLinearGradient(gradient, start: CGPoint(x: 220, y: 700), end: CGPoint(x: 810, y: 300), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }
    guard let image = context.makeImage(), let sink = CGImageDestinationCreateWithURL(destination.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("image") }
    CGImageDestinationAddImage(sink, image, nil)
    guard CGImageDestinationFinalize(sink) else { fatalError("write") }
}

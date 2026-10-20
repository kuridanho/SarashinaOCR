import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

let rect = NSRect(x: 56, y: 56, width: 912, height: 912)
let path = NSBezierPath(roundedRect: rect, xRadius: 210, yRadius: 210)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.82, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.66, blue: 0.66, alpha: 1)
])!
gradient.draw(in: path, angle: -52)

// Subtle inner highlight
NSColor.white.withAlphaComponent(0.16).setStroke()
path.lineWidth = 6
path.stroke()

if let symbol = NSImage(
    systemSymbolName: "doc.text.viewfinder",
    accessibilityDescription: nil
), let configured = symbol.withSymbolConfiguration(
    NSImage.SymbolConfiguration(pointSize: 430, weight: .medium)
) {
    let symbolRect = NSRect(
        x: (1024 - 520) / 2,
        y: (1024 - 470) / 2,
        width: 520,
        height: 470
    )
    let ratio = min(
        symbolRect.width / max(configured.size.width, 1),
        symbolRect.height / max(configured.size.height, 1)
    )
    let size = NSSize(
        width: configured.size.width * ratio,
        height: configured.size.height * ratio
    )
    let inner = NSRect(
        x: symbolRect.midX - size.width / 2,
        y: symbolRect.midY - size.height / 2,
        width: size.width,
        height: size.height
    )
    let tinted = NSImage(size: inner.size)
    tinted.lockFocus()
    configured.draw(in: NSRect(origin: .zero, size: inner.size))
    NSColor.white.set()
    NSRect(origin: .zero, size: inner.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    tinted.draw(in: inner)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let data = rep.representation(using: .png, properties: [:])
else {
    fputs("failed to render icon\n", stderr)
    exit(1)
}
try data.write(to: output)

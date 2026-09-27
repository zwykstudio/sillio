// Dessine l'icône de l'app à partir du symbole partagé (Sources/Mark.swift) et écrit un PNG.
// Usage : make-icon <sortie.png>   — voir Tools/make-icon.sh

import AppKit
import CoreGraphics

let size = 1024.0
let out = URL(fileURLWithPath: CommandLine.arguments.last!)

guard let context = CGContext(data: nil, width: Int(size), height: Int(size),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

// Carré arrondi façon macOS, graphite comme les panneaux de l'app.
let inset = size * 0.09
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
context.saveGState()
context.addPath(CGPath(roundedRect: rect, cornerWidth: size * 0.185, cornerHeight: size * 0.185, transform: nil))
context.clip()
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [CGColor(red: 0.18, green: 0.20, blue: 0.23, alpha: 1),
                                   CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1)] as CFArray,
                          locations: [0, 1])!
context.drawLinearGradient(gradient,
                           start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY),
                           options: [])
// Reflet discret en haut à gauche, pour que l'icône ne soit pas plate.
context.setFillColor(CGColor(gray: 1, alpha: 0.06))
context.fillEllipse(in: CGRect(x: rect.minX - size * 0.2, y: rect.midY, width: size * 0.9, height: size * 0.75))
context.restoreGState()

// Le sillon, centré, avec le point rouge de l'enregistrement.
context.saveGState()
context.translateBy(x: size * 0.215, y: size * 0.215)
Mark.draw(in: context,
          size: size * 0.57,
          stroke: CGColor(red: 0.96, green: 0.95, blue: 0.93, alpha: 1),
          dot: CGColor(red: 1.00, green: 0.27, blue: 0.22, alpha: 1),
          recording: true)
context.restoreGState()

guard let image = context.makeImage() else { exit(1) }
try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: out)
print("icône → \(out.path)")

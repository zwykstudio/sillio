// Dessine le fond de la fenêtre du DMG : on y glisse Sillio sur Applications.
// Usage : make-dmg-background <échelle> <sortie.png>   — voir package.sh
//
// Les positions ci-dessous doivent correspondre à celles que package.sh donne au Finder
// (fenêtre 640 × 330, icônes centrées en 170,190 et 470,190).
// Le texte est en anglais : un DMG ne peut pas suivre la langue du système.

import AppKit

let width = 640.0, height = 330.0
let scale = Double(CommandLine.arguments[1])!
let out = URL(fileURLWithPath: CommandLine.arguments[2])

let appCenter = CGPoint(x: 170, y: 190)
let applicationsCenter = CGPoint(x: 470, y: 190)

let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale),
                              bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
// Origine en haut à gauche, comme le Finder.
context.translateBy(x: 0, y: height * scale)
context.scaleBy(x: scale, y: -scale)
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}
let armed = color(1.00, 0.75, 0.28)   // la lampe ambre de l'app : prêt
let paper = color(0.96, 0.95, 0.93)

// Fond graphite, un peu plus clair en haut, comme l'icône.
let gradient = CGGradient(colorsSpace: rgb,
                          colors: [color(0.17, 0.18, 0.21), color(0.09, 0.10, 0.12)] as CFArray,
                          locations: [0, 1])!
context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])

// Sillons concentriques très discrets, centrés sous l'icône de l'app : la gravure d'un disque.
context.setLineWidth(1)
for index in 1...14 {
    let radius = 70.0 + Double(index) * 16
    context.setStrokeColor(color(1, 1, 1, 0.035 - Double(index) * 0.0018))
    context.strokeEllipse(in: CGRect(x: appCenter.x - radius, y: appCenter.y - radius,
                                     width: radius * 2, height: radius * 2))
}

// Plaquettes sous les noms des icônes : dès qu'une fenêtre a une image de fond, le Finder écrit
// les noms en noir, même en mode sombre. Sans elles, ils disparaîtraient dans le graphite.
for center in [appCenter, applicationsCenter] {
    let plate = CGRect(x: center.x - 58, y: center.y + 62, width: 116, height: 24)
    context.addPath(CGPath(roundedRect: plate, cornerWidth: 12, cornerHeight: 12, transform: nil))
    context.setFillColor(color(0.57, 0.58, 0.60))
    context.fillPath()
}

// La flèche : un sillon pointillé ambre, extrémités rondes comme le symbole.
let arrowY = appCenter.y
let startX = appCenter.x + 78, endX = applicationsCenter.x - 78
context.setStrokeColor(armed)
context.setLineCap(.round)
context.setLineWidth(3)
context.setLineDash(phase: 0, lengths: [0.1, 11])
context.move(to: CGPoint(x: startX, y: arrowY))
context.addLine(to: CGPoint(x: endX - 8, y: arrowY))
context.strokePath()
context.setLineDash(phase: 0, lengths: [])
context.setLineJoin(.round)
context.move(to: CGPoint(x: endX - 11, y: arrowY - 10))
context.addLine(to: CGPoint(x: endX, y: arrowY))
context.addLine(to: CGPoint(x: endX - 11, y: arrowY + 10))
context.strokePath()

// Textes.
func text(_ string: String, font: NSFont, color: NSColor, kern: Double = 0, centerX: Double, top: Double) {
    let attributed = NSAttributedString(string: string, attributes: [
        .font: font, .foregroundColor: color, .kern: kern,
    ])
    let size = attributed.size()
    attributed.draw(at: CGPoint(x: centerX - size.width / 2, y: top))
}

let lampRect = CGRect(x: width / 2 - 38, y: 44, width: 7, height: 7)
context.setShadow(offset: .zero, blur: 6, color: color(1.00, 0.75, 0.28, 0.8))
context.setFillColor(armed)
context.fillEllipse(in: lampRect)
context.setShadow(offset: .zero, blur: 0, color: nil)
text("SILLIO", font: .monospacedSystemFont(ofSize: 11, weight: .semibold),
     color: NSColor(cgColor: paper)!.withAlphaComponent(0.55), kern: 3,
     centerX: width / 2 + 6, top: 40)
text("Drag Sillio to Applications", font: .systemFont(ofSize: 19, weight: .semibold),
     color: NSColor(cgColor: paper)!, centerX: width / 2, top: 62)

guard let image = context.makeImage() else { exit(1) }
let bitmap = NSBitmapImageRep(cgImage: image)
bitmap.size = NSSize(width: width, height: height)   // 72 dpi logiques, quelle que soit l'échelle
try bitmap.representation(using: .png, properties: [:])!.write(to: out)

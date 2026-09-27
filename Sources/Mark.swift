// Le symbole de Sillio : un sillon.
//
// Deux arcs concentriques fendus autour d'un point central — la gravure d'un vinyle, et le
// point d'un enregistreur. Ce fichier est la seule source du dessin : l'icône de l'app et
// celle de la barre du menu sortent d'ici, donc elles ne peuvent pas diverger.

import AppKit
import CoreGraphics

enum Mark {
    /// Dessine le sillon dans un carré de côté `size`, coin inférieur gauche à l'origine.
    static func draw(in context: CGContext, size: CGFloat, stroke: CGColor, dot: CGColor, recording: Bool = false) {
        let center = CGPoint(x: size / 2, y: size / 2)
        let lineWidth = size * 0.088
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setStrokeColor(stroke)

        // La fente est orientée en bas à droite : c'est elle qui distingue le symbole
        // d'une simple cible, et elle suit le sens de lecture d'un sillon.
        let slit = CGFloat.pi * 0.34
        let slitCenter = -CGFloat.pi * 0.17
        for radius in [size * 0.395, size * 0.255] {
            context.addArc(center: center,
                           radius: radius,
                           startAngle: slitCenter + slit / 2,
                           endAngle: slitCenter - slit / 2 + 2 * .pi,
                           clockwise: false)
            context.strokePath()
        }

        let dotRadius = size * (recording ? 0.105 : 0.072)
        context.setFillColor(dot)
        context.fillEllipse(in: CGRect(x: center.x - dotRadius, y: center.y - dotRadius,
                                       width: dotRadius * 2, height: dotRadius * 2))
    }

    /// L'icône de la barre du menu : monochrome, macOS la teinte selon le thème.
    static func menuBarImage(recording: Bool) -> NSImage {
        let side: CGFloat = 16
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let black = NSColor.black.cgColor
            draw(in: context, size: rect.width, stroke: black, dot: black, recording: recording)
            return true
        }
        image.isTemplate = true
        return image
    }
}

// Vocabulaire visuel de Sillio : un magnétophone de terrain.
// Le timecode et le tracé de niveau portent la personnalité ; tout le reste reste en retrait.
// Un seul accent : la lampe rouge, qui ne s'allume que pendant l'enregistrement.

import SwiftUI

enum Ink {
    static let signal = Color(red: 1.00, green: 0.27, blue: 0.22)  // lampe : enregistre
    static let armed = Color(red: 1.00, green: 0.75, blue: 0.28)   // lampe : prêt, en attente du son
    static let trace = Color.primary.opacity(0.7)                  // tracé de niveau
    static let surface = Color.primary.opacity(0.09)               // champs et boutons
    static let surfacePressed = Color.primary.opacity(0.17)
    static let hairline = Color.primary.opacity(0.13)
}

enum Metric {
    static let panelWidth: CGFloat = 288
    static let radius: CGFloat = 11
    static let overlayRadius: CGFloat = 18
}

extension Font {
    /// Chiffres de compteur : monospace, comme sur un enregistreur.
    static func timecode(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }
}

// MARK: - Lampe

struct RecordLamp: View {
    let recording: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(recording ? Ink.signal : Ink.armed)
            .frame(width: 9, height: 9)
            .shadow(color: (recording ? Ink.signal : Ink.armed).opacity(0.7), radius: 4)
            // Prêt : la lampe clignote. Enregistre : elle reste fixe.
            .opacity(recording ? 1 : (dim ? 0.3 : 1))
            .animation(recording ? nil : .easeInOut(duration: 0.65).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
            .accessibilityLabel(recording ? tr("Recording", "Enregistrement en cours") : tr("Waiting for sound", "En attente de son"))
    }
}

// MARK: - Tracé de niveau

/// Les niveaux récents, du plus ancien au plus récent, en 0…1 (échelle dB).
struct LevelTrace: View {
    let levels: [Float]
    var bars: Int = 46
    var color: Color = Ink.trace

    var body: some View {
        GeometryReader { geometry in
            let values = padded
            let spacing: CGFloat = 2
            let width = max(1.5, (geometry.size.width - spacing * CGFloat(bars - 1)) / CGFloat(bars))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(values.indices, id: \.self) { index in
                    let value = CGFloat(values[index])
                    Capsule(style: .continuous)
                        .fill(color.opacity(0.2 + 0.8 * value))
                        .frame(width: width, height: max(2, geometry.size.height * value))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var padded: [Float] {
        let recent = Array(levels.suffix(bars))
        return Array(repeating: 0, count: max(0, bars - recent.count)) + recent
    }
}

// MARK: - Boutons

/// L'action principale : pleine, rouge, impossible à confondre avec un champ.
struct RecordButtonStyle: ButtonStyle {
    var active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(active ? Color.primary : Color.white)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill((active ? Ink.surface : Ink.signal).opacity(configuration.isPressed ? 0.75 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(active ? Ink.hairline : .clear)
            )
            .contentShape(Rectangle())
    }
}

/// Réglage numérique compact : − valeur +
struct PlusMinus: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: 2) {
            Button { value = max(range.lowerBound, value - step) } label: { Image(systemName: "minus") }
                .buttonStyle(GlyphButtonStyle(size: 22))
                .disabled(value <= range.lowerBound)
            Text(format(value))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 42)
            Button { value = min(range.upperBound, value + step) } label: { Image(systemName: "plus") }
                .buttonStyle(GlyphButtonStyle(size: 22))
                .disabled(value >= range.upperBound)
        }
        .padding(.horizontal, 4)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.surface))
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                    .fill(configuration.isPressed ? Ink.surfacePressed : Ink.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                    .strokeBorder(prominent ? Ink.hairline : .clear)
            )
            .contentShape(Rectangle())
    }
}

/// Champ cliquable pleine largeur (sélecteur de source).
struct FieldButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                    .fill(configuration.isPressed ? Ink.surfacePressed : Ink.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                    .strokeBorder(Ink.hairline)
            )
            .contentShape(Rectangle())
    }
}

struct GlyphButtonStyle: ButtonStyle {
    var size: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(Circle().fill(configuration.isPressed ? Ink.surfacePressed : .clear))
            .contentShape(Circle())
    }
}

/// Bouton d'arrêt de l'overlay : carré rouge dans un cercle, comme sur un enregistreur.
struct StopButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Ink.surface)
                Circle().strokeBorder(Ink.hairline)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Ink.signal)
                    .frame(width: 13, height: 13)
            }
            .frame(width: 38, height: 38)
            .scaleEffect(hovering ? 1.06 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tr("Stop recording", "Arrêter l'enregistrement"))
    }
}

// MARK: - Habillage

struct PanelSurface: ViewModifier {
    var radius: CGFloat = Metric.overlayRadius

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Ink.hairline)
            )
    }
}

extension View {
    func panelSurface(radius: CGFloat = Metric.overlayRadius) -> some View {
        modifier(PanelSurface(radius: radius))
    }
}

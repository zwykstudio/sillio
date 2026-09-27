// Fenêtre flottante affichée pendant toute la capture : elle reste visible au-dessus du
// navigateur, sur tous les bureaux, et ne prend jamais le focus (cliquer « stop » ne quitte
// pas l'app où tu es). On peut la déplacer à la souris ; sa position est retenue.

import AppKit
import SwiftUI

final class OverlayController {
    private var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?
    private let defaults = UserDefaults.standard
    private let size = CGSize(width: 318, height: 112)

    func show(model: AppModel) {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow
        panel.setFrameOrigin(savedOrigin())
        panel.orderFrontRegardless()

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in self?.saveOrigin() }

        self.panel = panel
    }

    func hide() {
        saveOrigin()
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func saveOrigin() {
        guard let origin = panel?.frame.origin else { return }
        defaults.set([origin.x, origin.y], forKey: "overlayOrigin")
    }

    private func savedOrigin() -> NSPoint {
        if let saved = defaults.array(forKey: "overlayOrigin") as? [Double], saved.count == 2 {
            let point = NSPoint(x: saved[0], y: saved[1])
            // Ignorer une position devenue hors écran (écran débranché).
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -40, dy: -40).contains(point) }) {
                return point
            }
        }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: screen.maxX - size.width - 20, y: screen.maxY - size.height - 12)
    }
}

struct OverlayView: View {
    @ObservedObject var model: AppModel
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    RecordLamp(recording: model.isRecording)
                    if model.isRecording {
                        Text(model.timecode)
                            .font(.timecode(26))
                            .monospacedDigit()
                    } else {
                        Text(model.waitingTitle)
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                LevelTrace(levels: model.levels, color: model.isRecording ? Ink.trace : Ink.armed.opacity(0.8))
                    .frame(height: 22)
                Text(model.overlayCaption)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            StopButton { model.toggleRecord() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(width: 318, height: 112)
        .panelSurface()
        .scaleEffect(appeared ? 1 : 0.96)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { appeared = true } }
    }
}

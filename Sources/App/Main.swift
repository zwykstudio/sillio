// Point d'entrée de Sillio.app : une icône dans la barre du menu.
// L'icône est le même sillon que celle de l'app (Sources/Mark.swift) ; pendant la capture,
// son point central grossit et le compteur s'affiche à côté.

import SwiftUI

@main
struct SillioApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            let mark = Image(nsImage: Mark.menuBarImage(recording: model.isActive))
            if model.isRecording {
                Text("\(mark) \(model.timecode)")
            } else if model.isActive {
                Text("\(mark) ···")
            } else {
                mark
            }
        }
        .menuBarExtraStyle(.window)
    }
}

// Outil de test : affiche une vue de l'app dans une fenêtre pour la photographier,
// ou exerce un enregistrement complet sans interface.
//
//   render --view main|main-rec|settings|overlay-rec|overlay-wait <fichier-id-fenêtre>
//   render --record <app> <dossier> <format> <fichier-id-fenêtre>
//   render --defaults <suite>   (sinon : un bac à sable, pas les réglages de l'app)

import AppKit
import SwiftUI

let arguments = CommandLine.arguments
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
if arguments.contains("--light") { app.appearance = NSAppearance(named: .aqua) }

let suite = option("--defaults") ?? "sillio.preview"
let defaults = UserDefaults(suiteName: suite)!
let model = AppModel(defaults: defaults)

func sampleLevels(_ count: Int) -> [Float] {
    (0..<count).map { index in
        let phase = Double(index) / 6
        return Float(max(0.05, min(1, 0.55 + 0.35 * sin(phase) + 0.18 * sin(phase * 2.7))))
    }
}

// Noms neutres : ces vues servent aussi aux captures du README.
let sampleRecents = [
    RecentRecording(path: "/tmp/Sillio/Night Drive.mp3", duration: 178, date: Date()),
    RecentRecording(path: "/tmp/Sillio/Paper Moons (demo).mp3", duration: 250, date: Date()),
    RecentRecording(path: "/tmp/Sillio/Firefox 2026-09-27 00-12.flac", duration: 143, date: Date()),
]

// --record : exerce le chemin complet de l'app sans interface.
if let index = arguments.firstIndex(of: "--record") {
    model.sourceID = arguments[index + 1]
    model.folder = URL(fileURLWithPath: arguments[index + 2])
    model.format = OutputFormat(rawValue: arguments[index + 3]) ?? .mp3
    model.autoStop = true
    model.silenceSeconds = 1.5
    model.mute = true
    model.overlayEnabled = arguments.contains("--overlay")
    model.customName = "test app"
    var ticks = 0
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
        ticks += 1
        print("[\(ticks)] \(model.statusLine) niveaux=\(model.levels.count) t=\(model.seconds)s")
        if ticks > 1, model.status == .idle {
            print("message: \(model.message ?? "-")")
            print("récents: \(model.recents.map { "\($0.name) \(formatTime($0.duration))" })")
            exit(model.messageIsError ? 1 : 0)
        }
        if ticks > 40 { print("TIMEOUT"); exit(2) }
    }
    model.toggleRecord()
    app.run()
}

// --persist : écrit les réglages, relit tout dans un modèle neuf, compare.
if arguments.contains("--persist") {
    let name = "sillio.persist.test"
    UserDefaults().removePersistentDomain(forName: name)
    let first = AppModel(defaults: UserDefaults(suiteName: name)!)
    first.sourceID = "Firefox"
    first.format = .flac
    first.folder = URL(fileURLWithPath: "/tmp/Sillio/Ailleurs")
    first.customName = "mon titre"
    first.autoStop = false
    first.silenceSeconds = 5.5
    first.mute = true
    first.overlayEnabled = false

    let second = AppModel(defaults: UserDefaults(suiteName: name)!)
    let checks: [(String, Bool)] = [
        ("source", second.sourceID == "Firefox"),
        ("format", second.format == .flac),
        ("dossier", second.folder.path == "/tmp/Sillio/Ailleurs"),
        ("nom", second.customName == "mon titre"),
        ("arrêt auto", second.autoStop == false),
        ("silence", second.silenceSeconds == 5.5),
        ("muet", second.mute == true),
        ("overlay", second.overlayEnabled == false),
    ]
    for (label, ok) in checks { print("\(ok ? "✓" : "✗") \(label)") }
    UserDefaults().removePersistentDomain(forName: name)
    exit(checks.allSatisfy(\.1) ? 0 : 1)
}

// --view : affiche une vue dans une fenêtre sans bordure, prête à être photographiée.
let view = option("--view") ?? "main"
model.recents = sampleRecents
model.sourceID = "Firefox"
model.refreshSources()

let content: AnyView
switch view {
case "settings":
    model.showSettings = true
    content = AnyView(PanelView(model: model))
case "main-rec":
    model.status = .recording
    model.seconds = 97
    model.levels = sampleLevels(60)
    content = AnyView(PanelView(model: model))
case "overlay-rec":
    model.status = .recording
    model.seconds = 97
    model.levels = sampleLevels(60)
    content = AnyView(OverlayView(model: model))
case "overlay-wait":
    model.status = .waitingForSound
    model.levels = []
    content = AnyView(OverlayView(model: model))
default:
    model.message = "Firefox 2026-09-27 00-12.mp3, 02:58"
    content = AnyView(PanelView(model: model))
}

let hosting = NSHostingView(rootView: content.fixedSize())
hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
let window = NSWindow(contentRect: hosting.frame,
                      styleMask: [.borderless],
                      backing: .buffered,
                      defer: false)
window.contentView = hosting
window.isOpaque = false
window.backgroundColor = view.hasPrefix("overlay") ? .clear : .windowBackgroundColor
window.hasShadow = view.hasPrefix("overlay")
window.setFrameTopLeftPoint(NSPoint(x: 80, y: (NSScreen.main?.frame.height ?? 900) - 80))
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

try? "\(window.windowNumber)".write(toFile: arguments.last!, atomically: true, encoding: .utf8)
app.run()

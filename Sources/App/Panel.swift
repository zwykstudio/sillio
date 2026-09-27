// Modèle et interface du panneau de Sillio.app.
// Le panneau ne montre qu'une décision : quoi enregistrer. Le reste est derrière l'engrenage.

import AppKit
import SwiftUI

struct RecentRecording: Codable, Identifiable, Hashable {
    let path: String
    let duration: Double
    let date: Date

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    init(url: URL, duration: Double) {
        self.init(path: url.path, duration: duration, date: Date())
    }

    init(path: String, duration: Double, date: Date) {
        self.path = path
        self.duration = duration
        self.date = date
    }
}

final class AppModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case waitingForApp(String)
        case waitingForSound
        case recording
        case exporting
    }

    @Published var status: Status = .idle
    @Published var sources: [AudioSource] = [AudioSource.everythingSource]
    @Published var levels: [Float] = []
    @Published var seconds: Int = 0
    @Published var message: String?
    @Published var messageIsError = false
    @Published var needsPermission = false
    @Published var recents: [RecentRecording] = []
    @Published var showSettings = false
    /// Icônes des apps : cherchées une seule fois par app, l'appel système est lent.
    @Published var icons: [String: NSImage] = [:]

    @Published var sourceID: String { didSet { defaults.set(sourceID, forKey: "sourceID") } }
    @Published var format: OutputFormat { didSet { defaults.set(format.rawValue, forKey: "format") } }
    @Published var folder: URL { didSet { defaults.set(folder.path, forKey: "folder") } }
    @Published var customName: String { didSet { defaults.set(customName, forKey: "customName") } }
    @Published var autoStop: Bool { didSet { defaults.set(autoStop, forKey: "autoStop") } }
    @Published var silenceSeconds: Double { didSet { defaults.set(silenceSeconds, forKey: "silenceSeconds") } }
    @Published var mute: Bool { didSet { defaults.set(mute, forKey: "mute") } }
    @Published var overlayEnabled: Bool { didSet { defaults.set(overlayEnabled, forKey: "overlayEnabled") } }

    /// Revérifié à chaque ouverture du panneau et toutes les 3 s : ffmpeg peut être installé
    /// pendant que l'app tourne (bouton « Installer ffmpeg »), sans qu'il faille la relancer.
    @Published var ffmpegAvailable = ffmpegInstalled()
    private let defaults: UserDefaults
    private let overlay = OverlayController()
    private var capture: Capture?
    private var refreshTimer: Timer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        sourceID = defaults.string(forKey: "sourceID") ?? AudioSource.everything
        // Premier lancement : MP3 seulement si ffmpeg est là, sinon M4A, qui marche partout.
        format = OutputFormat(rawValue: defaults.string(forKey: "format") ?? "")
            ?? (ffmpegInstalled() ? .mp3 : .m4a)
        folder = defaults.string(forKey: "folder").map { URL(fileURLWithPath: $0) }
            ?? music.appendingPathComponent("Sillio")
        customName = defaults.string(forKey: "customName") ?? ""
        autoStop = defaults.object(forKey: "autoStop") as? Bool ?? true
        silenceSeconds = defaults.object(forKey: "silenceSeconds") as? Double ?? 3
        mute = defaults.bool(forKey: "mute")
        overlayEnabled = defaults.object(forKey: "overlayEnabled") as? Bool ?? true
        if let data = defaults.data(forKey: "recents"),
           let saved = try? JSONDecoder().decode([RecentRecording].self, from: data) {
            recents = saved.filter(\.exists)
        }
        refreshSources()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshSourcesInBackground()
        }
    }

    // MARK: État affiché

    var isActive: Bool { status != .idle && status != .exporting }
    var isRecording: Bool { status == .recording }
    var timecode: String { formatTime(Double(seconds)) }
    var formatAvailable: Bool { !format.needsFFmpeg || ffmpegAvailable }

    var sourceName: String {
        sourceID == AudioSource.everything
            ? AudioSource.everythingSource.name
            : sources.first { $0.id == sourceID }?.name ?? sourceID
    }

    var waitingTitle: String {
        switch status {
        case .waitingForApp(let name): return tr("Waiting for \(name)", "En attente de \(name)")
        case .exporting: return tr("Converting", "Conversion")
        default: return tr("Ready", "Prêt")
        }
    }

    var overlayCaption: String {
        switch status {
        case .waitingForSound: return tr("Starts at the first sound", "Démarre au premier son")
        case .waitingForApp(let name): return tr("\(name) hasn't played anything yet", "\(name) n'a encore rien joué")
        case .exporting: return tr("Writing the file", "Écriture du fichier")
        default: return tr("\(sourceName) to \(format.ext.uppercased())", "\(sourceName) en \(format.ext.uppercased())")
        }
    }

    /// Une ligne, jamais plus : format, destination, et ce qui sort de l'ordinaire.
    var shortSummary: String {
        var parts = [tr("\(format.ext.uppercased()) to \(folder.lastPathComponent)",
                         "\(format.ext.uppercased()) dans \(folder.lastPathComponent)")]
        if autoStop { parts.append(tr("auto stop", "arrêt auto")) }
        if mute { parts.append(tr("muted", "son coupé")) }
        if !overlayEnabled { parts.append(tr("no window", "sans fenêtre")) }
        return parts.joined(separator: ", ")
    }

    var formatCaption: String {
        switch format {
        case .mp3:
            return ffmpegAvailable
                ? tr("320 kbps, plays everywhere", "320 kb/s, lisible partout")
                : tr("macOS has no MP3 encoder: MP3 needs ffmpeg, a free tool.",
                     "macOS n'a pas d'encodeur MP3 : il faut ffmpeg, un outil gratuit.")
        case .m4a: return tr("AAC 256 kbps, small files", "AAC 256 kb/s, fichiers légers")
        case .flac: return tr("Lossless, about 5 times larger than MP3", "Sans perte, environ 5 fois plus lourd que le MP3")
        case .wav: return tr("Lossless, uncompressed, very large", "Sans perte, non compressé, très lourd")
        }
    }

    /// Une phrase d'état, pour les journaux et les tests.
    var statusLine: String {
        switch status {
        case .idle: return tr("Ready", "Prêt")
        case .waitingForApp(let name): return tr("Waiting for \(name)", "En attente de \(name)")
        case .waitingForSound: return tr("Waiting for sound", "En attente de son")
        case .recording: return tr("Recording \(timecode)", "Enregistrement \(timecode)")
        case .exporting: return tr("Converting", "Conversion")
        }
    }

    var buttonTitle: String {
        switch status {
        case .idle: return tr("Record", "Enregistrer")
        case .waitingForApp, .waitingForSound: return tr("Cancel", "Annuler")
        case .recording: return tr("Stop", "Arrêter")
        case .exporting: return tr("Converting…", "Conversion…")
        }
    }

    func refreshSources() {
        apply(audioSources())
        refreshFFmpeg()
    }

    private func refreshFFmpeg() {
        let found = ffmpegInstalled()
        if found != ffmpegAvailable { ffmpegAvailable = found }
    }

    /// Le balayage des processus audio ne doit pas occuper le thread principal.
    private func refreshSourcesInBackground() {
        guard !isActive else { return }  // inutile pendant une capture
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let list = audioSources()
            DispatchQueue.main.async {
                self?.apply(list)
                self?.refreshFFmpeg()
            }
        }
    }

    private func apply(_ found: [AudioSource]) {
        var list = found
        // Garder l'app choisie dans la liste même quand elle ne joue rien.
        if sourceID != AudioSource.everything, !list.contains(where: { $0.id == sourceID }) {
            list.append(AudioSource(id: sourceID, name: sourceID, playing: false))
        }
        sources = list

        let missing = list.map(\.id).filter { $0 != AudioSource.everything && icons[$0] == nil }
        guard !missing.isEmpty else { return }
        let running = NSWorkspace.shared.runningApplications
        for name in missing {
            let match = running.first { $0.localizedName == name || $0.executableURL?.lastPathComponent == name }
            if let icon = match?.icon { icons[name] = icon }
        }
    }

    // MARK: Enregistrement

    func toggleRecord() {
        if let capture {
            capture.stop()
            self.capture = nil
            return
        }
        message = nil
        needsPermission = false
        switch AudioCapturePermission.status() {
        case .denied:
            show(tr("Sillio isn't allowed to record system audio.",
                    "Sillio n'a pas l'autorisation d'enregistrer le son du système."), error: true)
            needsPermission = true
        case .notAsked:
            DispatchQueue.global().async { [weak self] in
                let granted = AudioCapturePermission.request()
                DispatchQueue.main.async {
                    if granted {
                        self?.beginRecording()
                    } else {
                        self?.show(tr("Permission denied.", "Autorisation refusée."), error: true)
                        self?.needsPermission = true
                    }
                }
            }
        default:
            beginRecording()
        }
    }

    private func beginRecording() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            show(tr("Folder unavailable: \(error.localizedDescription)",
                     "Dossier inaccessible : \(error.localizedDescription)"), error: true)
            return
        }
        refreshFFmpeg()
        guard formatAvailable else {
            show(tr("MP3 needs ffmpeg: install it from the settings, or pick M4A.",
                    "Le MP3 demande ffmpeg : installe-le depuis les réglages, ou choisis M4A."), error: true)
            return
        }

        let output = availableURL(folder.appendingPathComponent(outputName()).appendingPathExtension(format.ext))
        let capture = Capture(settings: CaptureSettings(
            sourceID: sourceID,
            output: output,
            mute: mute,
            silenceStop: autoStop ? silenceSeconds : nil))
        capture.onLevel = { [weak self] peak, seconds in
            guard let self else { return }
            self.seconds = Int(seconds)
            self.levels.append(Self.normalized(peak))
            if self.levels.count > 200 { self.levels.removeFirst(self.levels.count - 200) }
        }
        capture.onState = { [weak self] state in self?.handle(state) }
        self.capture = capture
        status = .waitingForSound
        levels = []
        seconds = 0
        showSettings = false
        if overlayEnabled { overlay.show(model: self) }
        capture.start()
    }

    /// Peak linéaire → hauteur de barre, en dB (−60 dB = rien, 0 dB = plein).
    private static func normalized(_ peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        return min(1, max(0, (20 * log10(peak) + 60) / 60))
    }

    private func outputName() -> String {
        let typed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            return typed.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let source = sourceID == AudioSource.everything ? "Mac" : sourceID
        return "\(source) \(formatter.string(from: Date()))"
    }

    private func handle(_ state: Capture.State) {
        switch state {
        case .waitingForApp(let name):
            status = .waitingForApp(name)
        case .waitingForSound:
            status = .waitingForSound
        case .recording:
            status = .recording
        case .exporting:
            status = .exporting
        case .finished(let recording):
            finish()
            recents.insert(RecentRecording(url: recording.url, duration: recording.duration), at: 0)
            recents = Array(recents.prefix(8))
            saveRecents()
            show("\(recording.url.lastPathComponent), \(formatTime(recording.duration))", error: false)
            clearMessageLater()
        case .cancelled:
            finish()
            message = nil
        case .failed(let error):
            finish()
            show(error.localizedDescription, error: true)
        }
    }

    private func finish() {
        status = .idle
        capture = nil
        levels = []
        overlay.hide()
    }

    /// La confirmation n'a plus lieu d'être une fois le fichier visible dans la liste.
    private func clearMessageLater() {
        let shown = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.message == shown { self?.message = nil }
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recents) { defaults.set(data, forKey: "recents") }
    }

    // MARK: Actions

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = tr("Choose", "Choisir")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    /// Ouvre le Terminal sur un script qui installe ffmpeg avec Homebrew (et Homebrew d'abord,
    /// après confirmation, s'il manque). Tout se passe sous les yeux de l'utilisateur, qui tape
    /// lui-même son mot de passe ; l'app détecte ffmpeg toute seule une fois installé.
    func installFFmpeg() {
        let script = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(tr("Install ffmpeg for Sillio.command", "Installer ffmpeg pour Sillio.command"))
        do {
            try ffmpegInstallScript().write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            show(tr("Couldn't open Terminal: \(error.localizedDescription)",
                    "Impossible d'ouvrir le Terminal : \(error.localizedDescription)"), error: true)
        }
    }

    func ffmpegInstallScript() -> String {
        #"""
        #!/bin/bash
        # Installe ffmpeg pour Sillio (export MP3). Écrit et ouvert par l'app.
        clear
        echo "Sillio — \#(tr("installing ffmpeg, needed for MP3 export", "installation de ffmpeg, nécessaire à l'export MP3"))"
        echo
        find_brew() {
          for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
            [ -x "$candidate" ] && { echo "$candidate"; return; }
          done
        }
        BREW=$(find_brew)
        if [ -z "$BREW" ]; then
          echo "\#(tr("ffmpeg installs with Homebrew, the usual package manager for macOS (brew.sh).",
                     "ffmpeg s'installe avec Homebrew, le gestionnaire de paquets habituel de macOS (brew.sh)."))"
          echo "\#(tr("Homebrew isn't on this Mac yet: it will be installed first. It will ask for your password.",
                     "Homebrew n'est pas encore sur ce Mac : il sera installé d'abord. Il demandera ton mot de passe."))"
          echo
          read -r -p "\#(tr("Press Enter to continue, or close this window to cancel. ",
                             "Appuie sur Entrée pour continuer, ou ferme cette fenêtre pour annuler. "))"
          /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || exit 1
          BREW=$(find_brew)
          [ -z "$BREW" ] && { echo "\#(tr("Homebrew wasn't installed.", "Homebrew n'a pas été installé."))"; exit 1; }
        fi
        "$BREW" install ffmpeg || exit 1
        echo
        echo "✅ \#(tr("ffmpeg is installed. Sillio picks it up by itself: you can close this window.",
                       "ffmpeg est installé. Sillio le détecte tout seul : tu peux fermer cette fenêtre."))"
        """#
    }

    func forget(_ item: RecentRecording) {
        recents.removeAll { $0.id == item.id }
        saveRecents()
    }
}

// MARK: - Panneau

struct PanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            if model.showSettings {
                SettingsView(model: model)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                MainView(model: model)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.showSettings)
        .frame(width: Metric.panelWidth)
        .onAppear { model.refreshSources() }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SourceMenu(model: model)

            if model.isActive {
                HStack(spacing: 7) {
                    RecordLamp(recording: model.isRecording)
                    Text(model.isRecording ? tr("Recording", "Enregistrement") : model.waitingTitle)
                    Spacer(minLength: 4)
                    Text(model.timecode).font(.timecode(11))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                LevelTrace(levels: model.levels,
                           color: model.isRecording ? Ink.trace : Ink.armed.opacity(0.8))
                    .frame(height: 18)
            }

            Button { model.toggleRecord() } label: {
                HStack(spacing: 7) {
                    Image(systemName: model.isActive ? "stop.fill" : "largecircle.fill.circle")
                        .font(.system(size: model.isActive ? 11 : 13))
                        .foregroundStyle(model.isActive ? Ink.signal : .white)
                    Text(model.buttonTitle)
                }
            }
            .buttonStyle(RecordButtonStyle(active: model.isActive))
            .disabled(model.status == .exporting)
            .keyboardShortcut(.defaultAction)

            // Une seule ligne d'information : le dernier résultat, sinon le résumé des réglages.
            Button { model.showSettings = true } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if let message = model.message {
                        Image(systemName: model.messageIsError ? "exclamationmark.triangle.fill" : "checkmark")
                            .font(.system(size: 9, weight: .bold))
                        Text(message).lineLimit(model.messageIsError ? 3 : 1)
                    } else if !model.formatAvailable {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text(tr("MP3 needs ffmpeg: set it up", "Le MP3 demande ffmpeg : l'installer"))
                            .lineLimit(1)
                    } else {
                        Text(model.shortSummary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(model.messageIsError || (model.message == nil && !model.formatAvailable)
                                 ? Ink.signal : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("Settings", "Réglages"))

            if model.needsPermission {
                Button(tr("Allow in System Settings", "Autoriser dans les réglages système")) {
                    NSWorkspace.shared.open(AudioCapturePermission.settingsURL)
                }
                .buttonStyle(PillButtonStyle())
            }

            if !model.recents.isEmpty {
                Divider().overlay(Ink.hairline)
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(model.recents.prefix(3)) { item in
                        RecentRow(item: item, model: model)
                    }
                }
            }

            HStack(spacing: 2) {
                Button { model.showSettings = true } label: { Image(systemName: "gearshape") }
                    .buttonStyle(GlyphButtonStyle(size: 24))
                    .help(tr("Settings", "Réglages"))
                Spacer()
                Button { model.reveal(model.folder) } label: { Image(systemName: "folder") }
                    .buttonStyle(GlyphButtonStyle(size: 24))
                    .help(tr("Open the recordings folder", "Ouvrir le dossier des enregistrements"))
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(GlyphButtonStyle(size: 24))
                    .help(tr("Quit Sillio", "Quitter Sillio"))
            }
            .padding(.top, 2)
        }
        .padding(14)
    }
}

struct SourceMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu {
            Button(AudioSource.everythingSource.name) { model.sourceID = AudioSource.everything }
            let apps = model.sources.filter { $0.id != AudioSource.everything }
            if !apps.isEmpty {
                Divider()
                ForEach(apps) { source in
                    Button {
                        model.sourceID = source.id
                    } label: {
                        if let icon = model.icons[source.id] { Image(nsImage: icon) }
                        Text(source.playing ? "\(source.name)  ◀))" : source.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                SourceIcon(name: model.sourceID, icon: model.icons[model.sourceID])
                Text(model.sourceName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(FieldButtonStyle())
        .menuIndicator(.hidden)
        .disabled(model.isActive)
    }
}

/// L'icône de l'app quand on la connaît, sinon un haut-parleur pour « tout le son ».
struct SourceIcon: View {
    let name: String
    let icon: NSImage?

    var body: some View {
        if let icon {
            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: name == AudioSource.everything ? "speaker.wave.2" : "waveform")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
    }
}

struct RecentRow: View {
    let item: RecentRecording
    @ObservedObject var model: AppModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(item.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(formatTime(item.duration))
                .font(.timecode(10))
                .foregroundStyle(.secondary)
            Button { model.reveal(item.url) } label: { Image(systemName: "folder") }
                .buttonStyle(GlyphButtonStyle(size: 18))
                .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Ink.surface : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { NSWorkspace.shared.open(item.url) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button(tr("Show in Finder", "Afficher dans le Finder")) { model.reveal(item.url) }
            Button(tr("Remove from list", "Retirer de la liste")) { model.forget(item) }
        }
    }
}

// MARK: - Réglages

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Button { model.showSettings = false } label: { Image(systemName: "chevron.backward") }
                    .buttonStyle(GlyphButtonStyle(size: 24))
                Text(tr("Settings", "Réglages")).font(.system(size: 13, weight: .semibold))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: $model.format) {
                    ForEach(OutputFormat.allCases) { format in
                        Text(format.ext.uppercased()).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(model.formatCaption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !model.formatAvailable {
                    HStack(spacing: 6) {
                        Button(tr("Install ffmpeg…", "Installer ffmpeg…")) { model.installFFmpeg() }
                            .buttonStyle(PillButtonStyle(prominent: true))
                            .help(tr("Opens Terminal and installs ffmpeg with Homebrew",
                                     "Ouvre le Terminal et installe ffmpeg avec Homebrew"))
                        Button(tr("Use M4A", "Passer en M4A")) { model.format = .m4a }
                            .buttonStyle(PillButtonStyle())
                    }
                    .padding(.top, 2)
                }
            }

            Button { model.chooseFolder() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(model.folder.lastPathComponent).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(tr("Change", "Changer")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(FieldButtonStyle())
            .help(model.folder.path)

            TextField(tr("automatic name", "nom automatique"), text: $model.customName)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: Metric.radius, style: .continuous).fill(Ink.surface))
                .overlay(RoundedRectangle(cornerRadius: Metric.radius, style: .continuous).strokeBorder(Ink.hairline))

            Divider().overlay(Ink.hairline)

            VStack(alignment: .leading, spacing: 9) {
                Toggle(tr("Stop at the end of a track", "Arrêt automatique en fin de morceau"), isOn: $model.autoStop)
                if model.autoStop {
                    HStack(spacing: 8) {
                        Text(tr("after", "après")).font(.system(size: 11)).foregroundStyle(.secondary)
                        PlusMinus(value: $model.silenceSeconds, range: 1...15, step: 0.5) {
                            "\(String(format: "%g", $0)) s"
                        }
                        Text(tr("of silence", "de silence")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Toggle(tr("Mute the speakers while recording", "Couper le son pendant la capture"), isOn: $model.mute)
                Toggle(tr("Floating window while recording", "Fenêtre flottante pendant la capture"), isOn: $model.overlayEnabled)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
        }
        .padding(14)
    }
}

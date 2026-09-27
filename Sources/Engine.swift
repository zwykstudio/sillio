// Moteur de capture audio partagé par le CLI (sillio) et l'app (Sillio.app).
//
// Utilise les « process taps » Core Audio (macOS 14.2+) : pas de driver virtuel à installer.
// Le son est capté en numérique, avant le volume système, donc sans perte ni bruit.

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Utilitaires

struct Failure: Error, LocalizedError, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
    var errorDescription: String? { description }
}

struct Cancelled: Error {}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else {
        throw Failure(tr("\(what) failed (OSStatus \(status))", "\(what) a échoué (OSStatus \(status))"))
    }
}

func formatTime(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return String(format: "%02d:%02d", s / 60, s % 60)
}

func findExecutable(_ name: String) -> URL? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    // Une app lancée depuis le Finder n'a pas le PATH du shell : on ajoute les chemins Homebrew.
    let directories = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
    return directories
        .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

/// SILLIO_NO_FFMPEG=1 fait comme s'il manquait : pour tester ce cas sans le désinstaller.
func ffmpegInstalled() -> Bool {
    ProcessInfo.processInfo.environment["SILLIO_NO_FFMPEG"] == nil && findExecutable("ffmpeg") != nil
}

/// Formats écrits par macOS lui-même. Tous les autres (MP3 en tête) passent par ffmpeg.
func needsFFmpeg(_ url: URL) -> Bool {
    !["m4a", "aac", "flac", "wav", "aiff", "caf"].contains(url.pathExtension.lowercased())
}

/// Ne jamais écraser un fichier existant : « nom.mp3 » → « nom-2.mp3 ».
func availableURL(_ url: URL) -> URL {
    var candidate = url
    var index = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
        let base = url.deletingPathExtension().lastPathComponent
        candidate = url.deletingLastPathComponent()
            .appendingPathComponent("\(base)-\(index)")
            .appendingPathExtension(url.pathExtension)
        index += 1
    }
    return candidate
}

// MARK: - Propriétés Core Audio

func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector,
                               mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

func readValue<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) throws -> T {
    var address = propertyAddress(selector)
    var size = UInt32(MemoryLayout<T>.size)
    var value = initial
    try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value), tr("Reading a property", "Lecture de propriété"))
    return value
}

func readObjectList(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
    var address = propertyAddress(selector)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size), tr("Reading a list", "Lecture de liste"))
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ids), tr("Reading a list", "Lecture de liste"))
    return ids
}

func readString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var address = propertyAddress(selector)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>?
    try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value), tr("Reading a string", "Lecture de chaîne"))
    return value?.takeRetainedValue() as String? ?? ""
}

// MARK: - Processus qui jouent du son

struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let name: String
    let app: String  // app responsable, ex. « Google Chrome » pour « Google Chrome Helper »
    let bundleID: String
    let playing: Bool

    func matches(_ query: String) -> Bool {
        let q = query.lowercased()
        return [name, app, bundleID].contains { $0.lowercased().contains(q) }
    }
}

func executableName(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "?" }
    return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
}

/// Les navigateurs jouent le son depuis un sous-processus (Chrome Helper, WebKit GPU…) :
/// on remonte à l'app « responsable » pour que « safari » ou « chrome » suffise à la désigner.
let responsiblePID: (pid_t) -> pid_t = {
    typealias Fn = @convention(c) (pid_t) -> pid_t
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    guard let symbol = dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid") else { return { $0 } }
    let fn = unsafeBitCast(symbol, to: Fn.self)
    return { pid in
        let responsible = fn(pid)
        return responsible > 0 ? responsible : pid
    }
}()

func audioProcesses() throws -> [AudioProcess] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    return try readObjectList(system, kAudioHardwarePropertyProcessObjectList).compactMap { id in
        guard let pid = try? readValue(id, kAudioProcessPropertyPID, pid_t(0)), pid > 0, pid != getpid() else {
            return nil
        }
        let running = (try? readValue(id, kAudioProcessPropertyIsRunningOutput, UInt32(0))) ?? 0
        return AudioProcess(objectID: id,
                            pid: pid,
                            name: executableName(pid),
                            app: executableName(responsiblePID(pid)),
                            bundleID: (try? readString(id, kAudioProcessPropertyBundleID)) ?? "",
                            playing: running != 0)
    }
}

/// Une app regroupée (tous ses processus audio), telle que l'affiche l'app.
struct AudioSource: Identifiable, Hashable {
    let id: String  // AudioSource.everything, ou le nom de l'app
    let name: String
    let playing: Bool

    static let everything = "*"
    static let everythingSource = AudioSource(id: everything, name: tr("All Mac audio", "Tout le son du Mac"), playing: false)
}

func audioSources() -> [AudioSource] {
    let processes = (try? audioProcesses()) ?? []
    var byApp: [String: Bool] = [:]  // nom de l'app → joue du son
    for process in processes where !process.app.isEmpty && process.app != "?" {
        byApp[process.app] = (byApp[process.app] ?? false) || process.playing
    }
    let sources = byApp
        .map { AudioSource(id: $0.key, name: $0.key, playing: $0.value) }
        .sorted { ($0.playing ? 0 : 1, $0.name.lowercased()) < ($1.playing ? 0 : 1, $1.name.lowercased()) }
    return [AudioSource.everythingSource] + sources
}

// MARK: - Permission « Enregistrement audio du système »

/// API privée TCC : sans la permission, macOS ne renvoie pas d'erreur, juste du silence.
enum AudioCapturePermission {
    enum Status { case granted, denied, notAsked, unknown }

    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let service = "kTCCServiceAudioCapture" as CFString

    static func status() -> Status {
        typealias Fn = @convention(c) (CFString, CFDictionary?) -> Int
        guard let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: Fn.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        case 2: return .notAsked
        default: return .unknown
        }
    }

    /// Affiche la demande système. Bloquant : à appeler hors du thread principal.
    static func request() -> Bool {
        typealias Fn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
        guard let symbol = dlsym(tcc, "TCCAccessRequest") else { return true }
        let done = DispatchSemaphore(value: 0)
        var granted = false
        unsafeBitCast(symbol, to: Fn.self)(service, nil) { ok in
            granted = ok
            done.signal()
        }
        done.wait()
        return granted
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}

// MARK: - Formats de sortie

enum OutputFormat: String, CaseIterable, Identifiable {
    case mp3, m4a, flac, wav

    var id: String { rawValue }
    var ext: String { rawValue }
    var name: String {
        switch self {
        case .mp3: return tr("MP3 320 kbps", "MP3 320 kb/s")
        case .m4a: return tr("M4A (AAC 256 kbps)", "M4A (AAC 256 kb/s)")
        case .flac: return tr("FLAC (lossless)", "FLAC (sans perte)")
        case .wav: return tr("WAV 24-bit", "WAV 24 bits")
        }
    }

    /// Aucun encodeur MP3 dans macOS : celui-là passe par ffmpeg.
    var needsFFmpeg: Bool { self == .mp3 }
    var available: Bool { !needsFFmpeg || ffmpegInstalled() }
}

// MARK: - Capture

struct Recording {
    let url: URL
    let duration: Double
}

struct CaptureSettings {
    var sourceID: String?  // nil ou AudioSource.everything = tout le son du Mac
    var output: URL
    var mute = false
    var silenceStop: Double?  // arrêt auto après N secondes de silence
    var maxDuration: Double?
    var threshold: Float = 0.001  // -60 dBFS : en dessous, on considère que c'est du silence
}

final class Capture {
    enum State {
        case waitingForApp(String)
        case waitingForSound
        case recording
        case exporting
        case finished(Recording)
        case cancelled
        case failed(Error)
    }

    let settings: CaptureSettings
    let rawURL: URL

    /// Appelés sur le thread principal.
    var onState: ((State) -> Void)?
    var onLevel: ((_ peak: Float, _ seconds: Double) -> Void)?

    // `io` : callback audio et compteurs. `control` : démarrage, arrêt, export.
    // Les deux files sont séparées : arrêter le périphérique depuis `io` bloquerait Core Audio.
    private let io = DispatchQueue(label: "sillio.io", qos: .userInteractive)
    private let control = DispatchQueue(label: "sillio.control")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var format: AVAudioFormat!
    private var file: AVAudioFile?
    private var levelTimer: DispatchSourceTimer?

    // État `io`
    private var started = false
    private var finished = false
    private var written: AVAudioFramePosition = 0     // frames écrites dans le WAV brut
    private var soundStart: AVAudioFramePosition = 0  // premier frame audible
    private var soundEnd: AVAudioFramePosition = 0    // fin du dernier frame audible
    private var peak: Float = 0

    // État `control`
    private var stopping = false
    private let cancelLock = NSLock()
    private var cancelRequested = false

    init(settings: CaptureSettings) {
        self.settings = settings
        rawURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sillio-\(UUID().uuidString).wav")
    }

    private var cancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelRequested
    }

    private func emit(_ state: State) {
        DispatchQueue.main.async { self.onState?(state) }
    }

    func start() {
        control.async {
            do {
                let description = try self.makeTapDescription()
                try self.begin(with: description)
                self.emit(.waitingForSound)
            } catch is Cancelled {
                self.emit(.cancelled)
            } catch {
                self.cleanUpAudio()
                self.emit(.failed(error))
            }
        }
    }

    /// Arrête et exporte ce qui a été capté (ou annule si rien n'a encore été entendu).
    func stop() {
        cancelLock.lock()
        cancelRequested = true
        cancelLock.unlock()
        control.async { self.teardown() }
    }

    // MARK: Mise en place

    private func makeTapDescription() throws -> CATapDescription {
        let description: CATapDescription
        if let query = settings.sourceID, query != AudioSource.everything {
            var matches = try audioProcesses().filter { $0.app == query || $0.matches(query) }
            if matches.isEmpty {
                emit(.waitingForApp(query))
                while matches.isEmpty {
                    if cancelled { throw Cancelled() }
                    Thread.sleep(forTimeInterval: 0.5)
                    matches = try audioProcesses().filter { $0.app == query || $0.matches(query) }
                }
            }
            description = CATapDescription(stereoMixdownOfProcesses: matches.map(\.objectID))
            if #available(macOS 26.0, *) {
                description.isProcessRestoreEnabled = true  // suit l'app si son process audio redémarre
            }
        } else {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        if cancelled { throw Cancelled() }
        description.uuid = UUID()
        description.name = "sillio"
        description.isPrivate = true
        description.muteBehavior = settings.mute ? .mutedWhenTapped : .unmuted
        return description
    }

    private func begin(with description: CATapDescription) throws {
        try check(AudioHardwareCreateProcessTap(description, &tapID), tr("Creating the audio tap", "Création du tap audio"))

        var streamDescription = try readValue(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &streamDescription),
              format.commonFormat == .pcmFormatFloat32 else {
            throw Failure(tr("Unsupported tap audio format", "Format audio du tap non pris en charge"))
        }
        self.format = format

        let outputDevice = try readValue(AudioObjectID(kAudioObjectSystemObject),
                                         kAudioHardwarePropertyDefaultSystemOutputDevice,
                                         AudioDeviceID(kAudioObjectUnknown))
        let outputUID = try readString(outputDevice, kAudioDevicePropertyDeviceUID)
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "sillio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                  tr("Creating the aggregate device", "Création du périphérique agrégé"))

        file = try AVAudioFile(forWriting: rawURL,
                               settings: format.settings,
                               commonFormat: .pcmFormatFloat32,
                               interleaved: format.isInterleaved)

        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, io) { [weak self] _, input, _, _, _ in
            self?.process(input)
        }, tr("Creating the audio callback", "Création du callback audio"))
        try check(AudioDeviceStart(aggregateID, ioProcID), tr("Starting the capture", "Démarrage de la capture"))

        let timer = DispatchSource.makeTimerSource(queue: io)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.reportLevel() }
        timer.resume()
        levelTimer = timer
    }

    // MARK: Capture

    /// Appelé sur `io` à chaque bloc audio (~10 ms).
    private func process(_ input: UnsafePointer<AudioBufferList>) {
        guard !finished, let file,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
              let data = buffer.floatChannelData else { return }

        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let stride = buffer.stride
        let interleaved = format.isInterleaved
        var firstLoud = -1, lastLoud = -1
        for frame in 0..<frames {
            var level: Float = 0
            for channel in 0..<channels {
                let sample = interleaved ? data[0][frame * stride + channel] : data[channel][frame * stride]
                level = max(level, abs(sample))
            }
            peak = max(peak, level)
            if level > settings.threshold {
                if firstLoud < 0 { firstLoud = frame }
                lastLoud = frame
            }
        }

        if !started {
            guard firstLoud >= 0 else { return }  // on n'écrit rien tant que c'est silencieux
            started = true
            soundStart = AVAudioFramePosition(firstLoud)
            emit(.recording)
        }

        do {
            try file.write(from: buffer)
        } catch {
            finished = true
            control.async { self.teardown(error: error) }
            return
        }
        if lastLoud >= 0 { soundEnd = written + AVAudioFramePosition(lastLoud) + 1 }
        written += AVAudioFramePosition(frames)

        let sampleRate = format.sampleRate
        if let maxDuration = settings.maxDuration,
           written - soundStart >= AVAudioFramePosition(maxDuration * sampleRate) {
            finished = true
            control.async { self.teardown() }
        } else if let silence = settings.silenceStop,
                  written - soundEnd >= AVAudioFramePosition(silence * sampleRate) {
            finished = true
            control.async { self.teardown() }
        }
    }

    /// Appelé sur `io` toutes les 100 ms.
    private func reportLevel() {
        guard started else { return }
        let seconds = Double(written - soundStart) / format.sampleRate
        let level = peak
        peak = 0
        DispatchQueue.main.async { self.onLevel?(level, seconds) }
    }

    // MARK: Arrêt et export

    private func cleanUpAudio() {
        io.sync {
            finished = true
            levelTimer?.cancel()
            levelTimer = nil
        }
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        io.sync {
            if #available(macOS 15.0, *) { file?.close() }
            file = nil
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func teardown(error: Error? = nil) {
        guard !stopping else { return }
        stopping = true
        cleanUpAudio()

        var didStart = false
        var from: AVAudioFramePosition = 0
        var to: AVAudioFramePosition = 0
        io.sync {
            didStart = started
            from = soundStart
            to = soundEnd
        }

        if let error {
            emit(.failed(error))
            return
        }
        guard didStart else {
            try? FileManager.default.removeItem(at: rawURL)
            emit(cancelled ? .cancelled : .failed(Failure(tr("No sound captured.", "Aucun son capté."))))
            return
        }

        let sampleRate = format.sampleRate
        if let maxDuration = settings.maxDuration {
            to = min(to, from + AVAudioFramePosition(maxDuration * sampleRate))
        }
        emit(.exporting)
        do {
            try export(raw: rawURL, from: from, to: to, output: settings.output)
            try? FileManager.default.removeItem(at: rawURL)
            emit(.finished(Recording(url: settings.output, duration: Double(to - from) / sampleRate)))
        } catch {
            // ffmpeg a disparu entre le lancement et l'export : ne pas perdre la prise pour autant,
            // l'écrire en M4A (encodeur de macOS) à côté.
            if needsFFmpeg(settings.output), !ffmpegInstalled() {
                let fallback = availableURL(settings.output.deletingPathExtension().appendingPathExtension("m4a"))
                if (try? export(raw: rawURL, from: from, to: to, output: fallback)) != nil {
                    try? FileManager.default.removeItem(at: rawURL)
                    emit(.finished(Recording(url: fallback, duration: Double(to - from) / sampleRate)))
                    return
                }
            }
            emit(.failed(error))  // le WAV brut est conservé
        }
    }
}

// MARK: - Export (coupe les silences de début et de fin)

func export(raw: URL, from: AVAudioFramePosition, to: AVAudioFramePosition, output: URL) throws {
    if !needsFFmpeg(output) {
        try exportNatively(raw: raw, from: from, to: to, output: output)
    } else {
        // MP3 (pas d'encodeur dans macOS) et formats exotiques : ffmpeg.
        guard ffmpegInstalled(), let ffmpeg = findExecutable("ffmpeg") else {
            throw Failure(tr("The .\(output.pathExtension) format needs ffmpeg (brew install ffmpeg). "
                + "Without ffmpeg: M4A, FLAC or WAV.",
                "Le format .\(output.pathExtension) demande ffmpeg (brew install ffmpeg). "
                + "Sans ffmpeg : M4A, FLAC ou WAV."))
        }
        try exportWithFFmpeg(ffmpeg, raw: raw, from: from, to: to, output: output)
    }
}

private func exportNatively(raw: URL, from: AVAudioFramePosition, to: AVAudioFramePosition, output: URL) throws {
    let input = try AVAudioFile(forReading: raw)
    let sampleRate = input.processingFormat.sampleRate
    let channels = input.processingFormat.channelCount
    var settings: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
    switch output.pathExtension.lowercased() {
    case "m4a", "aac":
        settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
        settings[AVEncoderBitRateKey] = 256_000
    case "flac":
        settings[AVFormatIDKey] = kAudioFormatFLAC
        settings[AVLinearPCMBitDepthKey] = 24
    default:  // wav, aiff, caf
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        settings[AVLinearPCMBitDepthKey] = 24
        settings[AVLinearPCMIsFloatKey] = false
        settings[AVLinearPCMIsBigEndianKey] = output.pathExtension.lowercased() == "aiff"
        settings[AVLinearPCMIsNonInterleaved] = false
    }

    let out = try AVAudioFile(forWriting: output, settings: settings)
    let chunk: AVAudioFrameCount = 16384
    guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk) else {
        throw Failure(tr("Not enough memory to export", "Mémoire insuffisante pour l'export"))
    }
    input.framePosition = from
    var remaining = to - from
    while remaining > 0 {
        try input.read(into: buffer, frameCount: min(chunk, AVAudioFrameCount(remaining)))
        guard buffer.frameLength > 0 else { break }
        try out.write(from: buffer)
        remaining -= AVAudioFramePosition(buffer.frameLength)
    }
    if #available(macOS 15.0, *) { out.close() }
}

private func exportWithFFmpeg(_ ffmpeg: URL, raw: URL, from: AVAudioFramePosition, to: AVAudioFramePosition, output: URL) throws {
    // -nostdin + stdin vide : sinon ffmpeg tente de configurer le terminal depuis un
    // groupe de processus en arrière-plan, et macOS le suspend (SIGTTOU) indéfiniment.
    var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", raw.path,
                     "-af", "atrim=start_sample=\(from):end_sample=\(to)"]
    switch output.pathExtension.lowercased() {
    case "mp3": arguments += ["-c:a", "libmp3lame", "-b:a", "320k"]
    default: break  // ffmpeg choisit selon l'extension
    }
    arguments.append(output.path)

    let process = Process()
    process.executableURL = ffmpeg
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let detail = message.isEmpty ? "code \(process.terminationStatus)" : message
        throw Failure(tr("Conversion failed: \(detail)", "Conversion échouée : \(detail)"))
    }
}

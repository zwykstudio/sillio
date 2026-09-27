// sillio — version ligne de commande. Le moteur est dans Sources/Engine.swift.
// Le CLI parle toujours anglais, y compris les messages du moteur qu'il relaie.

import AVFoundation
import Foundation

Language.isFrench = false

func log(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

let isTTY = isatty(STDERR_FILENO) != 0

func paint(_ line: String) {
    guard isTTY else { return }
    FileHandle.standardError.write("\r\u{1B}[K\(line)".data(using: .utf8)!)
}

func clearLine() {
    guard isTTY else { return }
    FileHandle.standardError.write("\r\u{1B}[K".data(using: .utf8)!)
}

let usage = """
sillio — records the sound coming out of your Mac to a file.

Usage:
  sillio [options]        record (all audio, or a single app with -a)
  sillio list             list the apps that have an audio output

Options:
  -a, --app NAME          capture one app only (part of its name or bundle id: chrome, firefox…)
  -o, --out FILE          output file: .mp3 (320k, needs ffmpeg) .m4a .flac .wav …
                          default: .mp3, or .m4a when ffmpeg isn't installed
      --auto              stop by itself after a silence (ideal for one track)
  -s, --silence SEC       silence that triggers the stop in --auto mode (default: 3)
  -d, --duration SEC      maximum recording length
  -m, --mute              mute the app in the speakers while recording
  -h, --help

Silence at the start and at the end is trimmed automatically: start sillio, then playback.

Examples:
  sillio -a firefox --auto -o "my song.mp3"
  sillio -a spotify -m -d 60
  sillio                                         # all Mac audio, Ctrl-C to stop
"""

func listProcesses() throws {
    let processes = try audioProcesses().sorted {
        ($0.playing ? 0 : 1, $0.app.lowercased()) < ($1.playing ? 0 : 1, $1.app.lowercased())
    }
    guard !processes.isEmpty else {
        print("No audio process.")
        return
    }
    print("   PID     APP                     PROCESS                           BUNDLE ID")
    for p in processes {
        let app = p.app.padding(toLength: 22, withPad: " ", startingAt: 0)
        let name = p.name.padding(toLength: 32, withPad: " ", startingAt: 0)
        print("\(p.playing ? "▶" : " ")  \(String(p.pid).padding(toLength: 7, withPad: " ", startingAt: 0)) \(app)  \(name)  \(p.bundleID)")
    }
    print("\n▶ = playing sound. To record a single app: sillio -a <name>")
}

/// MP3 quand ffmpeg est là, sinon M4A : sans extension demandée, ça marche toujours.
let defaultExtension = ffmpegInstalled() ? "mp3" : "m4a"

struct CLIOptions {
    var app: String?
    var output: URL?
    var auto = false
    var silence = 3.0
    var duration: Double?
    var mute = false
}

func parseOptions(_ arguments: [String]) throws -> CLIOptions {
    var options = CLIOptions()
    var iterator = arguments.makeIterator()
    func value(for flag: String) throws -> String {
        guard let value = iterator.next() else { throw Failure("\(flag) needs a value") }
        return value
    }
    func number(for flag: String) throws -> Double {
        guard let number = Double(try value(for: flag)), number > 0 else { throw Failure("\(flag) needs a number > 0") }
        return number
    }
    while let argument = iterator.next() {
        switch argument {
        case "-a", "--app": options.app = try value(for: argument)
        case "-o", "--out":
            let path = (try value(for: argument) as NSString).expandingTildeInPath
            var url = URL(fileURLWithPath: path)
            if url.pathExtension.isEmpty { url.appendPathExtension(defaultExtension) }
            options.output = url
        case "--auto": options.auto = true
        case "-s", "--silence": options.silence = try number(for: argument)
        case "-d", "--duration": options.duration = try number(for: argument)
        case "-m", "--mute": options.mute = true
        case "-h", "--help":
            print(usage)
            exit(0)
        default: throw Failure("Unknown option: \(argument)\n\n\(usage)")
        }
    }
    return options
}

func defaultOutput(app: String?) -> URL {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    let prefix = app.map { $0.replacingOccurrences(of: " ", with: "-").lowercased() } ?? "rec"
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("\(prefix)-\(formatter.string(from: Date())).\(defaultExtension)")
}

func meter(_ peak: Float) -> String {
    let db = 20 * log10(max(peak, 1e-6))
    let width = 30
    let filled = max(0, min(width, Int((db + 60) / 60 * Float(width))))
    return String(repeating: "█", count: filled) + String(repeating: "·", count: width - filled)
}

// MARK: - Programme

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "list" {
        try listProcesses()
        exit(0)
    }
    let options = try parseOptions(arguments)

    switch AudioCapturePermission.status() {
    case .denied:
        throw Failure("""
            Permission denied. Allow your terminal in:
            System Settings › Privacy & Security › Screen & System Audio Recording
            (section “System Audio Recording Only”), then restart the terminal.
            """)
    case .notAsked:
        guard AudioCapturePermission.request() else { throw Failure("Audio recording permission denied.") }
    default: break
    }

    let output = availableURL(options.output ?? defaultOutput(app: options.app))
    // Vérifier avant d'enregistrer, pas après tout un morceau.
    if needsFFmpeg(output), !ffmpegInstalled() {
        throw Failure("""
            .\(output.pathExtension) export needs ffmpeg, and it isn't installed.
              Install it:  brew install ffmpeg   (Homebrew: https://brew.sh)
              Or record to .m4a, .flac or .wav, which need nothing.
            """)
    }
    let capture = Capture(settings: CaptureSettings(
        sourceID: options.app,
        output: output,
        mute: options.mute,
        silenceStop: options.auto ? options.silence : nil,
        maxDuration: options.duration))

    let stopHint = options.auto
        ? "  (auto stop after \(String(format: "%g", options.silence)) s of silence, or Ctrl-C)"
        : "  (Ctrl-C to stop)"
    var waitingSince: Date?
    var hintShown = false
    var recording = false

    // Répète la ligne d'attente et affiche un rappel si rien n'arrive.
    let waitTimer = DispatchSource.makeTimerSource(queue: .main)
    waitTimer.schedule(deadline: .now(), repeating: .milliseconds(200))
    waitTimer.setEventHandler {
        guard let since = waitingSince, !recording else { return }
        paint("⏳ Waiting for sound…\(stopHint)")
        if !hintShown, Date().timeIntervalSince(since) > 10 {
            hintShown = true
            clearLine()
            log("  (still nothing… if sound is really playing, check the permission: see README)")
        }
    }

    capture.onLevel = { peak, seconds in
        paint("● REC \(formatTime(seconds))  \(meter(peak))\(stopHint)")
    }
    capture.onState = { state in
        switch state {
        case .waitingForApp(let name):
            log("Waiting for “\(name)” to play sound… (Ctrl-C to cancel)")
        case .waitingForSound:
            log("Source: \(options.app ?? "all Mac audio")")
            waitingSince = Date()
            waitTimer.resume()
        case .recording:
            recording = true
            if !isTTY { log("● Recording…") }
        case .exporting:
            clearLine()
            log("Converting to \(output.pathExtension)…")
        case .finished(let recording):
            log("✅ \(recording.url.path)  (\(formatTime(recording.duration)))")
            exit(0)
        case .cancelled:
            clearLine()
            log("Cancelled.")
            exit(130)
        case .failed(let error):
            clearLine()
            log("Error: \(error.localizedDescription)")
            if FileManager.default.fileExists(atPath: capture.rawURL.path) {
                log("Raw recording kept: \(capture.rawURL.path)")
            }
            exit(1)
        }
    }

    capture.start()

    // Sur sa propre file : un 2e Ctrl-C doit quitter même si le thread principal est occupé.
    var interrupts = 0
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue(label: "sillio.signals"))
    sigint.setEventHandler {
        // `data` = nombre de SIGINT reçus : deux Ctrl-C rapprochés arrivent en un seul événement.
        interrupts += max(1, Int(sigint.data))
        guard interrupts < 2 else {
            if FileManager.default.fileExists(atPath: capture.rawURL.path) {
                log("\nInterrupted. Raw recording: \(capture.rawURL.path)")
            }
            exit(130)
        }
        capture.stop()
    }
    sigint.resume()
    dispatchMain()
} catch {
    log("Error: \(error.localizedDescription)")
    exit(1)
}

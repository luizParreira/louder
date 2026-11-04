import CoreAudio
import Foundation
import LouderEngine

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(code)
}

let usage = """
usage: louder-cli [--boost dB] [--device NAME] [--list]
       louder-cli --selftest [--seconds N] [--hold] [--public-tap]

  --boost dB    extra loudness in dB (default 3); capped at +6 on headphones, +12 on speakers
  --device NAME output device (substring match); default follows the system output
  --list        list output devices and their safety profile
  --selftest    start the engine with the original audio unmuted and Louder's output silent,
                wait for audio to flow (up to 10 s), run --seconds more, stop, report. Inaudible.

While boosting: type + or - then Return (1 dB steps), q then Return or Ctrl-C to quit.
"""

var boost: Float = 3
var deviceQuery: String?
var selftest = false
var seconds = 3.0
var hold = false
var publicTap = false
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--boost", "-b":
        guard let v = args.popFirst().flatMap(Float.init), v >= 0 else { fail("--boost needs a dB value >= 0") }
        boost = v
    case "--device", "-d": deviceQuery = args.popFirst()
    case "--list", "-l":
        for d in OutputDevice.all() {
            print("\(d.name)  [\(d.kind.rawValue), max +\(Int(d.profile.maxBoostDB)) dB]")
        }
        exit(0)
    case "--selftest": selftest = true
    case "--seconds":
        guard let v = args.popFirst().flatMap(Double.init), v > 0 else { fail("--seconds needs a positive number") }
        seconds = v
    case "--hold": hold = true
    case "--public-tap": publicTap = true
    case "-h", "--help": print(usage); exit(0)
    default: print(usage); exit(1)
    }
}

var deviceUID: String?
if let q = deviceQuery?.lowercased() {
    guard let match = OutputDevice.all().first(where: { $0.name.lowercased().contains(q) }) else {
        fail("no output device matching '\(q)' (try --list)")
    }
    deviceUID = match.uid
}

let options = selftest
    ? BoostEngine.Options(muteOriginal: false, silentOutput: true, requestPermission: false, publicTap: publicTap)
    : BoostEngine.Options()
let engine = BoostEngine(boostDB: boost, preferredDeviceUID: deviceUID, options: options)
engine.onEvent = { print("louder: \($0)") }

@MainActor func finish(_ message: String, code: Int32 = 0) -> Never {
    alarm(2)
    let started = Date()
    engine.stop()
    print(message + String(format: " (stopped in %.0f ms)", Date().timeIntervalSince(started) * 1000))
    exit(code)
}

var keepAlive: [any DispatchSourceProtocol] = []
let signalQueue = DispatchQueue(label: "louder.signals")
nonisolated(unsafe) var signalsReceived = 0
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
    source.setEventHandler {
        signalsReceived += 1
        if signalsReceived > 1 { _exit(130) }
        alarm(2)
        DispatchQueue.main.async { MainActor.assumeIsolated { () -> Void in finish("\nStopped. Normal audio restored.") } }
    }
    source.resume()
    keepAlive.append(source)
}

engine.start()

@MainActor func describe(_ state: BoostEngine.State) -> String {
    switch state {
    case .off: "off"
    case .starting: "starting"
    case .running: "running"
    case .needsPermission: "needs System Audio Recording permission"
    case .failed(let message): "failed: \(message)"
    }
}

if selftest {
    let startedAt = Date()
    var audioStartedAt: Date?
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
    timer.setEventHandler {
        MainActor.assumeIsolated {
            if case .failed = engine.state { finish("selftest FAILED: \(describe(engine.state))", code: 2) }
            if audioStartedAt == nil, engine.meters.dataCycles > 0 { audioStartedAt = Date() }
            if hold { return }
            if let audioStartedAt, Date().timeIntervalSince(audioStartedAt) < seconds { return }
            if audioStartedAt == nil, Date().timeIntervalSince(startedAt) < seconds + 10 { return }
            let device = engine.device.map { "\($0.name) [\($0.kind.rawValue)]" } ?? "none"
            let ok = engine.state == .running && engine.meters.dataCycles > 10
            print("""
            device: \(device)
            state: \(describe(engine.state))
            audio cycles: \(engine.meters.dataCycles) of \(engine.meters.ioCycles)
            input level: \(String(format: "%.1f", engine.meters.inputLevelDB)) dBFS
            """)
            finish(ok ? "selftest PASSED" : "selftest FAILED", code: ok ? 0 : 2)
        }
    }
    timer.resume()
    keepAlive.append(timer)
} else {
    if case .failed = engine.state { fail(describe(engine.state)) }
    if engine.state == .needsPermission {
        fail("Louder needs System Audio Recording permission. Enable your terminal in System Settings > Privacy & Security > Screen & System Audio Recording.")
    }
    let device = engine.device.map { "\($0.name) (\($0.kind.rawValue), max +\(Int($0.profile.maxBoostDB)) dB)" } ?? "?"
    print("Louder: boosting \(device), target +\(engine.effectiveBoostDB) dB. Fading in…")
    print("Type + or - then Return to change, q then Return to quit.")

    let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
    input.setEventHandler {
        MainActor.assumeIsolated {
            guard let line = readLine() else { input.cancel(); return }
            for c in line {
                switch c {
                case "+": engine.setBoost(min(engine.maxBoostDB, engine.boostDB + 1))
                case "-": engine.setBoost(max(0, engine.boostDB - 1))
                case "q": finish("Stopped. Normal audio restored.")
                default: break
                }
            }
            print("target +\(Int(engine.effectiveBoostDB)) dB")
        }
    }
    input.resume()
    keepAlive.append(input)

    let status = DispatchSource.makeTimerSource(queue: .main)
    status.schedule(deadline: .now() + 2, repeating: 2)
    status.setEventHandler {
        MainActor.assumeIsolated {
            if engine.state != .running && engine.state != .starting {
                finish("Louder stopped: \(describe(engine.state))", code: 3)
            }
            let m = engine.meters
            print(String(format: "boost +%.1f dB (target +%.0f) | input %.0f dBFS | limiter -%.1f dB",
                         m.appliedBoostDB, engine.effectiveBoostDB, m.inputLevelDB, m.limiterReductionDB))
        }
    }
    status.resume()
    keepAlive.append(status)
}

CFRunLoopRun()

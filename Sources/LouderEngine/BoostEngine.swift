import AudioToolbox
import CoreAudio
import Foundation
import Observation
import Synchronization

/// Values shared between the audio I/O thread and the main thread, all lock-free.
final class SharedState: Sendable {
    private let targetBits = Atomic<UInt32>(0)
    private let appliedBits = Atomic<UInt32>(0)
    private let inputBits = Atomic<UInt32>((-120 as Float).bitPattern)
    private let limiterBits = Atomic<UInt32>(0)
    let ioCycles = Atomic<UInt64>(0)
    /// Callbacks that actually received tap audio. The stall watchdog uses this, not `ioCycles`.
    let dataCycles = Atomic<UInt64>(0)
    let feedbackTripped = Atomic<Bool>(false)

    var targetBoostDB: Float {
        get { Float(bitPattern: targetBits.load(ordering: .relaxed)) }
        set { targetBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    var appliedBoostDB: Float { Float(bitPattern: appliedBits.load(ordering: .relaxed)) }
    var inputLevelDB: Float { Float(bitPattern: inputBits.load(ordering: .relaxed)) }
    var limiterReductionDB: Float { Float(bitPattern: limiterBits.load(ordering: .relaxed)) }

    func publish(_ processor: BoostProcessor, hadData: Bool) {
        if hadData { dataCycles.wrappingAdd(1, ordering: .relaxed) }
        appliedBits.store(processor.appliedBoostDB.bitPattern, ordering: .relaxed)
        inputBits.store(processor.inputLevelDB.bitPattern, ordering: .relaxed)
        limiterBits.store(processor.limiterReductionDB.bitPattern, ordering: .relaxed)
        if processor.feedbackTripped { feedbackTripped.store(true, ordering: .relaxed) }
        ioCycles.wrappingAdd(1, ordering: .relaxed)
    }

    func reset() {
        appliedBits.store(0, ordering: .relaxed)
        inputBits.store((-120 as Float).bitPattern, ordering: .relaxed)
        limiterBits.store(0, ordering: .relaxed)
        feedbackTripped.store(false, ordering: .relaxed)
    }
}

/// Everything the I/O callback touches. Allocated once per session; the callback never allocates.
final class RenderContext: @unchecked Sendable {
    let processor: BoostProcessor
    let shared: SharedState
    let channels: Int
    let skipInputChannels: Int
    let silentOutput: Bool
    let capacity = 16384
    let scratch: UnsafeMutablePointer<Float>

    init(processor: BoostProcessor, shared: SharedState, channels: Int, skipInputChannels: Int, silentOutput: Bool) {
        self.processor = processor
        self.shared = shared
        self.channels = channels
        self.skipInputChannels = skipInputChannels
        self.silentOutput = silentOutput
        scratch = .allocate(capacity: capacity * channels)
        scratch.initialize(repeating: 0, count: capacity * channels)
    }

    deinit { scratch.deallocate() }

    /// Runs one empty cycle so Swift's lazy type-metadata lookups happen here, not on the
    /// real-time audio thread.
    func prime() {
        var input = AudioBufferList()
        var output = AudioBufferList()
        render(&input, &output)
    }

    func render(_ inputList: UnsafePointer<AudioBufferList>, _ outputList: UnsafeMutablePointer<AudioBufferList>) {
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputList))
        var frames = capacity
        var tapChannelsFound = 0
        var channel = 0
        for buffer in input {
            let n = Int(buffer.mNumberChannels)
            if n > 0, channel + n > skipInputChannels, buffer.mData != nil {
                frames = min(frames, Int(buffer.mDataByteSize) / (4 * n))
                tapChannelsFound += min(n, channel + n - skipInputChannels)
            }
            channel += n
        }
        if tapChannelsFound < channels { frames = 0 }

        channel = 0
        for buffer in input {
            let n = Int(buffer.mNumberChannels)
            if n > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                for k in 0..<n {
                    let tapChannel = channel + k - skipInputChannels
                    guard tapChannel >= 0, tapChannel < channels else { continue }
                    for f in 0..<frames { scratch[f * channels + tapChannel] = data[f * n + k] }
                }
            }
            channel += n
        }

        processor.process(scratch, frames: frames, channels: channels, targetBoostDB: shared.targetBoostDB)

        let output = UnsafeMutableAudioBufferListPointer(outputList)
        let audible = !silentOutput && !processor.feedbackTripped
        var outChannel = 0
        for buffer in output {
            let n = Int(buffer.mNumberChannels)
            guard n > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let outFrames = Int(buffer.mDataByteSize) / (4 * n)
            for k in 0..<n {
                let global = outChannel + k
                let source = channels == 1 && global < 2 ? 0 : global
                let copied = audible && source < channels ? min(frames, outFrames) : 0
                for f in 0..<copied { data[f * n + k] = scratch[f * channels + source] }
                for f in copied..<outFrames { data[f * n + k] = 0 }
            }
            outChannel += n
        }
        shared.publish(processor, hadData: frames > 0)
    }
}

/// Boosts everything playing on an output device, with hearing protection.
///
/// Safety model: the original audio is muted only while Louder's tap exists. Any failure,
/// device change, stall or detected feedback tears the tap down first, so the system falls
/// back to normal, unboosted audio. If the process dies, macOS removes the private tap.
@MainActor
@Observable
public final class BoostEngine {
    public struct Options: Sendable {
        /// Mute the original audio while boosting. Only self-tests turn this off.
        public var muteOriginal: Bool
        /// Write silence instead of the boosted signal. Only self-tests turn this on.
        public var silentOutput: Bool
        /// Ask for the System Audio Recording permission before starting.
        public var requestPermission: Bool
        /// Make the tap and aggregate visible to other processes. Only self-tests turn this on.
        public var publicTap: Bool

        public init(muteOriginal: Bool = true, silentOutput: Bool = false, requestPermission: Bool = true, publicTap: Bool = false) {
            self.muteOriginal = muteOriginal
            self.silentOutput = silentOutput
            self.requestPermission = requestPermission
            self.publicTap = publicTap
        }
    }

    public enum State: Equatable, Sendable {
        case off
        case starting
        case running
        case needsPermission
        case failed(String)
    }

    public struct Meters: Equatable, Sendable {
        public var appliedBoostDB: Float = 0
        public var inputLevelDB: Float = -120
        public var limiterReductionDB: Float = 0
        public var ioCycles: UInt64 = 0
        /// Audio callbacks that delivered captured audio.
        public var dataCycles: UInt64 = 0
    }

    public private(set) var state: State = .off
    /// The device being boosted (or that will be boosted on start).
    public private(set) var device: OutputDevice?
    public private(set) var meters = Meters()
    /// Requested boost in dB. The engine applies at most `maxBoostDB` for the current device.
    public private(set) var boostDB: Float
    /// Fixed output device UID, or nil to follow the system default output.
    public private(set) var preferredDeviceUID: String?

    public var maxBoostDB: Float { device?.profile.maxBoostDB ?? SafetyProfile.headphones.maxBoostDB }
    public var effectiveBoostDB: Float { min(boostDB, maxBoostDB) }
    public var isRunning: Bool { state == .running }

    /// Called on the main thread for notable events (restarts, safety stops). Useful for logging.
    @ObservationIgnored public var onEvent: ((String) -> Void)?

    @ObservationIgnored public let options: Options
    @ObservationIgnored private let shared = SharedState()
    @ObservationIgnored private var tapID = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var procID: AudioDeviceIOProcID?
    @ObservationIgnored private var renderContext: RenderContext?
    @ObservationIgnored private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    @ObservationIgnored private var watchdog: DispatchSourceTimer?
    @ObservationIgnored private var pendingRestart: DispatchWorkItem?
    @ObservationIgnored private var lastDataCycles: UInt64 = 0
    @ObservationIgnored private var lastPermissionCheck = Date.distantPast
    /// Bumped by every start/stop/restart so stale permission callbacks and scheduled restarts
    /// can't build a second session on top of the current one.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lockDescriptor: Int32 = -1
    @ObservationIgnored private var stalledSince: Date?
    @ObservationIgnored private var sessionHasAudio = false
    @ObservationIgnored private var recentRestarts: [Date] = []
    @ObservationIgnored private var wantsRunning = false

    public init(boostDB: Float = 3, preferredDeviceUID: String? = nil, options: Options = Options()) {
        self.boostDB = 0
        self.preferredDeviceUID = preferredDeviceUID
        self.options = options
        setBoost(boostDB)
        device = resolveDevice()
    }

    // MARK: Public controls

    public func setBoost(_ db: Float) {
        boostDB = db.isFinite ? min(max(db, 0), SafetyProfile.speakers.maxBoostDB) : 0
        shared.targetBoostDB = boostDB
    }

    /// nil follows the system default output device.
    public func setPreferredDevice(uid: String?) {
        preferredDeviceUID = uid
        if wantsRunning { restart(reason: "Output device changed", userInitiated: true) } else { device = resolveDevice() }
    }

    public func start() {
        guard !wantsRunning else { return }
        wantsRunning = true
        generation += 1
        recentRestarts.removeAll()
        beginSession(checkPermission: options.requestPermission)
    }

    public func stop() {
        wantsRunning = false
        generation += 1
        pendingRestart?.cancel()
        pendingRestart = nil
        teardown()
        state = .off
    }

    public static var permissionStatus: AudioCapturePermission.Status { AudioCapturePermission.status }

    // MARK: Session lifecycle

    private func beginSession(checkPermission: Bool) {
        guard wantsRunning else { return }
        if checkPermission {
            switch AudioCapturePermission.status {
            case .denied:
                wantsRunning = false
                teardown()
                state = .needsPermission
                return
            case .unknown:
                teardown()
                state = .starting
                let requestGeneration = generation
                AudioCapturePermission.request { granted in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard self.wantsRunning, self.generation == requestGeneration else { return }
                            if granted {
                                self.beginSession(checkPermission: false)
                            } else {
                                self.wantsRunning = false
                                self.teardown()
                                self.state = .needsPermission
                            }
                        }
                    }
                }
                return
            case .authorized:
                break
            }
        }
        state = .starting
        do {
            try build()
            state = .running
        } catch {
            teardown()
            wantsRunning = false
            state = .failed(String(describing: error))
            onEvent?("Could not start: \(error)")
        }
    }

    /// A chosen device that isn't connected resolves to nil: Louder never silently moves the
    /// boost to a different device than the one the user picked.
    private func resolveDevice() -> OutputDevice? {
        if let uid = preferredDeviceUID {
            return OutputDevice.all().first(where: { $0.uid == uid })
        }
        return OutputDevice.systemDefault()
    }

    private func build() throws {
        teardown()
        let resolved = resolveDevice()
        device = resolved
        guard let device = resolved else {
            throw LouderError(preferredDeviceUID == nil
                ? "No output device is available."
                : "The output device you picked isn't connected. Pick another device or Follow system output.")
        }
        try acquireLock()
        guard let ownProcess = HAL.ownProcessObject() else {
            throw LouderError("Couldn't identify Louder's own audio process, so it can't safely exclude itself. Not starting (feedback risk).")
        }

        let tap = CATapDescription(excludingProcesses: [ownProcess], deviceUID: device.uid, stream: 0)
        tap.name = "Louder"
        tap.isPrivate = !options.publicTap
        tap.muteBehavior = options.muteOriginal ? .mutedWhenTapped : .unmuted
        try HAL.check(AudioHardwareCreateProcessTap(tap, &tapID), "to create the audio tap")

        guard let format: AudioStreamBasicDescription = HAL.value(tapID, kAudioTapPropertyFormat),
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32,
              format.mChannelsPerFrame > 0 else {
            throw LouderError("The output device uses an audio format Louder doesn't support.")
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Louder",
            kAudioAggregateDeviceUIDKey: "\(OutputDevice.louderUIDPrefix)\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceIsPrivateKey: !options.publicTap,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tap.uuid.uuidString,
            ]],
        ]
        try HAL.check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID), "to create the aggregate device")

        let tapChannels = Int(format.mChannelsPerFrame)
        let deviceInputChannels = HAL.channelCount(device.id, scope: kAudioObjectPropertyScopeInput)
        let aggregateInputChannels = HAL.channelCount(aggregateID, scope: kAudioObjectPropertyScopeInput)
        guard aggregateInputChannels == deviceInputChannels + tapChannels else {
            throw LouderError("Unexpected audio channel layout (\(aggregateInputChannels) inputs, expected \(deviceInputChannels)+\(tapChannels)). Not starting.")
        }

        shared.reset()
        shared.targetBoostDB = boostDB
        let context = RenderContext(
            processor: BoostProcessor(sampleRate: Float(format.mSampleRate), profile: device.profile),
            shared: shared,
            channels: tapChannels,
            skipInputChannels: deviceInputChannels,
            silentOutput: options.silentOutput
        )
        renderContext = context
        context.prime()
        try HAL.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, Self.ioBlock(context)), "to create the audio callback")
        try HAL.check(AudioDeviceStart(aggregateID, procID), "to start audio")

        installListeners(for: device)
        startWatchdog()
    }

    /// Built outside the main actor: a closure formed in a @MainActor method inherits that
    /// isolation and traps when Core Audio calls it on its real-time thread.
    private nonisolated static func ioBlock(_ context: RenderContext) -> AudioDeviceIOBlock {
        { @Sendable _, input, _, output, _ in context.render(input, output) }
    }

    /// Releases everything in fail-open order: once the tap is gone, normal audio plays again.
    private func teardown() {
        watchdog?.cancel()
        watchdog = nil
        removeListeners()
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        renderContext = nil
        releaseLock()
        if meters != Meters() { meters = Meters() }
    }

    /// One boosting session per user across the app and the CLI; two would tap each other.
    private func acquireLock() throws {
        guard lockDescriptor < 0 else { return }
        let path = "/tmp/io.github.luizparreira.Louder.\(getuid()).lock"
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw LouderError("Couldn't create the lock file at \(path).") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw LouderError("Another copy of Louder (the app or louder-cli) is already boosting. Quit it first.")
        }
        lockDescriptor = fd
    }

    private func releaseLock() {
        guard lockDescriptor >= 0 else { return }
        flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
        lockDescriptor = -1
    }

    private func restart(reason: String, userInitiated: Bool = false) {
        teardown()
        generation += 1
        onEvent?("\(reason). Restarting.")
        let now = Date()
        recentRestarts = recentRestarts.filter { now.timeIntervalSince($0) < 30 }
        if !userInitiated { recentRestarts.append(now) }
        if recentRestarts.count > 5 {
            wantsRunning = false
            state = .failed("\(reason). Louder stopped after repeated restarts; normal audio is playing.")
            return
        }
        state = .starting
        pendingRestart?.cancel()
        let restartGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.wantsRunning, self.generation == restartGeneration else { return }
                self.beginSession(checkPermission: self.options.requestPermission)
            }
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func safetyStop(_ message: String, state newState: State? = nil) {
        wantsRunning = false
        generation += 1
        pendingRestart?.cancel()
        teardown()
        state = newState ?? .failed(message)
        onEvent?(message)
    }

    // MARK: Monitoring

    private func installListeners(for device: OutputDevice) {
        var watched: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope, String)] = [
            (HAL.system, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, "Audio devices changed"),
            (device.id, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, "Output device disconnected"),
            (device.id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, "Output sample rate changed"),
            (device.id, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput, "Output source changed"),
            (device.id, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput, "Output channels changed"),
        ]
        if preferredDeviceUID == nil {
            watched.append((HAL.system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, "Default output changed"))
        }
        let deviceUID = device.uid
        for (object, selector, scope, reason) in watched {
            var addr = HAL.address(selector, scope)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, self.wantsRunning, self.procID != nil else { return }
                    if selector == kAudioHardwarePropertyDevices,
                       OutputDevice.all().contains(where: { $0.uid == deviceUID }) {
                        return
                    }
                    self.restart(reason: reason)
                }
            }
            if AudioObjectAddPropertyListenerBlock(object, &addr, DispatchQueue.main, block) == noErr {
                listeners.append((object, addr, block))
            }
        }
    }

    private func removeListeners() {
        for (object, address, block) in listeners {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(object, &addr, DispatchQueue.main, block)
        }
        listeners.removeAll()
    }

    private func startWatchdog() {
        lastDataCycles = shared.dataCycles.load(ordering: .relaxed)
        lastPermissionCheck = Date()
        stalledSince = nil
        sessionHasAudio = false
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.resume()
        watchdog = timer
    }

    private func tick() {
        guard procID != nil else { return }
        if shared.feedbackTripped.load(ordering: .relaxed) {
            safetyStop("Feedback detected. Louder turned itself off; normal audio is playing.")
            return
        }
        if options.requestPermission, Date().timeIntervalSince(lastPermissionCheck) > 2 {
            lastPermissionCheck = Date()
            if AudioCapturePermission.status == .denied {
                safetyStop("System Audio Recording permission was turned off.", state: .needsPermission)
                return
            }
        }
        let dataCycles = shared.dataCycles.load(ordering: .relaxed)
        if dataCycles == lastDataCycles {
            let since = stalledSince ?? Date()
            stalledSince = since
            let limit: TimeInterval = sessionHasAudio ? 1.5 : 5
            if Date().timeIntervalSince(since) > limit {
                restart(reason: sessionHasAudio ? "Audio stopped flowing" : "Audio didn't start")
                return
            }
        } else {
            stalledSince = nil
            sessionHasAudio = true
        }
        lastDataCycles = dataCycles
        let cycles = shared.ioCycles.load(ordering: .relaxed)
        let updated = Meters(
            appliedBoostDB: shared.appliedBoostDB,
            inputLevelDB: shared.inputLevelDB,
            limiterReductionDB: shared.limiterReductionDB,
            ioCycles: cycles,
            dataCycles: dataCycles
        )
        if updated != meters { meters = updated }
    }
}

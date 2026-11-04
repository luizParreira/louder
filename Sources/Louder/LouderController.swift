import CoreAudio
import Foundation
import LouderEngine
import Observation
import ServiceManagement
import os

@MainActor
@Observable
final class LouderController {
    let engine: BoostEngine
    private(set) var devices: [OutputDevice] = []
    private(set) var loginItemStatus: SMAppService.Status = .notRegistered
    private(set) var loginItemError: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var resumeAfterWake = false
    @ObservationIgnored private var wakeTask: Task<Void, Never>?

    private enum Key {
        static let boostDB = "boostDB"
        static let deviceUID = "deviceUID"
        static let wasEnabled = "wasEnabled"
        static let sessionActive = "sessionActive"
    }

    init(defaults: UserDefaults = .standard) {
        defaults.register(defaults: [Key.boostDB: Float(3)])
        self.defaults = defaults
        engine = BoostEngine(
            boostDB: defaults.float(forKey: Key.boostDB),
            preferredDeviceUID: defaults.string(forKey: Key.deviceUID)
        )
        let log = Logger(subsystem: "io.github.luizparreira.Louder", category: "engine")
        engine.onEvent = { message in log.notice("\(message, privacy: .public)") }
        devices = OutputDevice.all()
        loginItemStatus = SMAppService.mainApp.status
        watchOutputDevices()
        watchEngineState()
    }

    var isOn: Bool { engine.state == .running || engine.state == .starting }

    var launchesAtLogin: Bool { loginItemStatus == .enabled || loginItemStatus == .requiresApproval }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.wasEnabled)
        if enabled { startEngine() } else { stopEngine() }
    }

    func setBoost(_ db: Float) {
        engine.setBoost(db.rounded())
        defaults.set(engine.boostDB, forKey: Key.boostDB)
    }

    func selectDevice(uid: String?) {
        guard uid != engine.preferredDeviceUID else { return }
        defaults.set(uid, forKey: Key.deviceUID)
        engine.setPreferredDevice(uid: uid)
    }

    /// A run that ended while Louder was on without a normal quit (crash, force quit,
    /// `pkill -9 Louder`) leaves `sessionActive` set; the next launch then stays off.
    func restoreOnLaunch() {
        if defaults.bool(forKey: Key.sessionActive) {
            defaults.set(false, forKey: Key.sessionActive)
            defaults.set(false, forKey: Key.wasEnabled)
            return
        }
        if defaults.bool(forKey: Key.wasEnabled) { startEngine() }
    }

    func shutdown() {
        wakeTask?.cancel()
        wakeTask = nil
        stopEngine()
    }

    func systemWillSleep() {
        resumeAfterWake = isOn || wakeTask != nil
        wakeTask?.cancel()
        wakeTask = nil
        if isOn { stopEngine() }
    }

    func systemDidWake() {
        guard resumeAfterWake else { return }
        resumeAfterWake = false
        wakeTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            wakeTask = nil
            if defaults.bool(forKey: Key.wasEnabled) { startEngine() }
        }
    }

    private func startEngine() {
        defaults.set(true, forKey: Key.sessionActive)
        engine.start()
    }

    private func stopEngine() {
        engine.stop()
        defaults.set(false, forKey: Key.sessionActive)
    }

    func refreshLoginItem() {
        loginItemStatus = SMAppService.mainApp.status
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        refreshLoginItem()
    }

    /// The engine only watches devices while it runs, so the app keeps the picker and the
    /// resolved device (and with it the boost cap) current while Louder is off.
    private func watchOutputDevices() {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.outputDevicesChanged() }
            }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }

    private func outputDevicesChanged() {
        let current = OutputDevice.all()
        if current != devices { devices = current }
        if !isOn { engine.setPreferredDevice(uid: engine.preferredDeviceUID) }
    }

    /// When the engine turns itself off (safety stop, failure, missing permission), the next
    /// launch should not switch it back on by itself.
    private func watchEngineState() {
        withObservationTracking {
            _ = engine.state
        } onChange: { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.engineStateChanged()
                self.watchEngineState()
            }
        }
    }

    private func engineStateChanged() {
        switch engine.state {
        case .needsPermission, .failed:
            defaults.set(false, forKey: Key.wasEnabled)
        case .off, .starting, .running:
            break
        }
    }
}

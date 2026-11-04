import Foundation
import LouderEngine

/// Turns the engine's 10 Hz meters into a steady, human description of what the boost is doing.
struct BoostActivity {
    enum Phase: Equatable {
        case waiting
        case easingIn
        case boosting
        case holdingBack
    }

    private(set) var phase: Phase = .waiting
    private var lastApplied: Float = 0
    private var lastUpdate: Date?
    private var gapSince: Date?

    static let silenceDBFS: Float = -70
    static let holdBackDelay: TimeInterval = 1

    mutating func update(target: Float, meters: BoostEngine.Meters, now: Date = .now) {
        let applied = meters.appliedBoostDB
        defer {
            lastApplied = applied
            lastUpdate = now
        }
        guard meters.inputLevelDB > Self.silenceDBFS else {
            phase = .waiting
            gapSince = nil
            return
        }
        guard target - applied > 1 else {
            phase = .boosting
            gapSince = nil
            return
        }
        let since = gapSince ?? now
        gapSince = since
        let elapsed = lastUpdate.map { now.timeIntervalSince($0) } ?? 0
        let rising = elapsed > 0 && Double(applied - lastApplied) / elapsed > 1
        if rising {
            phase = .easingIn
        } else if now.timeIntervalSince(since) >= Self.holdBackDelay {
            phase = .holdingBack
        }
    }

    mutating func reset() {
        self = BoostActivity()
    }

    mutating func targetChanged() {
        gapSince = nil
    }
}

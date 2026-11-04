import Foundation

public enum OutputKind: String, Sendable, Codable {
    case headphones
    case speakers
}

/// Hearing-safety limits applied to every sample, chosen by the kind of output device.
public struct SafetyProfile: Sendable, Equatable {
    public var kind: OutputKind
    /// Largest boost the user can ask for.
    public var maxBoostDB: Float
    /// Boost is reduced so the input's short-term RMS plus boost never exceeds this level.
    /// Quiet material gets the full boost; material that is already loud gets little or none.
    public var loudnessCeilingDBFS: Float
    /// Hard ceiling for every output sample.
    public var peakCeilingDBFS: Float

    public static let headphones = SafetyProfile(kind: .headphones, maxBoostDB: 6, loudnessCeilingDBFS: -14, peakCeilingDBFS: -1)
    public static let speakers = SafetyProfile(kind: .speakers, maxBoostDB: 12, loudnessCeilingDBFS: -10, peakCeilingDBFS: -1)

    public static func `for`(_ kind: OutputKind) -> SafetyProfile {
        kind == .headphones ? .headphones : .speakers
    }
}

@inline(__always) func dbToGain(_ db: Float) -> Float { powf(10, db / 20) }

/// Real-time gain stage: ramped boost, loudness guard, stereo-linked peak limiter and a
/// feedback detector. Runs on the audio I/O thread; it never allocates or locks.
public final class BoostProcessor: @unchecked Sendable {
    public static let rampUpDBPerSecond: Float = 3
    /// Sustained input this loud means we are hearing our own output (runaway feedback).
    public static let feedbackThresholdDBFS: Float = -4
    public static let feedbackHoldSeconds: Float = 0.3

    static let levelSmoothingSeconds: Float = 0.03
    static let levelAttackSeconds: Float = 0.05
    static let levelReleaseSeconds: Float = 1.0
    static let fastAttackSeconds: Float = 0.005
    /// Below this input level the boost holds instead of ramping up, so sound that starts
    /// after a pause is never hit by a boost that grew during the silence.
    static let silenceDBFS: Float = -60
    static let maxMeanSquare: Float = 1e4
    static let limiterReleaseSeconds: Float = 0.08
    static let controlFrames = 32

    public let sampleRate: Float
    public let profile: SafetyProfile

    public private(set) var appliedBoostDB: Float = 0
    public private(set) var inputLevelDB: Float = -120
    public private(set) var limiterReductionDB: Float = 0
    public private(set) var feedbackTripped = false

    private var smoothedMeanSquare: Float = 0
    private var meanSquare: Float = 0
    private var fastSmoothedMeanSquare: Float = 0
    private var fastMeanSquare: Float = 0
    private var limiterGain: Float = 1
    private var feedbackSeconds: Float = 0
    private let peakCeiling: Float
    private let limiterReleaseCoefficient: Float

    public init(sampleRate: Float, profile: SafetyProfile) {
        self.sampleRate = max(sampleRate, 8000)
        self.profile = profile
        peakCeiling = dbToGain(min(profile.peakCeilingDBFS, 0))
        limiterReleaseCoefficient = 1 - expf(-1 / (Self.limiterReleaseSeconds * self.sampleRate))
    }

    /// Processes interleaved Float32 samples in place.
    public func process(_ samples: UnsafeMutablePointer<Float>, frames: Int, channels: Int, targetBoostDB: Float) {
        guard frames > 0, channels > 0 else { return }
        if feedbackTripped {
            samples.update(repeating: 0, count: frames * channels)
            return
        }
        let target = targetBoostDB.isFinite ? min(max(targetBoostDB, 0), profile.maxBoostDB) : 0
        var lowestLimiterGain: Float = 1
        var start = 0

        while start < frames {
            let count = min(Self.controlFrames, frames - start)
            let block = samples + start * channels
            let dt = Float(count) / sampleRate

            var sumOfSquares: Float = 0
            for i in 0..<(count * channels) {
                let x = block[i]
                if x.isFinite {
                    sumOfSquares += x * x
                } else {
                    block[i] = 0
                }
            }
            let blockMeanSquare = min(sumOfSquares / Float(count * channels), Self.maxMeanSquare)
            smoothedMeanSquare += (1 - expf(-dt / Self.levelSmoothingSeconds)) * (blockMeanSquare - smoothedMeanSquare)
            let tau = smoothedMeanSquare > meanSquare ? Self.levelAttackSeconds : Self.levelReleaseSeconds
            meanSquare += (1 - expf(-dt / tau)) * (smoothedMeanSquare - meanSquare)
            fastSmoothedMeanSquare += (1 - expf(-dt / Self.fastAttackSeconds)) * (blockMeanSquare - fastSmoothedMeanSquare)
            let fastTau = fastSmoothedMeanSquare > fastMeanSquare ? Self.fastAttackSeconds : Self.levelReleaseSeconds
            fastMeanSquare += (1 - expf(-dt / fastTau)) * (fastSmoothedMeanSquare - fastMeanSquare)
            let sustainedLevelDB = 10 * log10f(max(meanSquare, 1e-12))
            inputLevelDB = 10 * log10f(max(meanSquare, fastMeanSquare, 1e-12))

            if sustainedLevelDB > Self.feedbackThresholdDBFS {
                feedbackSeconds += dt
                if feedbackSeconds >= Self.feedbackHoldSeconds {
                    feedbackTripped = true
                    appliedBoostDB = 0
                    block.update(repeating: 0, count: (frames - start) * channels)
                    limiterReductionDB = 0
                    return
                }
            } else {
                feedbackSeconds = 0
            }

            let allowed = max(0, profile.loudnessCeilingDBFS - inputLevelDB)
            let desired = min(target, allowed)
            let previous = appliedBoostDB
            if desired < appliedBoostDB {
                appliedBoostDB = desired
            } else if inputLevelDB > Self.silenceDBFS {
                appliedBoostDB = min(desired, appliedBoostDB + Self.rampUpDBPerSecond * dt)
            }

            let startGain = dbToGain(previous)
            let gainStep = (dbToGain(appliedBoostDB) - startGain) / Float(count)
            for f in 0..<count {
                let gain = startGain + gainStep * Float(f + 1)
                let frame = block + f * channels
                var peak: Float = 0
                for c in 0..<channels { peak = max(peak, abs(frame[c]) * gain) }
                let needed = peak > peakCeiling ? peakCeiling / peak : 1
                limiterGain = min(needed, limiterGain + (1 - limiterGain) * limiterReleaseCoefficient)
                lowestLimiterGain = min(lowestLimiterGain, limiterGain)
                let total = gain * limiterGain
                for c in 0..<channels {
                    frame[c] = min(max(frame[c] * total, -peakCeiling), peakCeiling)
                }
            }
            start += count
        }
        limiterReductionDB = -20 * log10f(lowestLimiterGain)
    }
}

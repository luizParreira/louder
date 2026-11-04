import Foundation
import Testing
@testable import LouderEngine

private let sampleRate: Float = 48_000

private func sine(seconds: Float, amplitude: Float, frequency: Float = 440, channels: Int = 2) -> [Float] {
    let frames = Int(seconds * sampleRate)
    var out = [Float](repeating: 0, count: frames * channels)
    for f in 0..<frames {
        let v = amplitude * sinf(2 * .pi * frequency * Float(f) / sampleRate)
        for c in 0..<channels { out[f * channels + c] = v }
    }
    return out
}

private func noise(seconds: Float, amplitude: Float, channels: Int = 2) -> [Float] {
    var generator = SystemRandomNumberGenerator()
    return (0..<(Int(seconds * sampleRate) * channels)).map { _ in Float.random(in: -amplitude...amplitude, using: &generator) }
}

private func rmsDB(_ samples: ArraySlice<Float>) -> Float {
    let meanSquare = samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
    return 10 * log10f(max(meanSquare, 1e-12))
}

/// Runs the processor in 512-frame callbacks, like the audio device would.
@discardableResult
private func run(_ processor: BoostProcessor, _ samples: inout [Float], channels: Int = 2, target: Float) -> [Float] {
    let frames = samples.count / channels
    var applied: [Float] = []
    samples.withUnsafeMutableBufferPointer { buffer in
        var start = 0
        while start < frames {
            let n = min(512, frames - start)
            processor.process(buffer.baseAddress! + start * channels, frames: n, channels: channels, targetBoostDB: target)
            applied.append(processor.appliedBoostDB)
            start += n
        }
    }
    return applied
}

@Test func outputNeverExceedsPeakCeiling() {
    for profile in [SafetyProfile.speakers, .headphones] {
        let processor = BoostProcessor(sampleRate: sampleRate, profile: profile)
        var samples = noise(seconds: 3, amplitude: 1)
        run(processor, &samples, target: 40)
        let ceiling = dbToGain(profile.peakCeilingDBFS)
        #expect(samples.allSatisfy { abs($0) <= ceiling + 1e-6 })
    }
}

@Test func boostNeverExceedsProfileMaximum() {
    let processor = BoostProcessor(sampleRate: sampleRate, profile: .headphones)
    var samples = sine(seconds: 6, amplitude: 0.01)
    let applied = run(processor, &samples, target: 50)
    #expect(applied.max()! <= SafetyProfile.headphones.maxBoostDB + 1e-4)
    #expect(abs(applied.last! - SafetyProfile.headphones.maxBoostDB) < 0.01)
}

@Test func boostRampsUpSlowly() {
    let processor = BoostProcessor(sampleRate: sampleRate, profile: .speakers)
    var samples = sine(seconds: 1, amplitude: 0.01)
    let applied = run(processor, &samples, target: 12)
    #expect(applied.last! <= BoostProcessor.rampUpDBPerSecond + 0.05)
    #expect(applied.last! > BoostProcessor.rampUpDBPerSecond - 0.1)
    #expect(applied.first! < 0.1)
}

@Test func boostDropsQuicklyWhenTargetIsLowered() {
    let processor = BoostProcessor(sampleRate: sampleRate, profile: .speakers)
    var warmup = sine(seconds: 5, amplitude: 0.01)
    run(processor, &warmup, target: 12)
    #expect(processor.appliedBoostDB > 11.9)
    var after = sine(seconds: 0.25, amplitude: 0.01)
    run(processor, &after, target: 0)
    #expect(processor.appliedBoostDB < 0.01)
}

@Test func loudMaterialGetsLittleBoost() {
    let processor = BoostProcessor(sampleRate: sampleRate, profile: .headphones)
    let amplitude = dbToGain(-10) * sqrtf(2)
    var samples = sine(seconds: 4, amplitude: amplitude)
    let input = samples
    run(processor, &samples, target: 6)
    #expect(processor.appliedBoostDB < 0.01)
    let tail = samples.count / 2
    #expect(rmsDB(samples[tail...]) <= rmsDB(input[tail...]) + 0.1)
}

@Test func quietMaterialGetsBoostUpToLoudnessCeiling() {
    let profile = SafetyProfile.speakers
    let processor = BoostProcessor(sampleRate: sampleRate, profile: profile)
    let inputRMS: Float = -16
    var samples = sine(seconds: 6, amplitude: dbToGain(inputRMS) * sqrtf(2))
    run(processor, &samples, target: 12)
    let expected = profile.loudnessCeilingDBFS - inputRMS
    #expect(abs(processor.appliedBoostDB - expected) < 0.3)
    #expect(rmsDB(samples[(samples.count * 3 / 4)...]) <= profile.loudnessCeilingDBFS + 0.3)
}

@Test func suddenLoudPassageIsTamedQuickly() {
    let processor = BoostProcessor(sampleRate: sampleRate, profile: .speakers)
    var quiet = sine(seconds: 6, amplitude: 0.003)
    run(processor, &quiet, target: 12)
    #expect(processor.appliedBoostDB > 11.9)
    var loud = sine(seconds: 1, amplitude: dbToGain(-8) * sqrtf(2))
    run(processor, &loud, target: 12)
    let ceiling = dbToGain(SafetyProfile.speakers.peakCeilingDBFS)
    #expect(loud.allSatisfy { abs($0) <= ceiling + 1e-6 })
    let from = Int(0.01 * sampleRate) * 2
    let to = Int(0.05 * sampleRate) * 2
    #expect(rmsDB(loud[from..<to]) <= -8 + 1)
}

@Test func loudMusicAfterPauseIsNotBoosted() {
    let processor = BoostProcessor(sampleRate: sampleRate, profile: .headphones)
    var quiet = sine(seconds: 6, amplitude: dbToGain(-40) * sqrtf(2))
    run(processor, &quiet, target: 6)
    #expect(processor.appliedBoostDB > 5.9)
    var pause = [Float](repeating: 0, count: Int(1.5 * sampleRate) * 2)
    run(processor, &pause, target: 6)
    var music = sine(seconds: 0.5, amplitude: dbToGain(-10) * sqrtf(2))
    run(processor, &music, target: 6)
    let from = Int(0.01 * sampleRate) * 2
    let to = Int(0.05 * sampleRate) * 2
    #expect(rmsDB(music[from..<to]) <= -10 + 1)
}

@Test func boostDoesNotGrowDuringSilence() {
    let processor = BoostProcessor(sampleRate: sampleRate, profile: .speakers)
    var silence = [Float](repeating: 0, count: Int(3 * sampleRate) * 2)
    run(processor, &silence, target: 12)
    #expect(processor.appliedBoostDB == 0)
    var alert = sine(seconds: 0.1, amplitude: dbToGain(-20) * sqrtf(2))
    run(processor, &alert, target: 12)
    #expect(rmsDB(alert[...]) <= -20 + 1)
}

@Test func absurdInputDoesNotPoisonTheLevelDetector() {
    let processor = BoostProcessor(sampleRate: sampleRate, profile: .speakers)
    var huge = [Float](repeating: 1e30, count: 1024)
    run(processor, &huge, target: 12)
    #expect(processor.inputLevelDB.isFinite)
    #expect(huge.allSatisfy { abs($0) <= dbToGain(-1) + 1e-6 })
}

@Test func feedbackTripsAndSilences() {
    let processor = BoostProcessor(sampleRate: sampleRate, profile: .speakers)
    var square = (0..<(Int(sampleRate) * 2)).map { Float(($0 / 100) % 2 == 0 ? 0.9 : -0.9) }
    run(processor, &square, target: 6)
    #expect(processor.feedbackTripped)
    #expect(square.suffix(1000).allSatisfy { $0 == 0 })
}

@Test func loudMusicDoesNotTripFeedback() {
    let processor = BoostProcessor(sampleRate: sampleRate, profile: .speakers)
    var music = noise(seconds: 5, amplitude: dbToGain(-6) * sqrtf(3))
    run(processor, &music, target: 12)
    #expect(!processor.feedbackTripped)
}

@Test func invalidSamplesBecomeSilence() {
    let processor = BoostProcessor(sampleRate: sampleRate, profile: .speakers)
    var samples: [Float] = [.nan, .infinity, -.infinity, 0.1, .nan, 0.2]
    run(processor, &samples, target: 12)
    #expect(samples.allSatisfy { $0.isFinite })
    #expect(samples[0] == 0 && samples[1] == 0 && samples[2] == 0)
}

@Test func worksWithMonoAndMultichannel() {
    for channels in [1, 6] {
        let processor = BoostProcessor(sampleRate: sampleRate, profile: .speakers)
        var samples = noise(seconds: 1, amplitude: 1, channels: channels)
        run(processor, &samples, channels: channels, target: 12)
        #expect(samples.allSatisfy { abs($0) <= dbToGain(-1) + 1e-6 })
    }
}

@Test func headphonesAreClassifiedConservatively() {
    #expect(SafetyProfile.for(.headphones).maxBoostDB < SafetyProfile.for(.speakers).maxBoostDB)
    #expect(SafetyProfile.headphones.loudnessCeilingDBFS < SafetyProfile.speakers.loudnessCeilingDBFS)
}

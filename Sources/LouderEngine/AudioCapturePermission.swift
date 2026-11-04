import Foundation

/// "System Audio Recording" permission. macOS has no public API to query it, so this uses the
/// TCC framework's preflight/request functions when available and reports `.unknown` otherwise.
public enum AudioCapturePermission {
    public enum Status: Sendable {
        case authorized
        case denied
        case unknown
    }

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static var service: CFString { "kTCCServiceAudioCapture" as CFString }
    nonisolated(unsafe) private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    public static var status: Status {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: PreflightFunction.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if the user hasn't decided yet.
    public static func request(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else {
            completion(true)
            return
        }
        unsafeBitCast(symbol, to: RequestFunction.self)(service, nil) { completion($0) }
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
}

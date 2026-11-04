import CoreAudio
import Foundation

public struct LouderError: Error, CustomStringConvertible, Sendable {
    public let description: String

    init(_ message: String, status: OSStatus? = nil) {
        if let status, status != noErr {
            description = "\(message) (\(HAL.fourCC(UInt32(bitPattern: status))))"
        } else {
            description = message
        }
    }
}

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func check(_ status: OSStatus, _ action: String) throws {
        if status != noErr { throw LouderError("Failed \(action)", status: status) }
    }

    static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                          as _: T.Type = T.self) -> T? {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var result: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let result else { return nil }
        return result.takeRetainedValue() as String
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        guard let id: AudioObjectID = value(system, kAudioHardwarePropertyDefaultOutputDevice), id != kAudioObjectUnknown else {
            return nil
        }
        return id
    }

    /// Louder's own audio process object. Excluding it from the tap prevents hearing our own
    /// output again (feedback). Returns nil when it can't be confirmed.
    static func ownProcessObject() -> AudioObjectID? {
        let pid = getpid()
        for process in objectList(system, kAudioHardwarePropertyProcessObjectList) {
            if let processPID: pid_t = value(process, kAudioProcessPropertyPID), processPID == pid {
                return process
            }
        }
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        guard let processPID: pid_t = value(object, kAudioProcessPropertyPID), processPID == pid else { return nil }
        return object
    }

    static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xff) }
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }), let s = String(bytes: bytes, encoding: .ascii) {
            return "'\(s)'"
        }
        return "\(Int32(bitPattern: value))"
    }
}

public struct OutputDevice: Sendable, Hashable, Identifiable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let kind: OutputKind

    public var profile: SafetyProfile { .for(kind) }

    static let louderUIDPrefix = "louder-"

    init?(id: AudioObjectID) {
        guard let uid = HAL.string(id, kAudioDevicePropertyDeviceUID),
              !uid.hasPrefix(Self.louderUIDPrefix),
              HAL.channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0 else { return nil }
        self.id = id
        self.uid = uid
        name = HAL.string(id, kAudioObjectPropertyName) ?? "Unknown device"
        kind = Self.classify(id, name: name)
    }

    public static func all() -> [OutputDevice] {
        HAL.objectList(HAL.system, kAudioHardwarePropertyDevices).compactMap(OutputDevice.init(id:))
    }

    public static func systemDefault() -> OutputDevice? {
        HAL.defaultOutputDevice().flatMap(OutputDevice.init(id:))
    }

    /// Wireless and unknown devices get the conservative headphone profile.
    static func classify(_ id: AudioObjectID, name: String) -> OutputKind {
        let lowered = name.lowercased()
        let transport: UInt32 = HAL.value(id, kAudioDevicePropertyTransportType) ?? kAudioDeviceTransportTypeUnknown
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .headphones
        default:
            break
        }
        if ["headphone", "airpods", "buds", "headset", "earphone"].contains(where: lowered.contains) {
            return .headphones
        }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            let internalSpeakers: UInt32 = 0x6973_706B // 'ispk'
            let source: UInt32? = HAL.value(id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
            return source == internalSpeakers || (source == nil && lowered.contains("speaker")) ? .speakers : .headphones
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAirPlay:
            return .speakers
        default:
            return ["speaker", "display"].contains(where: lowered.contains) ? .speakers : .headphones
        }
    }
}

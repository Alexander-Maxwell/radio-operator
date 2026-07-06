import Foundation
import CoreAudio

/// Default-output introspection for the meeting echo guard and start-time
/// diagnostics. The guard only needs to know one thing: is the far side going
/// to leak out of speakers into the mic (echo → mislabeled "Me"), or is the
/// user on headphones (no leak)? Anything that isn't confidently headphones is
/// treated as speakers, so the guard errs on — the conservative, correct
/// direction after the "built-in speakers only" gating bug.
enum AudioOutputDevices {
    /// Built-in headphone-jack data source ('hdpn' four-char code).
    static let headphonesDataSource: UInt32 = 0x6864_706E // 'hdpn'

    struct Device: Equatable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let transport: UInt32
        let dataSource: UInt32?
        var isHeadphones: Bool { AudioOutputDevices.classifyHeadphones(dataSource: dataSource) }
    }

    /// Pure classifier (unit-tested): only the built-in headphone jack reports
    /// 'hdpn'. Built-in speakers ('ispk'), external/USB/HDMI/Bluetooth outputs,
    /// and unknown sources are all treated as NOT headphones so the echo guard
    /// stays on for them.
    static func classifyHeadphones(dataSource: UInt32?) -> Bool {
        dataSource == headphonesDataSource
    }

    static func defaultOutput() -> Device? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        return Device(
            id: deviceID,
            uid: stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "",
            name: stringProperty(deviceID, selector: kAudioObjectPropertyName) ?? "Default",
            transport: transportType(deviceID),
            dataSource: outputDataSource(deviceID))
    }

    /// Human-readable transport for the start-time diagnostic log.
    static func transportLabel(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:      return "built-in"
        case kAudioDeviceTransportTypeBluetooth:    return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE:  return "bluetooth-le"
        case kAudioDeviceTransportTypeUSB:          return "usb"
        case kAudioDeviceTransportTypeHDMI:         return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort:  return "displayport"
        case kAudioDeviceTransportTypeAirPlay:      return "airplay"
        case kAudioDeviceTransportTypeVirtual:      return "virtual"
        case kAudioDeviceTransportTypeAggregate:    return "aggregate"
        case kAudioDeviceTransportTypeThunderbolt:  return "thunderbolt"
        default:                                    return "other(\(transport))"
        }
    }

    // MARK: - Private

    private static func transportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport) == noErr else { return 0 }
        return transport
    }

    private static func outputDataSource(_ deviceID: AudioDeviceID) -> UInt32? {
        var source: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &source) == noErr else { return nil }
        return source
    }

    private static func stringProperty(_ deviceID: AudioDeviceID,
                                       selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}

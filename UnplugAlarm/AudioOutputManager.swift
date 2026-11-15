//
//  AudioOutputManager.swift
//  Unplug Alarm
//
//  Detects whether the alarm would be audible through the internal speakers
//  and forces the default output back to the built-in device when possible.
//

import Foundation
import CoreAudio

final class AudioOutputManager {
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private static let internalSpeakerDataSource: UInt32 = 0x6973_706B // 'ispk'

    /// Device that was the default output before we first switched away from it.
    /// Restored on `restoreOriginalOutput()`.
    private var deviceToRestore: AudioObjectID?
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    deinit {
        stopMonitoring()
    }

    // MARK: - Detection

    static func defaultOutputDevice() -> AudioObjectID {
        property(systemObject, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0)).value
    }

    /// Conservative rule: only `transport == built-in` **and** `dataSource == 'ispk'`
    /// counts as the internal speaker. A built-in device with an unreadable data
    /// source may be a wired headphone jack, so it does not count.
    static func isInternalSpeaker(_ device: AudioObjectID) -> Bool {
        guard transportType(device) == kAudioDeviceTransportTypeBuiltIn else { return false }
        let (source, status) = property(device, kAudioDevicePropertyDataSource,
                                        scope: kAudioObjectPropertyScopeOutput, default: UInt32(0))
        return status == noErr && source == internalSpeakerDataSource
    }

    static func isDefaultOutputInternalSpeaker() -> Bool {
        isInternalSpeaker(defaultOutputDevice())
    }

    static func defaultOutputName() -> String? {
        deviceName(defaultOutputDevice())
    }

    /// The built-in output device (MacBook speakers / headphone jack).
    static func builtInOutputDevice() -> AudioObjectID? {
        let candidates = allDevices().filter { hasOutputStreams($0) && transportType($0) == kAudioDeviceTransportTypeBuiltIn }
        return candidates.first(where: isInternalSpeaker) ?? candidates.first
    }

    // MARK: - Switching

    /// Makes the built-in device the default output. Returns true if the default
    /// output is the built-in device afterwards. A wired 3.5 mm headphone cannot
    /// be overridden (the data source is not settable), that case is only logged.
    @discardableResult
    func forceBuiltInOutput() -> Bool {
        let current = Self.defaultOutputDevice()
        guard let builtIn = Self.builtInOutputDevice() else {
            print("[Audio] No built-in output device found")
            return false
        }

        if current == builtIn {
            if !Self.isInternalSpeaker(builtIn) {
                print("[Audio] Built-in output is not the internal speaker (wired headphones?) — cannot switch")
            }
            return true
        }

        var newDevice = builtIn
        let status = AudioObjectSetPropertyData(
            Self.systemObject, &defaultOutputAddress, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &newDevice
        )
        guard status == noErr else {
            print("[Audio] Failed to switch default output to built-in: \(status)")
            return false
        }

        if deviceToRestore == nil {
            deviceToRestore = current
        }
        print("[Audio] Switched default output from \(Self.deviceName(current) ?? "?") to built-in")
        return true
    }

    /// Switches back to the device that was active before our first override.
    func restoreOriginalOutput() {
        guard let original = deviceToRestore else { return }
        deviceToRestore = nil

        // The device may have disappeared (e.g. AirPods disconnected).
        guard Self.allDevices().contains(original), Self.hasOutputStreams(original) else { return }
        guard Self.defaultOutputDevice() != original else { return }

        var device = original
        let status = AudioObjectSetPropertyData(
            Self.systemObject, &defaultOutputAddress, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &device
        )
        if status != noErr {
            print("[Audio] Failed to restore default output: \(status)")
        }
    }

    // MARK: - Monitoring

    /// While active: if the default output moves away from the built-in device
    /// (e.g. AirPods connect), switch it back. Our own switches also fire the
    /// listener; they are ignored because the output is then already built-in.
    func startMonitoring() {
        guard listenerBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.defaultOutputChanged()
        }
        let status = AudioObjectAddPropertyListenerBlock(Self.systemObject, &defaultOutputAddress, .main, block)
        if status == noErr {
            listenerBlock = block
        } else {
            print("[Audio] Failed to add default output listener: \(status)")
        }
    }

    func stopMonitoring() {
        guard let block = listenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(Self.systemObject, &defaultOutputAddress, .main, block)
        listenerBlock = nil
    }

    private func defaultOutputChanged() {
        let current = Self.defaultOutputDevice()
        if Self.transportType(current) == kAudioDeviceTransportTypeBuiltIn {
            if !Self.isInternalSpeaker(current) {
                print("[Audio] Output changed to built-in non-speaker source (wired headphones?) — cannot switch back")
            }
            return
        }
        print("[Audio] Output moved to \(Self.deviceName(current) ?? "?") — switching back to built-in")
        forceBuiltInOutput()
    }

    // MARK: - CoreAudio helpers

    private static func property<T: FixedWidthInteger>(_ object: AudioObjectID,
                                    _ selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                    default defaultValue: T) -> (value: T, status: OSStatus) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = defaultValue
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return (value, status)
    }

    private static func transportType(_ device: AudioObjectID) -> UInt32 {
        property(device, kAudioDevicePropertyTransportType, default: UInt32(0)).value
    }

    private static func deviceName(_ device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func allDevices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }
}

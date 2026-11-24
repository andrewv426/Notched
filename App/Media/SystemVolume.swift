import AudioToolbox
import CoreAudio
import NotchedCore

/// The Mac's output volume: the default output device's main volume and mute, through CoreAudio.
/// It reports on every change (the volume keys, another app, a new default device such as AirPods)
/// and sets the level when the slider moves. No permission is needed.
@MainActor
final class SystemVolume {
    private let deliver: @MainActor (OutputVolume?) -> Void
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var listening = false

    private static var defaultOutput = address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
    private static var volume = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
    private static var mute = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)

    init(deliver: @escaping @MainActor (OutputVolume?) -> Void) {
        self.deliver = deliver
    }

    func start() {
        guard !listening else { return }
        listening = true
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutput, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        follow()
    }

    /// Sets the level and unmutes, as the volume keys do.
    func set(_ level: Double) {
        var value = Float32(level)
        AudioObjectSetPropertyData(device, &Self.volume, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        var off = UInt32(0)
        if AudioObjectHasProperty(device, &Self.mute) {
            AudioObjectSetPropertyData(device, &Self.mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &off)
        }
    }

    /// Moves the listeners to the current default output device and reports its volume.
    private func follow() {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutput, 0, nil, &size, &id)
        if id != device {
            if let deviceListener, device != kAudioObjectUnknown {
                AudioObjectRemovePropertyListenerBlock(device, &Self.volume, .main, deviceListener)
                AudioObjectRemovePropertyListenerBlock(device, &Self.mute, .main, deviceListener)
            }
            device = id
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.report() }
            }
            deviceListener = listener
            if id != kAudioObjectUnknown {
                AudioObjectAddPropertyListenerBlock(id, &Self.volume, .main, listener)
                AudioObjectAddPropertyListenerBlock(id, &Self.mute, .main, listener)
            }
        }
        report()
    }

    /// Nil when the device has no volume it lets us set (some HDMI and USB interfaces).
    private func report() {
        var settable: DarwinBoolean = false
        guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &Self.volume),
              AudioObjectIsPropertySettable(device, &Self.volume, &settable) == noErr, settable.boolValue else {
            return deliver(nil)
        }
        var level = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &Self.volume, 0, nil, &size, &level) == noErr else { return deliver(nil) }
        var muted = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &Self.mute) {
            AudioObjectGetPropertyData(device, &Self.mute, 0, nil, &size, &muted)
        }
        deliver(OutputVolume(level: Double(level), isMuted: muted != 0))
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

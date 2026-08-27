import CoreAudio
import Foundation

/// An input device: the system default, or one the user pinned Mumble to.
///
/// Following the default is still the normal case, and it is what the engine does on its own:
/// macOS routes the input node through the default-device aggregate, which moves off the
/// built-in mic the instant AirPods connect. Pinning exists for the case that aggregate gets
/// you nothing — a call has taken the headset, and you want dictation on the laptop mic
/// regardless of what the system default does next.
///
/// The old warning still holds and is why pinning is opt-in: forcing the node onto a raw
/// Bluetooth device mid-negotiation knocks it off the aggregate, `installTap` fails with
/// "config change pending", and the recording captures nothing. `AudioCapture` therefore only
/// calls `setDeviceID` when there is an explicit preference to honour, and falls back to the
/// default when that call fails.
struct AudioInputDevice: Equatable, Sendable, Identifiable {
    let id: AudioDeviceID
    let name: String
    /// Stable across reboots and reconnects, unlike `id`. This is what a preference stores —
    /// an `AudioDeviceID` is a handle CoreAudio hands out fresh each time.
    let uid: String

    /// There is deliberately no `isWireless` here, and no transport type to derive it from.
    /// Whether a device is slow to wake is measured — the connecting cue fires off the
    /// first buffer's actual arrival time — and a transport check would only ever be a
    /// worse guess at the same thing.
    static var systemDefault: AudioInputDevice? {
        guard let id = defaultInputID, id != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return device(id)
    }

    /// Every device that can actually record, for the picker.
    ///
    /// Filtered by input channel count rather than by name or transport: a device with no
    /// input streams is an output, and the list has to be the devices you could plausibly
    /// dictate into or the preference points at something that can never work.
    static var all: [AudioInputDevice] {
        allDeviceIDs
            .filter { inputChannelCount(of: $0) > 0 }
            .map(device)
            .filter { !$0.isPlumbing }
    }

    /// Devices that exist for the audio system rather than for the user.
    ///
    /// `AVAudioEngine` publishes a private aggregate — `CADefaultDeviceAggregate-<pid>-0` —
    /// for the duration of a recording, and it has input channels like any other device. Left
    /// in, the picker grows a row while you dictate and every entry below it shifts down.
    private var isPlumbing: Bool {
        uid.hasPrefix("CADefaultDeviceAggregate") || Self.isHidden(id)
    }

    /// The pinned device, if it is still around. Returns nil when the preference names
    /// something unplugged — which is the case the caller has to fall back from.
    static func withUID(_ uid: String) -> AudioInputDevice? {
        all.first { $0.uid == uid }
    }

    private static func device(_ id: AudioDeviceID) -> AudioInputDevice {
        AudioInputDevice(
            id: id,
            name: name(of: id) ?? "Unknown input",
            uid: uid(of: id) ?? "\(id)"
        )
    }

    // MARK: - CoreAudio

    private static var defaultInputID: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        guard status == noErr else {
            Log.audio.error("default input query failed (OSStatus \(status))")
            return nil
        }
        return id
    }

    private static var allDeviceIDs: [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    /// How many input channels a device has, which is how "is this a microphone" is answered.
    private static func inputChannelCount(of id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }

        // `AudioBufferList` is variable-length, so it has to be read into raw storage rather
        // than into a value of the struct type — the struct only describes its first buffer.
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else {
            return 0
        }

        let list = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func isHidden(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    private static func uid(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // CoreAudio hands back a +1 reference; `takeRetainedValue` is what balances it.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

}

/// Reports default-input changes on the main actor.
///
/// Two properties are watched, not one. The default device changing covers "the user picked
/// a different mic"; the device *list* changing covers the case that actually matters here,
/// where AirPods connect and macOS promotes them to default as part of the same event — the
/// list notification is the one that fires reliably for a device that did not exist a moment
/// ago.
@MainActor
final class AudioInputObserver {
    /// Registrations live in a box rather than a stored array so `deinit` can unregister
    /// them: `deinit` is nonisolated, this class is not, and CoreAudio's unregister call is
    /// safe from any thread. Without it a dropped observer leaves live listener blocks
    /// registered against the system object for the rest of the process.
    private final class Registrations: @unchecked Sendable {
        var entries: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

        func removeAll() {
            for (address, block) in entries {
                var address = address
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
                )
            }
            entries.removeAll()
        }
    }

    private let registrations = Registrations()

    private static let watched: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDevices,
    ]

    func start(onChange: @escaping @MainActor (AudioInputDevice?) -> Void) {
        guard registrations.entries.isEmpty else { return }

        for selector in Self.watched {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                // Delivered on the queue passed below, which is the main queue — so the
                // isolation assumption is a fact about this call, not a hope.
                MainActor.assumeIsolated { onChange(AudioInputDevice.systemDefault) }
            }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
            )
            if status == noErr {
                registrations.entries.append((address, block))
            } else {
                Log.audio.error("input listener failed (OSStatus \(status))")
            }
        }
    }

    func stop() {
        registrations.removeAll()
    }

    deinit {
        registrations.removeAll()
    }
}

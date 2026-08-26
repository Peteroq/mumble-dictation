import CoreAudio
import Foundation

/// The system's current default input device, for display and for change detection.
///
/// Read-only on purpose. An earlier version of this used the device id to pin
/// `AVAudioEngine`'s input node with `setDeviceID`, on the theory that the engine would not
/// otherwise follow the default input. It does: macOS routes the node through the
/// default-device aggregate, which moves off the built-in mic the instant AirPods connect.
/// Forcing the node onto the raw Bluetooth device knocked it off that aggregate mid-format
/// negotiation, `installTap` failed with "config change pending", and the recording captured
/// nothing at all. The id survives only so `Equatable` can tell two identically named
/// devices apart.
struct AudioInputDevice: Equatable, Sendable {
    let id: AudioDeviceID
    let name: String

    /// There is deliberately no `isWireless` here, and no transport type to derive it from.
    /// Whether a device is slow to wake is measured — the connecting cue fires off the
    /// first buffer's actual arrival time — and a transport check would only ever be a
    /// worse guess at the same thing.
    static var systemDefault: AudioInputDevice? {
        guard let id = defaultInputID, id != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return AudioInputDevice(id: id, name: name(of: id) ?? "Unknown input")
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

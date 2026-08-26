import CoreAudio
import Foundation

/// The system's current default input device.
///
/// `AVAudioEngine` on macOS does **not** follow the system default input on its own. Its
/// input node binds to whatever device was default the first time the node was pulled and
/// never re-checks, so connecting AirPods after launch would otherwise keep recording from
/// the built-in mic until the app was relaunched. `AudioCapture` re-pins the node from this
/// type on every start, which is what makes "put in AirPods, then talk" work.
struct AudioInputDevice: Equatable, Sendable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32

    /// Wireless mics negotiate a call-quality profile before delivering a single sample.
    /// On AirPods that handshake is long enough to hear, which is what the connecting cue
    /// exists to cover; a built-in mic is live within a buffer or two.
    var isWireless: Bool {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeAirPlay,
             kAudioDeviceTransportTypeContinuityCaptureWireless:
            true
        default:
            false
        }
    }

    static var systemDefault: AudioInputDevice? {
        guard let id = defaultInputID, id != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return AudioInputDevice(
            id: id,
            name: name(of: id) ?? "Unknown input",
            transport: transport(of: id)
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

    private static func transport(of id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        return status == noErr ? transport : 0
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

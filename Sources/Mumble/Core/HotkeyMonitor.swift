import AppKit
import Carbon.HIToolbox
import Foundation

/// Which modifier key holds the mic open.
enum PushToTalkKey: String, CaseIterable, Sendable {
    case rightOption
    case fn
    case rightCommand

    var keyCode: Int64 {
        switch self {
        case .rightOption: Int64(kVK_RightOption)   // 61
        case .fn: Int64(kVK_Function)               // 63
        case .rightCommand: Int64(kVK_RightCommand) // 54
        }
    }

    /// Device-*dependent* bit for this specific physical key.
    ///
    /// `CGEventFlags.maskAlternate` is the union mask — it's set whenever *either* Option
    /// key is down. Using it means: hold Left ⌥, tap Right ⌥, and the release is invisible
    /// (the union bit is still set by the left key), so `onRelease` never fires. The mic
    /// stays open, the HUD stays up, and the next press is swallowed too.
    ///
    /// These raw values are the NX_DEVICE* masks from IOKit's event system; they carry the
    /// left/right distinction that the public `CGEventFlags` constants discard.
    var flag: CGEventFlags {
        switch self {
        case .rightOption: CGEventFlags(rawValue: 0x40)   // NX_DEVICERALTKEYMASK
        case .rightCommand: CGEventFlags(rawValue: 0x10)  // NX_DEVICERCMDKEYMASK
        case .fn: .maskSecondaryFn                        // no left/right variant exists
        }
    }

    var displayName: String {
        switch self {
        case .rightOption: "Right ⌥"
        case .fn: "fn"
        case .rightCommand: "Right ⌘"
        }
    }

    /// Every supported key is swallowed, `fn` included.
    ///
    /// `fn` used to be let through on the theory that consuming it would break fn+arrow,
    /// fn+delete and fn+F-keys. It does not: those combinations are translated below the
    /// session tap and arrive as their own key events carrying `maskSecondaryFn` in their
    /// own flags. What this consumes is only the `flagsChanged` notification that the
    /// modifier moved — which is also what the system's globe-key action watches for, and
    /// that action firing mid-dictation is the emoji palette landing on top of the HUD.
    var shouldConsumeEvent: Bool { true }
}

/// Watches for a held modifier key using a `CGEventTap`.
///
/// A tap is required rather than `NSEvent.addGlobalMonitor` because `fn` and left/right
/// modifier discrimination don't surface through the higher-level APIs. This needs
/// Accessibility permission; without it `CGEvent.tapCreate` returns nil.
@MainActor
final class HotkeyMonitor {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false

    /// Whether the mic is being held open by a double tap rather than by the key.
    private(set) var isLatched = false
    private var pressedAt: Date?
    /// A tap's release, held back in case a second tap is coming. See `release()`.
    private var heldRelease: Task<Void, Never>?
    /// Set when a press has already been acted on and the release that follows means nothing.
    private var ignoresNextRelease = false

    /// A press shorter than this is a tap rather than a hold.
    private static let tapCeiling: TimeInterval = 0.3
    /// How long after a tap a second one still counts as a double tap.
    private static let doubleTapWindow: TimeInterval = 0.4

    var key: PushToTalkKey = .rightOption
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// A double tap. The recording the first tap started keeps running with nothing held.
    var onLatch: (() -> Void)?
    /// A tap while latched: stop.
    var onUnlatch: (() -> Void)?

    /// - Returns: `false` if the tap couldn't be created — almost always missing Accessibility permission.
    @discardableResult
    func start() -> Bool {
        stop()

        let mask = (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

                // CGEvent isn't Sendable, so pull out the plain values before crossing into
                // actor-isolated code. The tap was added to the main run loop, so this
                // callback genuinely does run on the main thread.
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags
                let consume = MainActor.assumeIsolated {
                    monitor.handle(type: type, keyCode: keyCode, flags: flags)
                }
                return consume ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            Log.hotkey.error("tapCreate failed — Accessibility permission missing?")
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        Log.hotkey.info("listening for \(self.key.displayName)")
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isPressed = false
        heldRelease?.cancel()
        heldRelease = nil
        pressedAt = nil
        ignoresNextRelease = false
        isLatched = false
    }

    // MARK: - Tap callback

    /// - Returns: `true` if the event should be swallowed rather than passed along.
    private func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        // The system disables a tap that runs too slowly or is interrupted; re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        guard type == .flagsChanged, keyCode == key.keyCode else { return false }

        let nowPressed = flags.contains(key.flag)
        guard nowPressed != isPressed else { return false }
        isPressed = nowPressed

        if nowPressed { press() } else { release() }

        return key.shouldConsumeEvent
    }

    // MARK: - Press and release
    //
    // Three gestures on one key. Hold it and talk; tap it twice and talk with your hands
    // free; tap it once more to stop. They are told apart by how long the key was down and
    // how soon the next press arrives — nothing else about the key is different.

    private func press() {
        if isLatched {
            // A tap while hands-free means stop, and the release that follows it is not a
            // release of anything: what it would have ended is already ending.
            isLatched = false
            ignoresNextRelease = true
            onUnlatch?()
            return
        }

        if let pending = heldRelease {
            // The second press of a double tap, arriving before the first tap's release was
            // allowed to land. Because that release was held back, the recording the first
            // tap started is still running — so latching it starts nothing and stops
            // nothing, and the two taps read as one continuous gesture.
            pending.cancel()
            heldRelease = nil
            isLatched = true
            onLatch?()
            return
        }

        pressedAt = Date()
        onPress?()
    }

    private func release() {
        if ignoresNextRelease {
            ignoresNextRelease = false
            return
        }
        // Hands-free: the key is not what is holding the mic open, so letting go means
        // nothing. Only the next press does.
        if isLatched { return }

        guard let pressedAt else {
            onRelease?()
            return
        }
        let held = Date().timeIntervalSince(pressedAt)
        self.pressedAt = nil

        // A real hold ends the moment it ends. Only a tap pays the wait below, and a tap is
        // not how anyone dictates a sentence.
        guard held < Self.tapCeiling else {
            onRelease?()
            return
        }

        heldRelease = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.doubleTapWindow))
            guard !Task.isCancelled, let self else { return }
            self.heldRelease = nil
            self.onRelease?()
        }
    }
}

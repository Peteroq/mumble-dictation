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

/// What the key did, as the tap saw it.
enum HotkeyGesture: Sendable {
    case press
    case release
    /// A double tap: the recording the first tap started keeps running with nothing held.
    case latch
    /// A tap while latched: stop.
    case unlatch
}

/// The hotkey state machine, deliberately outside Swift concurrency.
///
/// A `CGEventTap` callback is a C function pointer invoked from CoreFoundation's mach-port
/// machinery. This state used to live on the main actor and be reached with
/// `MainActor.assumeIsolated` from inside that callback, which crashes: sixty tap-and-release
/// cycles killed the app every time, `swift_task_isCurrentExecutor` faulting on a garbage
/// pointer while working out which executor it was on. The double-tap gesture is precisely
/// what invites a fast run of taps, so the newest feature made an old fragility easy to
/// reach.
///
/// Nothing here touches an actor. The state is guarded by a lock, the decision to swallow an
/// event is computed synchronously because the callback has to return it, and the gestures
/// the app cares about are handed to the main queue — which, unlike unstructured tasks,
/// delivers them in the order they happened. A press that arrived before a release has to be
/// seen that way round, or the mic latches when it was told to stop.
private final class TapState: @unchecked Sendable {
    /// A press shorter than this is a tap rather than a hold.
    private static let tapCeiling: TimeInterval = 0.3
    /// How long after a tap a second one still counts as a double tap.
    private static let doubleTapWindow: TimeInterval = 0.4

    private let lock = NSLock()

    // Everything below is touched only while `lock` is held.
    private var keyCode: Int64 = 0
    private var flag: CGEventFlags = []
    private var consumes = true
    private var isPressed = false
    private var isLatched = false
    private var pressedAt: Date?
    private var pendingRelease: DispatchWorkItem?
    /// The tap itself, so the callback can re-arm it. The proxy the callback is handed is
    /// not the port and cannot be used for this.
    private var port: CFMachPort?
    /// Set when a press has already been acted on and the release that follows means nothing.
    private var ignoresNextRelease = false

    /// Delivered on the main queue.
    private let emit: @Sendable (HotkeyGesture) -> Void

    init(emit: @escaping @Sendable (HotkeyGesture) -> Void) {
        self.emit = emit
    }

    func adopt(port: CFMachPort) {
        lock.lock()
        defer { lock.unlock() }
        self.port = port
    }

    /// Re-arms a tap the system switched off for running too slowly or being interrupted.
    ///
    /// The events that happened while it was off are gone, so the state machine is now
    /// describing a keyboard that no longer exists. Left alone that is a dead hotkey: if the
    /// key was down when the tap went away, `isPressed` stays `true` and the guard in
    /// `handle` throws away the next genuine press as a duplicate — forever, because the
    /// release that would have cleared it was one of the events we missed.
    ///
    /// So the state is wound back to rest, and if a hold was in progress its release is
    /// synthesized. Ending a recording the user is still holding is the safe direction to be
    /// wrong in; the other way leaves the microphone open with no way to close it.
    func reEnable() {
        lock.lock()
        let port = port
        let wasPressed = isPressed
        let wasLatched = isLatched
        pendingRelease?.cancel()
        pendingRelease = nil
        isPressed = false
        isLatched = false
        pressedAt = nil
        ignoresNextRelease = false
        lock.unlock()

        if let port { CGEvent.tapEnable(tap: port, enable: true) }
        if wasLatched {
            emit(.unlatch)
        } else if wasPressed {
            emit(.release)
        }
    }

    /// Drops the latch without emitting anything.
    ///
    /// The tap decides to latch on its own — it has to, the decision is made from the timing
    /// of two key events and nothing else. But whether a recording is actually *running* is
    /// the controller's business, and the two used to be able to disagree: double-tap while
    /// the previous utterance is still being cleaned up and the controller declines to go
    /// hands-free while the tap latches anyway. From then on the tap reads the next press as
    /// "stop", the controller has nothing to stop, and the key looks broken until it is
    /// pressed a second time.
    ///
    /// This is the controller's way of saying so.
    func clearLatch() {
        lock.lock()
        defer { lock.unlock() }
        isLatched = false
        ignoresNextRelease = false
    }

    func configure(key: PushToTalkKey) {
        lock.lock()
        defer { lock.unlock() }
        keyCode = key.keyCode
        flag = key.flag
        consumes = key.shouldConsumeEvent
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        pendingRelease?.cancel()
        pendingRelease = nil
        port = nil
        isPressed = false
        isLatched = false
        pressedAt = nil
        ignoresNextRelease = false
    }

    /// - Returns: `true` if the event should be swallowed rather than passed along.
    func handle(keyCode code: Int64, flags: CGEventFlags) -> Bool {
        // Gestures are collected under the lock and sent after it is released. `emit` hands
        // work to the main queue, and holding a lock across that hand-off is how a deadlock
        // gets written by accident.
        var gestures: [HotkeyGesture] = []

        lock.lock()
        guard code == keyCode else {
            lock.unlock()
            return false
        }
        let nowPressed = flags.contains(flag)
        guard nowPressed != isPressed else {
            lock.unlock()
            return false
        }
        isPressed = nowPressed
        gestures = nowPressed ? press() : release()
        let swallow = consumes
        lock.unlock()

        for gesture in gestures { emit(gesture) }
        return swallow
    }

    // MARK: - The three gestures
    //
    // Hold the key and talk; tap it twice and talk with your hands free; tap once more to
    // stop. They are told apart by how long the key was down and how soon the next press
    // arrives — nothing else about the key is different.
    //
    // Both of these run with the lock already held.

    private func press() -> [HotkeyGesture] {
        // Only ever applies to the release of the press that set it. Carrying it further
        // would swallow the end of some later hold and leave the mic open.
        ignoresNextRelease = false

        if isLatched {
            // A tap while hands-free means stop, and the release that follows it is not a
            // release of anything: what it would have ended is already ending.
            isLatched = false
            ignoresNextRelease = true
            return [.unlatch]
        }

        if let pending = pendingRelease {
            // The second press of a double tap, arriving before the first tap's release was
            // allowed to land. Because that release was held back, the recording the first
            // tap started is still running — so latching it starts nothing and stops
            // nothing, and the two taps read as one continuous gesture.
            pending.cancel()
            pendingRelease = nil
            isLatched = true
            return [.latch]
        }

        pressedAt = Date()
        return [.press]
    }

    private func release() -> [HotkeyGesture] {
        if ignoresNextRelease {
            ignoresNextRelease = false
            return []
        }
        // Hands-free: the key is not what is holding the mic open, so letting go means
        // nothing. Only the next press does.
        if isLatched { return [] }

        guard let started = pressedAt else { return [.release] }
        pressedAt = nil

        // A real hold ends the moment it ends. Only a tap pays the wait below, and a tap is
        // not how anyone dictates a sentence.
        guard Date().timeIntervalSince(started) < Self.tapCeiling else { return [.release] }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            lock.lock()
            guard pendingRelease != nil else { return lock.unlock() }
            pendingRelease = nil
            lock.unlock()
            emit(.release)
        }
        pendingRelease = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleTapWindow, execute: work)
        return []
    }
}

/// The tap's callback, at file scope on purpose.
///
/// Written as a closure inside `start()` it inherits that method's `@MainActor` isolation,
/// and Swift then emits a runtime isolation check at the closure's entry. That check is what
/// crashes under a fast run of taps — the fault is inside `swift_task_isCurrentExecutor`
/// before a line of this code runs, so no amount of care *within* the callback avoids it. At
/// file scope the function is nonisolated and no check is emitted.
private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let state = Unmanaged<TapState>.fromOpaque(refcon).takeUnretainedValue()

    // The system disables a tap that runs too slowly or is interrupted; re-arm it.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        state.reEnable()
        return Unmanaged.passUnretained(event)
    }
    guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }

    let consume = state.handle(
        keyCode: event.getIntegerValueField(.keyboardEventKeycode),
        flags: event.flags
    )
    return consume ? nil : Unmanaged.passUnretained(event)
}

/// A run loop of our own, on a thread of our own, for the tap to be serviced on.
///
/// The tap used to be added to `CFRunLoopGetCurrent()` from `start()` — which runs on the
/// main actor, so the tap was serviced by the main run loop. The system disables a tap whose
/// callback it cannot deliver promptly, and the main thread of this app is busy for seconds
/// at a time: the cleanup model, SwiftUI laying out a long transcript, a window animating.
/// Every one of those was a chance for the hotkey to be switched off underneath us.
///
/// The callback does almost nothing — takes a lock, updates five fields, hands a gesture to
/// the main queue — so a dedicated thread sits idle except for the microseconds it is
/// actually needed, and is never behind anything.
private final class TapThread: @unchecked Sendable {
    private var runLoop: CFRunLoop?
    private let started = DispatchSemaphore(value: 0)

    /// Blocks until the thread's run loop exists and the source is on it. That wait is
    /// bounded by a thread start, and returning before the tap is live would mean the first
    /// key press after launch quietly did nothing.
    init(source: CFRunLoopSource) {
        nonisolated(unsafe) let source = source
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            started.signal()
            // A run loop with no input sources returns immediately, which is why the source
            // goes on first.
            CFRunLoopRun()
        }
        thread.name = "ai.pivotstudio.mumble.hotkey"
        // Above default, below real-time. The tap is on the path of every modifier press on
        // the machine, and a late callback is a disabled tap.
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
    }

    func stop(source: CFRunLoopSource) {
        guard let runLoop else { return }
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFRunLoopStop(runLoop)
        self.runLoop = nil
    }
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
    private var tapThread: TapThread?
    private var state: TapState?

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

        // The box is what the C callback is handed, and it is deliberately not `self`:
        // reaching a main-actor object from inside that callback is the crash this design
        // exists to avoid.
        let state = TapState { [weak self] gesture in
            DispatchQueue.main.async {
                // Genuinely the main queue, and an ordinary dispatched block rather than the
                // inside of an event-tap callback — which is the difference that matters.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch gesture {
                    case .press: self.onPress?()
                    case .release: self.onRelease?()
                    case .latch: self.onLatch?()
                    case .unlatch: self.onUnlatch?()
                    }
                }
            }
        }
        state.configure(key: key)
        self.state = state

        let mask = (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(state).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyTapCallback,
            userInfo: refcon
        ) else {
            Log.hotkey.error("tapCreate failed — Accessibility permission missing?")
            self.state = nil
            return false
        }

        self.tap = tap
        state.adopt(port: tap)
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            Log.hotkey.error("could not make a run loop source for the tap")
            stop()
            return false
        }
        runLoopSource = source
        tapThread = TapThread(source: source)
        CGEvent.tapEnable(tap: tap, enable: true)

        Log.hotkey.info("listening for \(self.key.displayName)")
        return true
    }

    /// Tells the tap the recording it thinks it is holding open has ended.
    ///
    /// Called from every route out of an active recording, not just the one the tap knows
    /// about. A run can end because the user clicked Record, because the microphone never
    /// delivered a sample, or because the double tap arrived while the previous utterance was
    /// still being cleaned up and was declined — and after any of those the tap is still
    /// latched, so the next press means "stop" to it and nothing to anyone else.
    func clearLatch() {
        state?.clearLatch()
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            tapThread?.stop(source: runLoopSource)
        }
        tapThread = nil
        tap = nil
        runLoopSource = nil
        state?.reset()
        // Released only after the source is off the run loop, so the callback can no longer
        // be handed a pointer to it.
        state = nil
    }
}

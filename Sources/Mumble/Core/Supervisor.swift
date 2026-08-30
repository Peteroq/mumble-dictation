import AppKit
import Foundation

/// The thing that notices when the app has quietly stopped working, and puts it back.
///
/// Every fault this repairs has a first line of defence somewhere else — the tap re-arms
/// itself when the system announces it disabled it, the controller has watchdogs on each
/// stage of starting up, capture rebinds when the engine posts a configuration change. This
/// exists because all of those depend on being *told*, and the failures that actually
/// stranded this app were the silent ones: a tap whose port died with no event, a task torn
/// out mid-flight by an exception that took its own error handling with it, a rebind whose
/// last chance failed with no further notification coming.
///
/// So it assumes nothing was announced. Every two seconds it re-derives what ought to be
/// true from what is observably true, and where they differ it repairs and says so. It is
/// deliberately dull: no state of its own beyond how long the current condition has held,
/// nothing that can itself get stuck, and every repair idempotent so that running it against
/// a healthy app does nothing at all.
@MainActor
final class Supervisor {
    private let controller: DictationController
    private let hud: () -> HUDPanel?

    private var task: Task<Void, Never>?

    /// The state last seen, and when it was first seen. A stuck app is one that has been in
    /// the same state for longer than that state can honestly take.
    private var lastState: DictationController.State = .idle
    private var stateSince = Date()

    /// Consecutive checks that found the HUD disagreeing with the state. Acted on at two
    /// rather than one because a check can land in the middle of a fade.
    private var hudMismatches = 0

    /// Whether the hotkey was armed last time. Only used so recovering it is logged once
    /// rather than every two seconds while Accessibility is switched off.
    private var reportedHotkeyDown = false

    init(controller: DictationController, hud: @escaping () -> HUDPanel?) {
        self.controller = controller
        self.hud = hud
    }

    // MARK: - Limits
    //
    // All well past what the ordinary path takes, because this is the backstop and not the
    // mechanism. If one of these fires it means a watchdog that should have caught the same
    // fault did not run at all.

    private static let interval: Duration = .seconds(2)
    /// A cold Parakeet load is ~20s, and the controller's own startup watchdog is 30s.
    private static let startingLimit: TimeInterval = 45
    /// `endDictation` bounds its own awaits to 9s, and then a smart cleanup pass can add
    /// another few on a cold model. Thirty leaves room for the slowest honest run rather than
    /// racing it.
    private static let finishingLimit: TimeInterval = 30
    /// The controller clears its own errors after 3s.
    private static let errorLimit: TimeInterval = 15

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled, let self else { return }
                check()
            }
        }
        Log.app.info("supervisor watching")
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: - The check

    private func check() {
        checkHotkey()
        checkStuckState()
        checkCapture()
        checkHUD()
    }

    /// The one the user feels first. A dead tap is a dead app, however well the rest of it
    /// is running.
    private func checkHotkey() {
        guard !controller.hotkeyIsArmed else {
            if reportedHotkeyDown {
                Log.hotkey.info("hotkey is armed again")
                reportedHotkeyDown = false
            }
            return
        }

        // Accessibility is the one cause we cannot repair — the grant is the user's to give,
        // and there is no notification when it changes either way, so this poll is also how
        // the app finds out it has been given back.
        guard Permissions.hasAccessibility else {
            if !reportedHotkeyDown {
                Log.hotkey.error("hotkey is down: Accessibility is not granted")
                reportedHotkeyDown = true
            }
            return
        }

        if !reportedHotkeyDown {
            Log.hotkey.error("hotkey is down with Accessibility granted — rearming")
            reportedHotkeyDown = true
        }
        controller.rearmHotkey()
    }

    /// A state that has outlasted anything it could honestly be doing.
    private func checkStuckState() {
        let state = controller.state
        guard state == lastState else {
            lastState = state
            stateSince = Date()
            return
        }

        let held = Date().timeIntervalSince(stateSince)
        let limit: TimeInterval? = switch state {
        case .starting, .connecting: Self.startingLimit
        case .finishing: Self.finishingLimit
        case .error: Self.errorLimit
        // A hands-free recording is allowed to last as long as the user wants, and the stall
        // watchdog is what ends one whose microphone has gone away.
        case .listening, .idle: nil
        }

        guard let limit, held > limit else { return }
        controller.forceReset(reason: "stuck in \(state) for \(Int(held))s")
        lastState = .idle
        stateSince = Date()
    }

    /// A recording that is not recording. The stall watchdog catches this within four
    /// seconds by noticing no buffers arrive; this catches the case where the engine stopped
    /// before a single one ever did.
    private func checkCapture() {
        guard controller.state == .connecting || controller.state == .listening else { return }
        guard !controller.captureIsHealthy else { return }
        controller.recoverCapture()
    }

    /// The band on screen has to agree with the state, in both directions. Stuck visible is
    /// a strip of light over the user's work that nothing will remove; stuck hidden is a
    /// recording with no sign that it is running.
    private func checkHUD() {
        guard let hud = hud() else { return }
        let shouldShow = controller.state.showsHUD
        guard hud.isVisible != shouldShow else {
            hudMismatches = 0
            return
        }

        // One mismatch is very likely a check that landed inside a fade.
        hudMismatches += 1
        guard hudMismatches >= 2 else { return }
        hudMismatches = 0
        Log.app.error("HUD was \(hud.isVisible ? "up" : "down", privacy: .public) with the state saying otherwise — correcting")
        hud.setVisible(shouldShow)
    }
}

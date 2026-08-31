import AppKit
import SwiftUI

/// The band of light that rises from the foot of the screen while you hold the key.
///
/// The single most important property here is that this panel **never becomes key**.
/// If it did, the user's text field would lose focus and `TextInjector` would have
/// nothing to insert into. Hence `.nonactivatingPanel` plus `canBecomeKey == false`.
@MainActor
final class HUDPanel: NSPanel {
    init(controller: DictationController) {
        super.init(
            // Placeholder. The real frame spans whichever screen `reposition` picks, and
            // is set there before the panel is ever ordered in.
            contentRect: NSRect(x: 0, y: 0, width: 800, height: HUDMetrics.bandHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = true

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        contentView = NSHostingView(rootView: HUDView(controller: controller))
    }

    /// Both `nonisolated` on purpose, and it is not a style choice.
    ///
    /// The class is `@MainActor`, so these `@objc` overrides would otherwise carry a runtime
    /// isolation check at their entry. AppKit reads them from inside
    /// `-[NSApplication _handleActivatedEvent:]`, while it enumerates windows looking for a
    /// key-window candidate — and that check faults there, in `swift_task_isCurrentExecutor`,
    /// before a line of this code runs. It is the same fault that used to kill the hotkey tap,
    /// reached by a different route: every app activation is another roll of the dice, and
    /// dictating into another app activates constantly.
    ///
    /// Safe to leave unisolated because neither touches any state — they are constants.
    override nonisolated var canBecomeKey: Bool { false }
    override nonisolated var canBecomeMain: Bool { false }

    /// Where the band sits at rest.
    private var restingFrame: NSRect = .zero

    /// Explicit, rather than inferred from `alphaValue`.
    ///
    /// `present` is called on every active state change — starting, connecting, listening,
    /// finishing — and the first three land inside a third of a second. Reading "already on
    /// the way in" off the alpha meant every one of those restarted the entry from the
    /// beginning, which is what made the band drop back and replay while it was still
    /// arriving.
    private enum Phase { case hidden, entering, shown, leaving }
    private var phase: Phase = .hidden

    private static let entryDuration: TimeInterval = 0.34
    private static let exitDuration: TimeInterval = 0.24

    /// Spans the full width of the active screen, sitting on the bottom of its visible frame.
    ///
    /// Resized on every presentation rather than once at construction: the user can move the
    /// app between displays of different widths between one hold and the next, and a band
    /// sized for the other screen would either stop short or run off the edge.
    ///
    /// The bottom edge is `visibleFrame`, not `frame`, so the band starts above the Dock
    /// instead of laying a gradient over it. The panel ignores mouse events either way, but a
    /// darkened Dock reads as a rendering fault rather than as an intentional backdrop.
    ///
    /// `NSScreen.main` is the screen with the *key window* — and an accessory app with a
    /// non-activating panel never has one, so it can be nil. Falling back to `screens.first`
    /// keeps the HUD on-screen instead of stranding it at the origin.
    func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            Log.app.error("no screen available to position HUD")
            return
        }
        let visible = screen.visibleFrame
        restingFrame = NSRect(
            x: visible.minX,
            y: visible.minY,
            width: visible.width,
            height: HUDMetrics.bandHeight
        )
        setFrame(restingFrame, display: true)
    }

    /// Fades the band in where it stands. The rise belongs to the content, in `HUDView`.
    ///
    /// The window deliberately does not move. Sliding it up from below the screen edge took
    /// its bottom off the display, so the densest part of the gradient was clipped for the
    /// length of the animation and you watched the band's own bottom edge travel up and settle
    /// back down. A fixed window with its contents rising inside it has nowhere to clip.
    func present() {
        switch phase {
        case .entering, .shown:
            // Already arriving, or arrived. Re-running from here is what caused the replay.
            return
        case .leaving:
            // Caught mid-exit. Carry on from whatever the fade reached rather than snapping
            // back to zero first, which would be a visible flash.
            break
        case .hidden:
            reposition()
            alphaValue = 0
            orderFrontRegardless()
        }

        phase = .entering
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.entryDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.phase == .entering else { return }
                self.phase = .shown
            }
        }
    }

    /// Forces the panel to match `visible`, whatever `phase` currently believes.
    ///
    /// `present` and `dismiss` are both guarded by `phase`, which is what stops a burst of
    /// state changes replaying the entry animation. That guard is also what makes them
    /// useless for repair: a panel on screen with `phase` reading `.hidden` cannot be
    /// dismissed by asking it to dismiss. The supervisor needs a way to say what the answer
    /// is rather than ask for a transition, so this sets the phase to whichever value lets
    /// the transition through, then runs it.
    func setVisible(_ visible: Bool) {
        if visible {
            phase = .hidden
            present()
        } else {
            phase = .shown
            dismiss()
        }
    }

    func dismiss() {
        guard phase == .entering || phase == .shown else { return }
        phase = .leaving

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.exitDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // AppKit always calls this on the main thread.
            MainActor.assumeIsolated {
                guard let self else { return }
                // A new hold can start inside the exit animation, in which case `present` has
                // already taken the phase off `.leaving` and this would hide a panel on its
                // way back in.
                guard self.phase == .leaving else { return }
                self.phase = .hidden
                self.orderOut(nil)
            }
        }
    }
}

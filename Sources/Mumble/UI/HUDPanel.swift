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

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Where the band sits at rest. Kept so the entry and exit can be offset from it without
    /// each having to recompute the screen geometry.
    private var restingFrame: NSRect = .zero

    /// How far below its resting place the band starts and ends. Small — the band is most of
    /// the screen's width, and a long travel on something that size reads as a lurch.
    private static let travel: CGFloat = 26
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

    /// Fades in while rising the last few points into place.
    ///
    /// Both at once rather than a fade alone: the band arrives at the bottom of the screen, so
    /// a little upward travel reads as it coming from off-screen instead of materialising.
    func present() {
        // Every active state change (starting → connecting → listening → finishing) calls
        // this. Without the early exit the panel would reset to alpha 0 and replay the entry
        // on each one, which reads as a flicker mid-utterance.
        guard !isVisible || alphaValue < 1 else { return }

        reposition()
        var start = restingFrame
        start.origin.y -= Self.travel
        setFrame(start, display: false)
        alphaValue = 0
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.entryDuration
            // Fast at the start and settling at the end, so the band decelerates into place
            // rather than stopping dead.
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrame(restingFrame, display: true)
        }
    }

    func dismiss() {
        var end = restingFrame
        end.origin.y -= Self.travel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.exitDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
            animator().setFrame(end, display: true)
        } completionHandler: { [weak self] in
            // AppKit always calls this on the main thread.
            MainActor.assumeIsolated {
                guard let self else { return }
                // A new hold can start inside the exit animation, in which case `present` has
                // already run and this handler is about to hide a panel that is on its way
                // back in. Checking the alpha rather than a flag keeps the two in one place.
                guard self.alphaValue < 0.01 else { return }
                self.orderOut(nil)
                self.setFrame(self.restingFrame, display: false)
            }
        }
    }
}

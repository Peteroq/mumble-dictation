import MetalKit
import SwiftUI

/// The orb, as a SwiftUI view backed by Metal.
///
/// `MTKView` rather than a hand-rolled `CAMetalLayer` plus display link: it already owns the
/// drawable lifecycle, the resize callback and the vsync timer, none of which this needs to do
/// differently.
struct OrbView: NSViewRepresentable {
    /// Smoothed 0…1 microphone level. Drives displacement and brightness.
    var level: Float
    /// Whether to run the display loop at all.
    var isActive: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60

        // Transparent, and clearing to transparent: the orb floats on the HUD's liquid glass,
        // so anything opaque here would paint a rectangle over the effect the panel is built
        // around. `composite_fragment` writes premultiplied alpha to match.
        view.layer?.isOpaque = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.level = level
        // Paused while the HUD is down. The panel is built once and merely hidden, so without
        // this the orb would keep drawing at 60fps behind an invisible window for as long as
        // the app is running.
        view.isPaused = !isActive
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice?
        private var renderer: OrbRenderer?
        private var queue: MTLCommandQueue?
        private var started = CFAbsoluteTimeGetCurrent()

        /// Written from `updateNSView` on the main actor, read in `draw(in:)`, which `MTKView`
        /// also calls on the main thread. Unchecked because `MTKViewDelegate` is not isolated.
        nonisolated(unsafe) var level: Float = 0

        override init() {
            device = MTLCreateSystemDefaultDevice()
            super.init()
            guard let device else {
                Log.app.error("orb: no Metal device — the HUD will show an empty slot")
                return
            }
            do {
                // Compiles the shader source. Costs a beat once, at HUD construction, which is
                // app launch rather than the first time the user holds the key.
                renderer = try OrbRenderer(device: device, outputFormat: .bgra8Unorm)
                queue = device.makeCommandQueue()
            } catch {
                Log.app.error("orb: renderer unavailable — \(error.localizedDescription)")
            }
        }

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        nonisolated func draw(in view: MTKView) {
            // `MTKView` drives this from its own display link on the main thread; the assumption
            // is a fact about that call, not a hope.
            MainActor.assumeIsolated {
                guard let renderer, let queue,
                      let drawable = view.currentDrawable,
                      let commandBuffer = queue.makeCommandBuffer()
                else { return }

                let elapsed = Float(CFAbsoluteTimeGetCurrent() - started)
                renderer.render(
                    into: drawable.texture,
                    commandBuffer: commandBuffer,
                    level: level,
                    time: elapsed,
                    // A slow turn so the form reads as three-dimensional rather than as a
                    // flat texture that happens to wobble.
                    yaw: 0.6 + elapsed * 0.12,
                    pitch: -0.15,
                    contentScale: Float(view.window?.backingScaleFactor ?? 2)
                )
                commandBuffer.present(drawable)
                commandBuffer.commit()
            }
        }
    }
}

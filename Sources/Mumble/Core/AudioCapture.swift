import AVFoundation
import Foundation
import MumbleObjC

/// Runs an AVFAudio call that is entitled to raise an Objective-C exception.
///
/// Every use below is a call that AVFAudio documents as throwing an `NSError` and that in
/// practice raises instead. Without this the raise unwinds out of whatever async task made
/// the call and nothing after it runs — see `MumbleObjC.h`.
private func catchingObjC(_ what: String, _ body: () -> Void) throws {
    var raised: NSError?
    guard MumbleRunCatchingException(body, &raised) else {
        let reason = raised?.localizedDescription ?? "unknown"
        Log.audio.error("\(what, privacy: .public) raised: \(reason, privacy: .public)")
        throw TranscriptionError.audioUnavailable(reason)
    }
}

/// Microphone capture with on-the-fly conversion to whatever format the speech engine wants.
///
/// The tap runs on a real-time audio thread, so everything it touches lives behind
/// `nonisolated(unsafe)` and is only ever mutated from that one thread.
final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private nonisolated(unsafe) var converter: AVAudioConverter?
    /// The input format `converter` was built for, so a format change can be noticed.
    private nonisolated(unsafe) var converterInput: AVAudioFormat?
    private nonisolated(unsafe) var outputFormat: AVAudioFormat?
    private var isRunning = false

    /// Called on the audio thread with each converted buffer.
    private nonisolated(unsafe) var onBuffer: (@Sendable (AudioChunk) -> Void)?
    /// Called on the audio thread with a 0…1 RMS level, for the HUD waveform.
    private nonisolated(unsafe) var onLevel: (@Sendable (Float) -> Void)?
    /// Called once, on the audio thread, when the first buffer arrives from the device.
    private nonisolated(unsafe) var onReady: (@Sendable () -> Void)?
    /// Latches so a mid-recording device swap doesn't re-announce the mic as newly live.
    private nonisolated(unsafe) var hasDeliveredAudio = false

    private var configObserver: NSObjectProtocol?

    /// The device the user pinned Mumble to, by UID, or nil to follow the system default.
    /// Handed in at `start` rather than read from `Settings` here — this type is not
    /// main-actor isolated, and the audio thread must not touch it.
    private nonisolated(unsafe) var preferredDeviceUID: String?

    /// - Returns: the device the tap was bound to, or `nil` if CoreAudio had no default input.
    @discardableResult
    func start(
        outputFormat: AVAudioFormat,
        preferredDeviceUID: String? = nil,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onReady: @escaping @Sendable () -> Void = {}
    ) async throws -> AudioInputDevice? {
        // A start over a capture that is already running is a bug in the caller, and the old
        // early return made it an invisible one: it kept the previous run's callbacks and its
        // already-latched `hasDeliveredAudio`, so the new recording never announced itself as
        // live. No chime, no `.listening`, and five seconds later a liveness error about a
        // microphone that was working the whole time. Stopping first is both correct and loud.
        if isRunning {
            Log.audio.error("capture started while already running — stopping the previous tap first")
            stop()
        }

        self.preferredDeviceUID = preferredDeviceUID
        self.onBuffer = onBuffer
        self.onLevel = onLevel
        self.onReady = onReady
        self.outputFormat = outputFormat
        hasDeliveredAudio = false

        // Retried, because the first attempt on a Bluetooth microphone is expected to fail.
        //
        // A tap has to be installed against the format the bus is carrying, and `installTap`
        // resolves that at the moment it is called — `nil` means "read it now", not "read it
        // later". But asking AirPods for their microphone is what moves them onto the
        // hands-free profile, and that happens inside `engine.start()`, one line further
        // down. So the tap is pinned to the 48kHz the device was serving as a speaker, the
        // hardware becomes a 24kHz headset underneath it, and the graph refuses to
        // initialize:
        //
        //     Error, formats don't match! Input HW format: 24000 Hz, tap format: 48000 Hz
        //     AVAudioEngine could not initialize, error = -10868
        //
        // There is no ordering that avoids this, because the switch is caused by the very
        // call that has to come after the tap. What there is, is a second attempt: by the
        // time the first one fails the device has already become what it was going to be, so
        // re-reading the format and installing again converges. The delays cover a headset
        // that takes its time about the handover.
        var lastError: Error?
        var lastDevice: AudioInputDevice?
        for attempt in 0..<Self.startDelays.count {
            do {
                let device = try bindTap(outputFormat: outputFormat)
                lastDevice = device ?? lastDevice
                try catchingObjC("engine.prepare") { engine.prepare() }
                try engine.start()
                isRunning = true
                observeConfigurationChanges()
                if attempt > 0 {
                    Log.audio.info("capture started on attempt \(attempt + 1, privacy: .public)")
                }
                return device
            } catch {
                lastError = error
                Log.audio.error(
                    "capture start attempt \(attempt + 1, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                try? catchingObjC("removeTap") { engine.inputNode.removeTap(onBus: 0) }
                try? catchingObjC("engine.stop") { engine.stop() }
                try? await Task.sleep(for: .milliseconds(Self.startDelays[attempt]))
            }
        }

        let name = lastDevice?.name
            ?? AudioInputDevice.systemDefault?.name
            ?? "The microphone"
        Log.audio.error(
            "capture would not start on \(name, privacy: .public) after \(Self.startDelays.count, privacy: .public) attempts: \(lastError?.localizedDescription ?? "unknown", privacy: .public)"
        )
        throw TranscriptionError.microphoneUnavailable(name)
    }

    /// How long to wait before each retry. The first is immediate: the format is already
    /// correct the instant the mismatch is reported, and the later ones are for a headset
    /// still negotiating.
    private static let startDelays = [0, 150, 400]

    /// Whether capture is both meant to be running and actually running.
    ///
    /// The two can disagree. `rebind` deliberately leaves `isRunning` true after a failure so
    /// a later attempt can succeed, which means "we think we are recording" and "the engine
    /// is turning" are separate facts, and the gap between them is a recording that captures
    /// nothing.
    var isHealthy: Bool {
        isRunning && engine.isRunning
    }

    /// Asks for a rebind from outside, for a caller that has noticed something is wrong.
    func recover() {
        guard isRunning else { return }
        Log.audio.error("capture is not turning — rebinding")
        rebind()
    }

    func stop() {
        guard isRunning else { return }
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        try? catchingObjC("removeTap") { engine.inputNode.removeTap(onBus: 0) }
        try? catchingObjC("engine.stop") { engine.stop() }
        isRunning = false
        converter = nil
        converterInput = nil
        onBuffer = nil
        onLevel = nil
        onReady = nil
        // Belt and braces: `start` clears this too, but leaving a latched flag behind on a
        // stopped capture is the kind of state that only bites once something else goes wrong.
        hasDeliveredAudio = false
        Log.audio.info("capture stopped")
    }

    // MARK: - Device binding

    /// Installs the tap for the current input device.
    ///
    /// Deliberately does **not** call `setDeviceID` on the input node. On macOS 26 the node
    /// is already routed through the system's default-device aggregate, which tracks the
    /// default input on its own — the AUHAL log shows it moving off the built-in mic the
    /// instant AirPods connect, with no help from us. Forcing the node onto the raw
    /// Bluetooth device instead knocks it off that aggregate and triggers a format
    /// renegotiation, and `installTap` then fails outright with "config change pending",
    /// which is a microphone that captures precisely nothing.
    @discardableResult
    private func bindTap(outputFormat: AVAudioFormat) throws -> AudioInputDevice? {
        let input = engine.inputNode

        // Before anything else: on a rebind the old tap is still installed and still bound
        // to hardware that may have just gone away — which is exactly when this raises.
        try? catchingObjC("removeTap") { input.removeTap(onBus: 0) }

        let device = pin(input) ?? AudioInputDevice.systemDefault

        let nativeFormat = input.outputFormat(forBus: 0)
        // A device mid-renegotiation reports a zero-rate format, and a tap installed against
        // one is silently never created. Better to fail loudly here — `rebind` retries, and
        // a genuine failure reaches the user as a message instead of a dead meter.
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw TranscriptionError.noAudioFormat
        }

        // `nil`, not `nativeFormat`, and this is a wedged-app fix rather than a tidy-up.
        //
        // Passing a format we read on the line above is a race against the hardware, and
        // Bluetooth loses it: the headset can change profile in the microseconds between the
        // read and the install, and 24kHz hands-free becomes 48kHz. `installTap` answers a
        // format that does not match the bus by throwing an **Objective-C exception** —
        //
        //     Format mismatch: input hw <1 ch, 48000 Hz>, client format <1 ch, 24000 Hz>
        //
        // — which `try` cannot catch, because it is an NSException and not a Swift error. It
        // unwound straight out of the async task that starts a recording, so the controller
        // was left pinned at `.starting` with the HUD up, the hotkey inert, and no way back
        // short of force-quitting the app.
        //
        // `nil` means "whatever this bus is carrying", resolved inside `installTap` where
        // there is no window to lose. The converter then has to be built from the format the
        // buffers actually arrive in, which is `handle`'s job, and which also means a format
        // that changes mid-recording is now something this survives rather than something it
        // never expected.
        converter = nil
        converterInput = nil
        try catchingObjC("installTap") {
            input.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
                self?.handle(buffer)
            }
        }

        Log.audio.info("""
            capture on \(device?.name ?? "system default", privacy: .public) — \
            node reports \(nativeFormat.sampleRate)Hz, engine wants \(outputFormat.sampleRate)Hz
            """)
        return device
    }

    /// Points the input node at the pinned device, when there is one.
    ///
    /// Only ever called with an explicit preference — see the note above about why the
    /// default case must not go through `setDeviceID`. Failures are not fatal: a pin whose
    /// device is unplugged, or one mid-negotiation, falls back to the default rather than
    /// ending the recording, which is the same trade the rebind path already makes.
    ///
    /// - Returns: the device the node was pinned to, or nil if it stayed on the default.
    private func pin(_ input: AVAudioInputNode) -> AudioInputDevice? {
        guard let preferredDeviceUID else { return nil }
        guard let device = AudioInputDevice.withUID(preferredDeviceUID) else {
            Log.audio.error("pinned input is not connected — falling back to the default")
            return nil
        }

        // Already there: `setDeviceID` posts a configuration change even when the device is
        // unchanged, and the engine answers it by tearing the graph down and rebinding. On a
        // pinned input that fired on every single recording.
        guard input.auAudioUnit.deviceID != device.id else { return device }

        do {
            try input.auAudioUnit.setDeviceID(device.id)
            return device
        } catch {
            let reason = error.localizedDescription
            Log.audio.error("could not pin input to \(device.name, privacy: .public): \(reason, privacy: .public) — falling back to the default")
            return nil
        }
    }

    /// The engine tears its own graph down when the hardware changes underneath it — a
    /// device disconnecting, or the default input switching mid-utterance. Rebinding keeps
    /// the rest of the recording alive instead of ending it in silence the user can't see.
    private func observeConfigurationChanges() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.rebind()
        }
    }

    private func rebind(attempt: Int = 0) {
        guard isRunning, let outputFormat else { return }
        if attempt == 0 { Log.audio.info("audio configuration changed — rebinding input") }
        try? catchingObjC("engine.stop") { engine.stop() }
        do {
            try bindTap(outputFormat: outputFormat)
            try catchingObjC("engine.prepare") { engine.prepare() }
            try engine.start()
            if attempt > 0 { Log.audio.info("rebind succeeded on attempt \(attempt + 1)") }
        } catch {
            // Not fatal, and specifically not `isRunning = false`: a Bluetooth device emits
            // several configuration changes back to back while it settles, and the early
            // ones legitimately fail. Staying "running" is what lets a later attempt succeed.
            Log.audio.error("rebind attempt \(attempt + 1) failed: \(error.localizedDescription)")

            // Retry on our own clock rather than waiting for another notification.
            //
            // The engine posts a configuration change per transition, and the *last* one is
            // the one that has to succeed. Closing an AirPods case ends with a single change
            // to the built-in mic — if the rebind for that one fails because the route is
            // still settling, no further notification is coming and the recording captures
            // nothing for as long as it lasts. Backing off from 150ms covers about five
            // seconds, which is longer than any handover observed here.
            guard attempt < Self.rebindAttempts else {
                Log.audio.error("giving up rebinding after \(attempt + 1) attempts")
                return
            }
            let delay = Self.rebindBackoff * pow(2, Double(attempt))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.rebind(attempt: attempt + 1)
            }
        }
    }

    private static let rebindAttempts = 5
    private static let rebindBackoff: TimeInterval = 0.15

    // MARK: - Audio thread

    private func handle(_ buffer: AVAudioPCMBuffer) {
        // The first buffer is the only honest "the mic is live" signal there is. A
        // Bluetooth device returns from `engine.start()` long before it has finished
        // negotiating a call profile, so start-of-engine would announce readiness during
        // a stretch where nothing is being recorded at all.
        if !hasDeliveredAudio {
            hasDeliveredAudio = true
            onReady?()
        }

        onLevel?(Self.rms(of: buffer))

        guard let outputFormat else { return }

        // Built here, from the format the buffer genuinely arrived in, rather than from one
        // read before the tap was installed. See `bindTap` for why that read is not to be
        // trusted. Rebuilt if the format ever changes under us, which on a Bluetooth device
        // is a thing that happens.
        if converterInput != buffer.format {
            converterInput = buffer.format
            converter = buffer.format == outputFormat
                ? nil
                : AVAudioConverter(from: buffer.format, to: outputFormat)
            Log.audio.info(
                "capturing \(buffer.format.sampleRate)Hz → \(outputFormat.sampleRate)Hz"
            )
        }

        // AVAudioEngine reuses the tap's buffer as soon as this returns, so the engine
        // must never see it directly — copy when no conversion would otherwise allocate.
        guard let converter else {
            if let copy = Self.copy(buffer) {
                onBuffer?(AudioChunk(buffer: copy))
            }
            return
        }

        // Output frame count scales with the sample-rate ratio; round up so we never clip.
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        // The input block runs synchronously inside `convert`, on this thread.
        nonisolated(unsafe) let input = buffer
        let consumed = Latch()
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            guard !consumed.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return input
        }

        if let error {
            Log.audio.error("conversion failed: \(error.localizedDescription)")
            return
        }
        guard status != .error, converted.frameLength > 0 else { return }
        onBuffer?(AudioChunk(buffer: converted))
    }

    /// Deep-copies a tap buffer into storage we own.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }

        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)

        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else if let source = buffer.int32ChannelData, let destination = copy.int32ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else {
            return nil
        }

        return copy
    }

    /// One-shot flag. Only touched from the audio thread inside a synchronous call.
    private final class Latch: @unchecked Sendable {
        private var fired = false
        /// - Returns: the value *before* this call, then latches to `true`.
        func take() -> Bool {
            defer { fired = true }
            return fired
        }
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<count {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()

        // Map roughly -50…0 dBFS onto 0…1 so quiet speech still moves the meter.
        let db = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (db + 50) / 50))
    }
}

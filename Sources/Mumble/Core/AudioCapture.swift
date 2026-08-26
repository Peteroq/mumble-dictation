import AVFoundation
import Foundation

/// Microphone capture with on-the-fly conversion to whatever format the speech engine wants.
///
/// The tap runs on a real-time audio thread, so everything it touches lives behind
/// `nonisolated(unsafe)` and is only ever mutated from that one thread.
final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private nonisolated(unsafe) var converter: AVAudioConverter?
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

    /// - Returns: the device the tap was bound to, or `nil` if CoreAudio had no default input.
    @discardableResult
    func start(
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onReady: @escaping @Sendable () -> Void = {}
    ) throws -> AudioInputDevice? {
        guard !isRunning else { return AudioInputDevice.systemDefault }

        self.onBuffer = onBuffer
        self.onLevel = onLevel
        self.onReady = onReady
        self.outputFormat = outputFormat
        hasDeliveredAudio = false

        let device = try bindTap(outputFormat: outputFormat)
        engine.prepare()
        try engine.start()
        isRunning = true
        observeConfigurationChanges()
        return device
    }

    func stop() {
        guard isRunning else { return }
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        converter = nil
        onBuffer = nil
        onLevel = nil
        onReady = nil
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
        let device = AudioInputDevice.systemDefault

        // Before anything else: on a rebind the old tap is still installed and still bound
        // to hardware that may have just gone away.
        input.removeTap(onBus: 0)

        let nativeFormat = input.outputFormat(forBus: 0)
        // A device mid-renegotiation reports a zero-rate format, and a tap installed against
        // one is silently never created. Better to fail loudly here — `rebind` retries, and
        // a genuine failure reaches the user as a message instead of a dead meter.
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw TranscriptionError.noAudioFormat
        }

        converter = nativeFormat == outputFormat
            ? nil
            : AVAudioConverter(from: nativeFormat, to: outputFormat)

        input.installTap(onBus: 0, bufferSize: 2048, format: nativeFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }

        Log.audio.info("""
            capture on \(device?.name ?? "system default", privacy: .public) — \
            native \(nativeFormat.sampleRate)Hz → engine \(outputFormat.sampleRate)Hz
            """)
        return device
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

    private func rebind() {
        guard isRunning, let outputFormat else { return }
        Log.audio.info("audio configuration changed — rebinding input")
        engine.stop()
        do {
            try bindTap(outputFormat: outputFormat)
            engine.prepare()
            try engine.start()
        } catch {
            // Not fatal, and specifically not `isRunning = false`: a Bluetooth device emits
            // several configuration changes back to back while it settles, and the early
            // ones legitimately fail. Staying "running" is what lets the next notification
            // rebind successfully; if none ever does, the controller's liveness timeout is
            // what turns the silence into a message.
            Log.audio.error("rebind failed: \(error.localizedDescription)")
        }
    }

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

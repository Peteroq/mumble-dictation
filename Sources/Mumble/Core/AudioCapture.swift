import AVFoundation
import CoreAudio
import Foundation
import MumbleObjC

/// Microphone capture, straight off the device, converted to whatever the speech engine wants.
///
/// This was built on `AVAudioEngine` until a week of failures established that it could not
/// be. Five separate faults, every one of them the engine's:
///
///   1. Its input node caches the format it last resolved and goes on reporting it after the
///      hardware has moved. Measured: a node insisting on 48kHz across three consecutive
///      attempts while CoreAudio said 24kHz and the graph refused the mismatch (-10868).
///   2. `installTap` answers a format that no longer matches its bus by raising an
///      Objective-C exception, which `try` cannot catch and which unwinds out of whatever
///      async task made the call, taking that task's own error handling with it.
///   3. Tearing an engine down while its Bluetooth device renegotiates blocks inside the
///      engine's own lock. Sampled mid-recording, every sample sat in
///      `-[AVAudioEngine inputNode]` on a `std::recursive_mutex` that never released.
///   4. Apple documents that a change to the input *or output* hardware's sample rate or
///      channel count makes the engine "stop, uninitialize itself, and issue this
///      notification" — and an AirPods handover is exactly such a change. It tears down
///      mid-recording by design, and clears audio scheduled on it while its completion
///      handlers report success.
///   5. Merely reading `outputNode` — no start, no tap — makes CoreAudio build a hidden
///      `CADefaultDeviceAggregate` fusing the default input and output devices. Reproduced on
///      macOS 27.0. The engine is not route-neutral even when idle.
///
/// An `AudioDeviceIOProc` has none of them. The format is read from the device, so there is
/// nothing in between holding a stale one. There is no tap to install and nothing that
/// raises. Changes arrive as property callbacks this code decides what to do about, rather
/// than as a teardown already performed on its behalf. And nothing is fused with anything.
///
/// The IOProc runs on a real-time audio thread, so what it touches lives behind
/// `nonisolated(unsafe)` and is mutated only from that thread or under `state`.
final class AudioCapture: @unchecked Sendable {
    /// Every control operation runs here, and never on the caller's thread.
    ///
    /// Starting, stopping and rebinding all talk to CoreAudio, and CoreAudio calls block for
    /// as long as the hardware takes. Doing that on the main actor is not merely a frozen
    /// window: every safeguard in this app — the liveness timer, the startup watchdog, the
    /// stall watchdog, the supervisor — is a task on the main actor, so blocking it switches
    /// off the machinery whose whole job is to notice that a recording has stopped making
    /// progress. A safeguard that shares a thread with the thing it guards is not a safeguard.
    private let control = DispatchQueue(label: "ai.pivotstudio.mumble.capture-control")

    private let state = NSLock()

    // Guarded by `state`.
    private var deviceID: AudioDeviceID?
    private var procID: AudioDeviceIOProcID?
    private var isRunning = false
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var boundDevice: AudioInputDevice?
    private var preferredDeviceUID: String?

    /// Touched only on the audio thread, once the IOProc is running.
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private nonisolated(unsafe) var inputFormat: AVAudioFormat?
    private nonisolated(unsafe) var outputFormat: AVAudioFormat?
    private nonisolated(unsafe) var onBuffer: (@Sendable (AudioChunk) -> Void)?
    private nonisolated(unsafe) var onLevel: (@Sendable (Float) -> Void)?
    private nonisolated(unsafe) var onReady: (@Sendable () -> Void)?
    /// Latches, so a mid-recording device swap doesn't re-announce the mic as newly live.
    private nonisolated(unsafe) var hasDeliveredAudio = false

    // MARK: - Starting

    /// - Returns: the device capture bound to, or `nil` if CoreAudio had no input at all.
    @discardableResult
    func start(
        outputFormat: AVAudioFormat,
        preferredDeviceUID: String? = nil,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onReady: @escaping @Sendable () -> Void = {}
    ) async throws -> AudioInputDevice? {
        try await withCheckedThrowingContinuation { continuation in
            control.async {
                do {
                    continuation.resume(returning: try self.startOnControlQueue(
                        outputFormat: outputFormat,
                        preferredDeviceUID: preferredDeviceUID,
                        onBuffer: onBuffer,
                        onLevel: onLevel,
                        onReady: onReady
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func startOnControlQueue(
        outputFormat: AVAudioFormat,
        preferredDeviceUID: String?,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onReady: @escaping @Sendable () -> Void
    ) throws -> AudioInputDevice? {
        if isRunningNow {
            Log.audio.error("capture started while already running — stopping the previous one first")
            teardown()
        }

        self.outputFormat = outputFormat
        self.onBuffer = onBuffer
        self.onLevel = onLevel
        self.onReady = onReady
        self.hasDeliveredAudio = false
        state.lock()
        self.preferredDeviceUID = preferredDeviceUID
        state.unlock()

        let device = try bind()
        observeDeviceChanges()
        return device
    }

    /// Resolves the device, reads its format, and starts an IOProc on it.
    ///
    /// There is no retry loop here, and that absence is the point. The engine version needed
    /// three attempts because it was racing its own cached format; the format here comes from
    /// the device on the line above, so there is no race to lose.
    @discardableResult
    private func bind() throws -> AudioInputDevice? {
        guard let wanted = outputFormat else { throw TranscriptionError.noAudioFormat }

        let pinned: AudioInputDevice? = {
            state.lock()
            let uid = preferredDeviceUID
            state.unlock()
            guard let uid else { return nil }
            guard let device = AudioInputDevice.withUID(uid) else {
                Log.audio.error("pinned input is not connected — following the default instead")
                return nil
            }
            return device
        }()

        guard let device = pinned ?? AudioInputDevice.systemDefault else {
            throw TranscriptionError.microphoneUnavailable("No microphone")
        }
        guard let format = AudioInputDevice.inputFormat(of: device.id) else {
            throw TranscriptionError.microphoneUnavailable(device.name)
        }

        inputFormat = format
        converter = format == wanted ? nil : AVAudioConverter(from: format, to: wanted)

        var newProc: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&newProc, device.id, nil) {
            [weak self] _, input, _, _, _ in
            self?.handle(input)
        }
        guard created == noErr, let newProc else {
            Log.audio.error("no IOProc on \(device.name, privacy: .public) (OSStatus \(created, privacy: .public))")
            throw TranscriptionError.microphoneUnavailable(device.name)
        }

        let started = AudioDeviceStart(device.id, newProc)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(device.id, newProc)
            Log.audio.error("could not start \(device.name, privacy: .public) (OSStatus \(started, privacy: .public))")
            throw TranscriptionError.microphoneUnavailable(device.name)
        }

        state.lock()
        deviceID = device.id
        procID = newProc
        boundDevice = device
        isRunning = true
        state.unlock()

        Log.audio.info("""
            capture on \(device.name, privacy: .public) — \
            \(format.sampleRate, privacy: .public)Hz \(format.channelCount, privacy: .public)ch \
            → \(wanted.sampleRate, privacy: .public)Hz
            """)
        return device
    }

    // MARK: - Stopping

    func stop() {
        // The flag drops synchronously, so a caller that stops and immediately starts again
        // sees a stopped capture. The CoreAudio calls, which block, go to the queue.
        state.lock()
        let wasRunning = isRunning
        isRunning = false
        state.unlock()
        guard wasRunning else { return }

        onBuffer = nil
        onLevel = nil
        onReady = nil
        control.async { [weak self] in
            self?.teardown()
            Log.audio.info("capture stopped")
        }
    }

    /// Stops the IOProc and unregisters everything. Safe when nothing is running.
    private func teardown() {
        removeListeners()

        state.lock()
        let device = deviceID
        let proc = procID
        deviceID = nil
        procID = nil
        boundDevice = nil
        isRunning = false
        state.unlock()

        if let device, let proc {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
        }
        converter = nil
        inputFormat = nil
        hasDeliveredAudio = false
    }

    // MARK: - Health

    private var isRunningNow: Bool {
        state.lock()
        defer { state.unlock() }
        return isRunning
    }

    /// Whether capture is both meant to be running and able to be.
    var isHealthy: Bool {
        state.lock()
        let running = isRunning
        let device = deviceID
        state.unlock()
        guard running, let device else { return false }
        return AudioInputDevice.isAlive(device)
    }

    /// The device capture is actually bound to, for the interface to name.
    var currentDevice: AudioInputDevice? {
        state.lock()
        defer { state.unlock() }
        return boundDevice
    }

    /// Asked for from outside, by a caller that has noticed something is wrong.
    func recover() {
        guard isRunningNow else { return }
        Log.audio.error("capture is not turning — rebinding")
        control.async { [weak self] in self?.rebind() }
    }

    // MARK: - Device changes

    /// Watches the three things that can invalidate a running capture.
    ///
    /// The engine used to hand us a single notification meaning "something changed, and by the
    /// way I have already torn myself down". These are narrower and, more usefully, arrive
    /// *before* anything has been decided on our behalf: the format moving under us — which is
    /// what an AirPods handover is — the device going away, and the system default moving
    /// while we are following it.
    private func observeDeviceChanges() {
        state.lock()
        let device = deviceID
        let following = preferredDeviceUID == nil
        state.unlock()
        guard let device else { return }

        listen(on: device, selector: kAudioDevicePropertyStreamFormat, scope: kAudioDevicePropertyScopeInput) {
            [weak self] in
            Log.audio.info("input format changed underneath the recording — rebinding")
            self?.rebind()
        }
        listen(on: device, selector: kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeGlobal) {
            [weak self] in
            Log.audio.error("the capture device went away — rebinding")
            self?.rebind()
        }
        if following {
            listen(
                on: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDefaultInputDevice,
                scope: kAudioObjectPropertyScopeGlobal
            ) { [weak self] in
                Log.audio.info("the default input changed — rebinding")
                self?.rebind()
            }
        }
    }

    private func listen(
        on object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        onChange: @escaping @Sendable () -> Void
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        // Delivered on the control queue, which is where the response has to run anyway.
        guard AudioObjectAddPropertyListenerBlock(object, &address, control, block) == noErr else {
            Log.audio.error("could not watch property \(selector, privacy: .public)")
            return
        }
        state.lock()
        listeners.append((object, address, block))
        state.unlock()
    }

    private func removeListeners() {
        state.lock()
        let current = listeners
        listeners.removeAll()
        state.unlock()

        for (object, address, block) in current {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, control, block)
        }
    }

    /// Rebuilds capture on whatever the right device now is.
    ///
    /// Always on the control queue — every caller either is that queue, being a property
    /// listener, or hops onto it. Failures are not fatal and specifically do not clear the
    /// running flag: a Bluetooth device emits several changes back to back while it settles
    /// and the early ones legitimately fail, so staying "running" is what lets a later attempt
    /// succeed. If none ever does, the controller's stall watchdog ends the recording rather
    /// than leaving it hung.
    private func rebind(attempt: Int = 0) {
        guard isRunningNow, outputFormat != nil else { return }

        removeListeners()
        state.lock()
        let device = deviceID
        let proc = procID
        deviceID = nil
        procID = nil
        state.unlock()
        if let device, let proc {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
        }

        do {
            try bind()
            observeDeviceChanges()
            if attempt > 0 {
                Log.audio.info("rebind succeeded on attempt \(attempt + 1, privacy: .public)")
            }
        } catch {
            Log.audio.error(
                "rebind attempt \(attempt + 1, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            guard attempt < Self.rebindAttempts else {
                Log.audio.error("giving up rebinding after \(attempt + 1, privacy: .public) attempts")
                return
            }
            // On our own clock rather than waiting for another notification: a handover ends
            // with a single change to the new device, and if the rebind for that one loses a
            // race with the route settling, nothing further is coming.
            let delay = Self.rebindBackoff * pow(2, Double(attempt))
            control.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.rebind(attempt: attempt + 1)
            }
        }
    }

    private static let rebindAttempts = 5
    private static let rebindBackoff: TimeInterval = 0.15

    // MARK: - Audio thread

    private func handle(_ input: UnsafePointer<AudioBufferList>) {
        guard let inputFormat, let outputFormat else { return }

        // A device that has just been started delivers empty lists before it has anything to
        // say. That is not the microphone going live, and counting it as such is what would
        // put the ready chime in front of the silence rather than in front of the audio.
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard buffers.count > 0, buffers[0].mDataByteSize > 0 else { return }

        // Guarded, because this is the one call left in the audio path that can raise.
        //
        // `bufferListNoCopy` validates the list against the format it is handed and raises an
        // Objective-C exception when they disagree. That disagreement is precisely what a
        // device changing format under a running IOProc looks like, in the window between the
        // hardware moving and the property listener rebinding — and a raise on a real-time
        // audio thread would take the process, not just the recording.
        var wrapped: AVAudioPCMBuffer?
        var raised: NSError?
        let ok = MumbleRunCatchingException({
            wrapped = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: input, deallocator: nil)
        }, &raised)
        guard ok else {
            // Not logged per buffer: at 48kHz this would be a hundred lines a second. The
            // rebind that follows the format change is what fixes it, and that logs.
            return
        }
        guard let wrapped, wrapped.frameLength > 0 else { return }

        // The first real buffer is the only honest "the mic is live" signal there is. A
        // Bluetooth device returns from `AudioDeviceStart` long before it has finished
        // negotiating a call profile.
        if !hasDeliveredAudio {
            hasDeliveredAudio = true
            onReady?()
        }

        onLevel?(Self.rms(of: wrapped))

        // The IOProc's memory belongs to CoreAudio and is gone the moment this returns, so
        // the engine must never be handed it directly.
        guard let converter else {
            if let copy = Self.copy(wrapped) { onBuffer?(AudioChunk(buffer: copy)) }
            return
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(wrapped.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }

        let consumed = Latch()
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            guard !consumed.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return wrapped
        }

        if let error {
            Log.audio.error("conversion failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard status != .error, converted.frameLength > 0 else { return }
        onBuffer?(AudioChunk(buffer: converted))
    }

    /// Deep-copies a buffer into storage we own.
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

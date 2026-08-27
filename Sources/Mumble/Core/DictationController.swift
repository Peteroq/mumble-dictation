import MumbleDictionary
import AVFoundation
import AppKit
import Foundation
import Observation

/// Builds the engine named by the current setting.
///
/// Deliberately at file scope rather than a static on `DictationController`: the class is
/// `@MainActor`, which would make a static method main-actor-isolated and therefore
/// ineligible to be `@Sendable`. Reading the setting per-utterance is what lets the menu's
/// engine picker take effect on the very next hold instead of needing a restart.
@Sendable
func engineForCurrentSetting() -> any TranscriptionEngine {
    // Always invoked from `beginDictation`, which runs on the main actor.
    MainActor.assumeIsolated {
        switch Settings.shared.engine {
        case .apple: AppleSpeechEngine()
        case .parakeet: ParakeetEngine()
        }
    }
}

@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        case idle
        /// Engine and capture are spinning up.
        case starting
        /// Capture has started but the device has not delivered a sample yet. Split out
        /// from `starting` because on a Bluetooth mic this is where the whole wait lives,
        /// and a state the user can be told about is better than a stall they can't explain.
        case connecting
        case listening
        case finishing
        case error(String)

        /// Whether a recording is under way. Governs the record button, the level meter and
        /// the elapsed counter — everything that should stay lit until the utterance is
        /// genuinely done with.
        var isActive: Bool {
            switch self {
            case .starting, .connecting, .listening, .finishing: true
            case .idle, .error: false
            }
        }

        /// Whether the HUD should be on screen. Deliberately not the same set.
        ///
        /// `finishing` is excluded: the key is already up by then, and keeping the band around
        /// while the engine finalises means the HUD outlives the gesture that summoned it. It
        /// closes on release instead, and the text lands in the app either way.
        ///
        /// `error` is included, which `isActive` is not — the HUD has a case for rendering the
        /// message and it was never being shown one.
        var showsHUD: Bool {
            switch self {
            case .starting, .connecting, .listening, .error: true
            case .idle, .finishing: false
            }
        }
    }

    private(set) var state: State = .idle
    /// Live transcript, updated as the engine revises it. Drives the HUD.
    private(set) var transcript = ""
    /// Smoothed 0…1 mic level for the waveform.
    private(set) var level: Float = 0

    /// The input device the next recording will use. Follows the system default, so it
    /// updates the moment AirPods connect rather than at the next launch.
    private(set) var inputDevice: AudioInputDevice? = AudioInputDevice.systemDefault

    private let hotkey = HotkeyMonitor()

    /// Whether the mic is open because the key was tapped twice rather than because it is
    /// being held. Read by the HUD, which has to say so: with nothing held there is no
    /// gesture in progress to remind you the mic is live.
    private(set) var isHandsFree = false
    private let capture = AudioCapture()
    private let inputObserver = AudioInputObserver()

    /// Fires the connecting cue if the device is still waking up past the grace window.
    private var connectingTask: Task<Void, Never>?
    /// Gives up on a device that accepted `start` and then delivered nothing.
    private var livenessTask: Task<Void, Never>?
    private let makeEngine: @Sendable () -> any TranscriptionEngine

    /// Injected only by tests; production reads the setting per-utterance below.
    private let formatter: (any TextFormatter)?

    /// Chosen per-utterance so the menu toggle applies to the very next hold.
    private func makeFormatter() -> any TextFormatter {
        if let formatter { return formatter }
        let strength = Settings.shared.cleanupStrength
        switch Settings.shared.cleanupTier {
        case .rules: return RuleBasedFormatter(strength: strength)
        case .onDevice: return FoundationModelFormatter(strength: strength)
        case .claude: return ClaudeFormatter(strength: strength)
        }
    }

    /// Built at key-down and held for the whole utterance so the instance we prewarmed is
    /// the same one that formats. Rebuilding it at release would throw away the warm
    /// session and put the cold-start back in the path the user waits on.
    private var utteranceFormatter: (any TextFormatter)?

    private var engine: (any TranscriptionEngine)?
    private var consumeTask: Task<Void, Never>?
    /// Returns the ordered recording when compare mode is on, empty otherwise.
    private var feedTask: Task<[AudioChunk], Never>?
    private var audioContinuation: AsyncStream<AudioChunk>.Continuation?

    /// Timestamps for the dashboard: when the key went down, and when it came up.
    private var holdStarted: Date?
    private var releasedAt: Date?
    private var engineName = ""

    /// Compare mode only: the recording, kept so every engine sees identical audio.
    private var recorded: [AudioChunk] = []
    private var isComparing = false

    init(
        formatter: (any TextFormatter)? = nil,
        makeEngine: @escaping @Sendable () -> any TranscriptionEngine = engineForCurrentSetting
    ) {
        self.formatter = formatter
        self.makeEngine = makeEngine
    }

    /// Re-reads the input preference, so the transport names the right device the moment it
    /// is picked rather than after the next recording.
    func reloadInputDevice() {
        inputDevice = Settings.shared.inputDeviceUID.flatMap(AudioInputDevice.withUID)
            ?? AudioInputDevice.systemDefault
    }

    // MARK: - Lifecycle

    /// - Returns: `false` if the hotkey tap couldn't be installed (missing Accessibility).
    @discardableResult
    func activate() -> Bool {
        inputObserver.start { [weak self] device in
            guard let self else { return }
            // When the input is pinned, the default moving is not news the transport should
            // report — the whole point of the pin is that a call taking the headset doesn't
            // change what Mumble records from.
            let current = Settings.shared.inputDeviceUID.flatMap(AudioInputDevice.withUID) ?? device
            guard current != inputDevice else { return }
            inputDevice = current
            Log.audio.info("input is now \(current?.name ?? "none", privacy: .public)")
        }
        // Rendering both cues costs a few milliseconds of arithmetic; paying it here keeps
        // it out of the gap between key-down and the first word.
        Feedback.prewarm()

        hotkey.key = Settings.shared.pushToTalkKey
        hotkey.onPress = { [weak self] in self?.beginDictation() }
        hotkey.onRelease = { [weak self] in self?.endDictation() }
        // Only claims hands-free if there is actually a recording to hold open: a double tap
        // that began on a failed start would otherwise leave the flag set with nothing live.
        hotkey.onLatch = { [weak self] in
            guard let self, state.isActive else { return }
            isHandsFree = true
        }
        hotkey.onUnlatch = { [weak self] in self?.endDictation() }
        return hotkey.start()
    }

    func deactivate() {
        inputObserver.stop()
        hotkey.stop()
        cancelDictation()
    }

    /// Re-arms the tap after the user picks a different push-to-talk key.
    @discardableResult
    func reloadHotkey() -> Bool {
        hotkey.stop()
        return activate()
    }

    // MARK: - Button-driven recording

    /// Starts a recording from a Record button rather than the hotkey.
    ///
    /// Wispr Flow's hotkey is held down for the duration **only in compare mode**. Reaching
    /// into another app is a comparison affordance; during ordinary dictation it would mean
    /// every recording silently shipped your audio to a third party's servers.
    func startButtonRecording() {
        guard case .idle = state else { return }
        if Settings.shared.compareMode { WisprTrigger.press() }
        beginDictation()
    }

    /// Releases Wispr's hotkey first, so its upload starts while our own engines are still
    /// finishing — otherwise every run would wait the full round trip end to end.
    func stopButtonRecording() {
        WisprTrigger.release()
        endDictation()
    }

    // MARK: - Dictation

    private func beginDictation() {
        guard case .idle = state else { return }
        state = .starting
        isHandsFree = false
        transcript = ""
        holdStarted = Date()
        isComparing = Settings.shared.compareMode
        recorded.removeAll(keepingCapacity: true)
        engineName = isComparing ? "Comparing…" : Settings.shared.engine.displayName

        // Warm the cleanup model now, against the hold. A model-backed formatter costs
        // ~2.6s cold and ~1.0s warm, and every millisecond of that is currently spent
        // after the key comes up, where it is the only delay the user can feel.
        let formatter = makeFormatter()
        utteranceFormatter = formatter
        formatter.prewarm()

        Task { @MainActor in
            do {
                guard await Permissions.requestMicrophone() else {
                    fail("Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone.")
                    return
                }

                let engine = makeEngine()
                self.engine = engine

                let chunks = try await engine.start()

                // Compare mode captures in *Apple's* format, not a format of our choosing.
                //
                // SpeechAnalyzer enforces `Audio sample data must be 16-bit signed integers`
                // as a hard precondition — feeding it float32 doesn't fail gracefully, it
                // kills the process. Parakeet is the flexible one (its `feed` converts
                // int16/int32/float32), so the strict engine picks the format and the
                // tolerant engine adapts. Both still replay the identical buffers.
                let formatOwner: any TranscriptionEngine = isComparing ? AppleSpeechEngine() : engine
                guard let format = await formatOwner.preferredInputFormat() else {
                    throw TranscriptionError.noAudioFormat
                }

                // Audio must reach the engine in capture order. A stream plus a single
                // draining task guarantees that; spawning a Task per buffer would not.
                let (audioStream, audioContinuation) = AsyncStream<AudioChunk>.makeStream(
                    bufferingPolicy: .bufferingNewest(64)
                )
                self.audioContinuation = audioContinuation

                // The recording is accumulated *inside* the ordered drain, not by spawning
                // a task per buffer. Unstructured tasks have no ordering guarantee, so
                // collecting them separately could assemble the replay audio out of order
                // and silently produce word-salad from the comparison.
                let comparing = isComparing
                self.feedTask = Task.detached(priority: .userInitiated) {
                    var recording: [AudioChunk] = []
                    for await chunk in audioStream {
                        if comparing { recording.append(chunk) }
                        await engine.feed(chunk)
                    }
                    return recording
                }

                let device = try capture.start(
                    outputFormat: format,
                    preferredDeviceUID: Settings.shared.inputDeviceUID,
                    onBuffer: { chunk in
                        audioContinuation.yield(chunk)
                    },
                    onLevel: { [weak self] level in
                        Task { @MainActor in self?.updateLevel(level) }
                    },
                    onReady: { [weak self] in
                        Task { @MainActor in self?.audioBecameLive() }
                    }
                )
                self.inputDevice = device ?? self.inputDevice

                // Bail out if the user already let go while we were spinning up.
                guard case .starting = self.state else {
                    await self.teardown()
                    return
                }

                // `.listening` is deliberately *not* set here. The engine is running, but a
                // wireless mic can be several hundred milliseconds away from producing a
                // sample, and calling that "listening" tells the user to start talking into
                // audio nobody is recording. `audioBecameLive` promotes the state when the
                // first buffer actually lands.
                self.armConnectionFeedback()

                self.consumeTask = Task { @MainActor in
                    do {
                        for try await chunk in chunks {
                            self.transcript = chunk.text
                        }
                    } catch {
                        self.fail(error.localizedDescription)
                    }
                }
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    /// Waits out a grace window before admitting the mic isn't ready yet.
    ///
    /// The built-in mic delivers its first buffer within a buffer period, so on that path
    /// this task is cancelled before it ever speaks and the user hears the ready chime
    /// alone. The whoosh only exists to cover a wait long enough to notice.
    private func armConnectionFeedback() {
        connectingTask?.cancel()
        connectingTask = Task { @MainActor in
            // 180ms, not 100. A 2048-frame buffer at 48kHz is already ~43ms, and the
            // built-in mic occasionally takes a couple of those to get going — firing under
            // that would put a whoosh in front of every recording, which is exactly the
            // noise this is supposed to avoid. AirPods take several hundred milliseconds,
            // so the gap between the two cases is wide enough to be safe at this threshold.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, case .starting = state else { return }
            state = .connecting
            if Settings.shared.soundEnabled { Feedback.connecting.play() }
        }

        livenessTask?.cancel()
        livenessTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            switch state {
            case .starting, .connecting:
                // Five seconds without a single sample is not a slow handshake, it's a
                // device that isn't going to work. Say which one, since the whole point of
                // following the system default is that it may not be the one the user
                // expects.
                fail("\(inputDevice?.name ?? "The microphone") isn't sending any audio. Pick a different input in Settings ▸ Microphone.")
            default:
                break
            }
        }
    }

    /// First real buffer from the device. This — not `engine.start()` returning — is the
    /// moment it's honest to tell the user to talk.
    private func audioBecameLive() {
        connectingTask?.cancel()
        connectingTask = nil
        livenessTask?.cancel()
        livenessTask = nil

        // The user may have released, or the run may have failed, during the handshake.
        switch state {
        case .starting, .connecting: break
        default: return
        }

        state = .listening
        if Settings.shared.soundEnabled { Feedback.ready.play() }
    }

    /// Stops both timers. Every path out of a recording goes through this, or the liveness
    /// timer fires an error over a run that already finished.
    private func cancelConnectionFeedback() {
        connectingTask?.cancel()
        connectingTask = nil
        livenessTask?.cancel()
        livenessTask = nil
    }

    private func endDictation() {
        // `.finishing` is "active", so without this a second press during processing would
        // run the whole tail again — re-reading `transcript` before the first pass cleared
        // it and pasting the same utterance twice. The window is wide: Parakeet transcribes
        // inside `finish()`, and smart cleanup adds up to 4s on top.
        guard state.isActive, state != .finishing else { return }
        cancelConnectionFeedback()
        isHandsFree = false
        state = .finishing
        capture.stop()
        level = 0
        releasedAt = Date()

        Task { @MainActor in
            // Drain every captured buffer into the engine before asking it to finalize,
            // or the tail of the utterance gets dropped.
            audioContinuation?.finish()
            audioContinuation = nil
            recorded = await feedTask?.value ?? []
            feedTask = nil

            // Bounded, because these two awaits are the only thing standing between a
            // wedged engine and a HUD stuck on "Transcribing…" that nothing but quitting
            // the app can clear.
            await bounded(6, "engine finish") { [engine] in await engine?.finish() }
            await bounded(3, "transcript drain") { [consumeTask] in await consumeTask?.value }
            consumeTask = nil
            engine = nil

            if isComparing {
                utteranceFormatter = nil
                await runComparison()
                return
            }

            let raw = transcript
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                state = .idle
                transcript = ""
                utteranceFormatter = nil
                return
            }

            let cleaned = Settings.shared.cleanupEnabled
                ? await (utteranceFormatter ?? makeFormatter()).format(raw)
                : raw

            // The dictionary runs last, and runs regardless of the cleanup setting. Biasing
            // only raises the odds of the right word; this is the pass that guarantees it,
            // so it must not be something the user can accidentally switch off.
            let (output, corrections) = DictionaryStore.shared.corrector.apply(to: cleaned)
            if !corrections.isEmpty {
                Log.speech.info("dictionary · \(corrections.count, privacy: .public) correction(s) applied")
            }

            recordRun(text: output, corrections: corrections)
            TextInjector.insert(output)
            if Settings.shared.soundEnabled { NSSound(named: "Pop")?.play() }

            state = .idle
            transcript = ""
            utteranceFormatter = nil
        }
    }

    private func cancelDictation() {
        cancelConnectionFeedback()
        utteranceFormatter = nil
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        consumeTask?.cancel()
        consumeTask = nil

        let engine = self.engine
        self.engine = nil
        Task { await engine?.finish() }

        state = .idle
        transcript = ""
        level = 0
    }

    private func teardown() async {
        cancelConnectionFeedback()
        utteranceFormatter = nil
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        await feedTask?.value
        feedTask = nil
        await engine?.finish()
        engine = nil
        consumeTask?.cancel()
        consumeTask = nil
        state = .idle
    }

    // MARK: - Helpers

    private func retainForComparison(_ chunk: AudioChunk) {
        guard isComparing else { return }
        recorded.append(chunk)
    }

    /// Replays the recording through every engine and files the results as one group.
    ///
    /// Nothing is injected in this mode — the point is to read the outputs side by side,
    /// and typing one of them into whatever had focus would be a surprise.
    private func runComparison() async {
        let chunks = recorded
        recorded.removeAll(keepingCapacity: false)

        guard !chunks.isEmpty, let holdStarted, let releasedAt else {
            state = .idle
            transcript = ""
            return
        }

        transcript = "Running both engines…"

        let group = UUID().uuidString
        let held = releasedAt.timeIntervalSince(holdStarted)

        // Filed one at a time as each engine finishes, so the window fills in progressively
        // rather than snapping both rows into place at the end.
        let results = await EngineComparison.run(chunks: chunks) { result in
            RunLog.record(
                DictationRun(
                    date: releasedAt,
                    engine: result.engine,
                    audioSeconds: held,
                    processSeconds: result.seconds,
                    text: result.text,
                    group: group
                )
            )
        }

        for result in results {
            Log.speech.info("""
                compare · \(result.engine, privacy: .public): \
                \(result.seconds, format: .fixed(precision: 2))s — \
                \(result.text, privacy: .public)
                """)
        }

        // Wispr Flow, if its hotkey was held for this same utterance. It transcribes in the
        // cloud, so its row lands after both local engines have already finished — the wait
        // happens here rather than blocking the rows above from appearing.
        if WisprReader.isInstalled {
            transcript = "Waiting for Wispr Flow…"
            if let wispr = await WisprReader.result(after: holdStarted, timeout: 8) {
                RunLog.record(
                    DictationRun(
                        date: releasedAt,
                        engine: wispr.engine,
                        audioSeconds: held,
                        processSeconds: wispr.seconds,
                        text: wispr.text,
                        group: group
                    )
                )
                Log.speech.info("""
                    compare · \(wispr.engine, privacy: .public): \
                    \(wispr.seconds, format: .fixed(precision: 2))s — \
                    \(wispr.text, privacy: .public)
                    """)
            } else {
                Log.speech.info("compare · Wispr Flow: no result (hotkey not held, or timed out)")
            }
        }

        self.holdStarted = nil
        self.releasedAt = nil
        isComparing = false
        state = .idle
        transcript = ""

        if Settings.shared.soundEnabled { NSSound(named: "Glass")?.play() }
    }

    /// Files the finished utterance for the dashboard.
    ///
    /// `processSeconds` is measured from key release, not from capture start — that's the
    /// wait the user actually experiences, and it's the only number on which a streaming
    /// engine and a batch engine can be compared honestly.
    private func recordRun(text: String, corrections: [AppliedCorrection] = []) {
        guard let holdStarted, let releasedAt else { return }
        RunLog.record(
            DictationRun(
                date: releasedAt,
                engine: engineName,
                audioSeconds: releasedAt.timeIntervalSince(holdStarted),
                processSeconds: Date().timeIntervalSince(releasedAt),
                text: text,
                corrections: corrections.isEmpty ? nil : corrections
            )
        )
        self.holdStarted = nil
        self.releasedAt = nil
    }

    /// Runs `work`, giving up after `seconds` and carrying on without it.
    ///
    /// A backstop, not a design — every engine is supposed to return from `finish()`. It
    /// exists because one of them didn't: handed a session that never received a single
    /// audio buffer, `SpeechAnalyzer.finalizeAndFinishThroughEndOfInput()` waits forever,
    /// and the whole app strands mid-utterance. That specific case is fixed at the source,
    /// but the cost of being wrong here is the user losing the app entirely, which is far
    /// too high to leave resting on a framework's liveness.
    ///
    /// On timeout the work is **abandoned**, not cancelled. Cancelling would not help — the
    /// hang is inside a framework call that never checks for it — and awaiting the task to
    /// observe the cancellation is precisely the thing that cannot be done here. A leaked
    /// task that eventually returns into nothing is the cheap outcome.
    @discardableResult
    private func bounded(
        _ seconds: Double,
        _ label: String,
        _ work: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let completed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            Task.detached(priority: .userInitiated) {
                await work()
                once.resume(completed: true)
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(seconds))
                once.resume(completed: false)
            }
        }
        if !completed {
            Log.speech.error("\(label, privacy: .public) timed out after \(seconds)s — abandoned")
        }
        return completed
    }

    /// Resumes a continuation exactly once, whichever racer gets there first.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func resume(completed: Bool) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: completed)
        }
    }

    /// Smoothing so the orb glides instead of strobing at buffer rate.
    ///
    /// Asymmetric on purpose: rise almost immediately, fall back gently. Meter ballistics work
    /// this way because a symmetric filter averages the peaks away — the level ends up sitting
    /// near the middle of its range the whole time you are talking, which is exactly what made
    /// the orb look like it was idling rather than listening.
    private func updateLevel(_ new: Float) {
        level += (new - level) * (new > level ? 0.62 : 0.16)
    }

    private func fail(_ message: String) {
        cancelConnectionFeedback()
        utteranceFormatter = nil
        Log.app.error("\(message)")
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        engine = nil
        consumeTask?.cancel()
        consumeTask = nil
        state = .error(message)
        level = 0

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if case .error = state { state = .idle }
        }
    }
}

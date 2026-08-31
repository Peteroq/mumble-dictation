import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// The two short cues that bracket the microphone handoff: a rising whoosh while a device
/// is still waking up, and a chime the moment audio is actually flowing.
///
/// Synthesized rather than shipped as files, and deliberately not drawn from
/// `/System/Library/Sounds`: the stock set has no whoosh at all, and these two need to read
/// as a *pair* — the same voice rising, then landing — which means generating both from one
/// set of parameters instead of pinning two unrelated alert blips together and hoping.
@MainActor
enum Feedback: Hashable {
    /// Airy rising sweep. Plays only when a device is slow enough that the wait is felt.
    case connecting
    /// Two-partial bell. Means "the mic is live, talk now".
    case ready

    /// Played through `NSSound`, not `AVAudioPlayer`, and that is not arbitrary.
    ///
    /// `AVAudioPlayer` was the original choice and it is the wrong one here. It binds itself
    /// to the output as configured when it was prepared, survives a route change as an
    /// object, reports success from `play()`, and produces no sound — which is what "the
    /// chime stopped happening" was for a week. Apple documents the same lying-success for
    /// audio scheduled on an `AVAudioEngine` across a configuration change: completion
    /// handlers fire as though it played.
    ///
    /// `NSSound` is the path the end-of-dictation Pop and Glass already use, and those were
    /// never the ones that went missing.
    func play() {
        let padded = self == .ready && Self.outputIsBluetooth
        guard let sound = NSSound(data: Self.audio(for: self, padded: padded)) else {
            Log.audio.error("cue \(String(describing: self), privacy: .public) could not be built")
            return
        }
        sound.volume = volume
        guard sound.play() else {
            Log.audio.error("cue \(String(describing: self), privacy: .public) refused to play")
            return
        }
        Log.audio.info(
            """
            cue \(String(describing: self), privacy: .public) playing — \
            \(sound.duration, privacy: .public)s at volume \(volume, privacy: .public) \
            on \(Self.outputDevice.name, privacy: .public)\
            \(padded ? " (padded)" : "", privacy: .public)
            """
        )
        Self.retain(sound, for: sound.duration)
    }

    /// Renders both cues up front. They fire on the path between key-down and the first
    /// word, which is the one stretch of this app where a few milliseconds are visible.
    static func prewarm() {
        _ = audio(for: .connecting, padded: false)
        _ = audio(for: .ready, padded: false)
        _ = audio(for: .ready, padded: true)
        _ = silence
    }

    /// Opens the output route at key-down, so the ready chime is not the thing that has to
    /// open it.
    ///
    /// A Bluetooth headset tears its audio link down when nothing is playing, and the first
    /// sound after that silence loses its opening while the link comes back — a few hundred
    /// milliseconds, which is most of a chime that only lasts half a second. It is why the
    /// chime was missing on the first recording and audible on the second: the second one
    /// arrived while the link was still warm from the first.
    ///
    /// Two seconds of near-silence, started when the key goes down, covers the whole
    /// spin-up: the connecting whoosh at 180ms, and the chime whenever the microphone
    /// actually goes live. Inaudible, and on a wired or built-in output it costs nothing but
    /// a stream nobody hears.
    static func wakeOutput() {
        guard let sound = NSSound(data: silence) else { return }
        sound.volume = 1
        guard sound.play() else { return }
        retain(sound, for: sound.duration)
    }

    /// Two seconds of dither, not of zeroes.
    ///
    /// One least-significant bit, alternating. Inaudible at any volume — it is 90dB below a
    /// speaking voice — but it is genuinely a signal, which matters: a stream of exact zeroes
    /// is something a driver or a codec is entitled to notice and skip, and a link that was
    /// never opened is not a link that was woken.
    private static let silence: Data = {
        let count = sampleRate * 2
        var samples = [Float](repeating: 0, count: count)
        let step = 1 / Float(Int16.max)
        for index in 0..<count { samples[index] = index.isMultiple(of: 2) ? step : -step }
        return wav(samples)
    }()

    private struct Rendering: Hashable {
        let cue: Feedback
        let padded: Bool
    }

    /// The rendered bytes are cached; a prepared player is not. Synthesising the waveform is
    /// the part worth doing early, and building the sound at the call site is what keeps it
    /// from binding to an output route that has since changed.
    private static var rendered: [Rendering: Data] = [:]

    /// Three hundred milliseconds of dither in front of the chime, for Bluetooth only.
    ///
    /// A Bluetooth headset rebuilds its audio link when the profile changes, and asking for
    /// its microphone is what changes the profile. Padding moves the loss onto something
    /// there is no cost to losing. Nothing is added on a wired or built-in output.
    private static let leadIn: [Float] = {
        let step = 1 / Float(Int16.max)
        return (0..<(sampleRate * 3 / 10)).map { $0.isMultiple(of: 2) ? step : -step }
    }()

    private static func audio(for cue: Feedback, padded: Bool) -> Data {
        let key = Rendering(cue: cue, padded: padded)
        if let cached = rendered[key] { return cached }
        let data = wav(padded ? leadIn + cue.samples : cue.samples)
        rendered[key] = data
        return data
    }

    // MARK: - Where the sound is going

    /// The current default output, by name and transport.
    ///
    /// Logged with every cue, because "it played" and "it played somewhere you could hear it"
    /// are different claims and only the second one is interesting. It is also how the
    /// decision to pad gets made.
    static var outputDevice: (name: String, isBluetooth: Bool) {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ) == noErr else { return ("unknown", false) }

        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let resolved = AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr
            ? name as String
            : "unknown"

        var transport = UInt32(0)
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport)
        return (resolved, transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE)
    }

    static var outputIsBluetooth: Bool { outputDevice.isBluetooth }

    /// A player released while it is still playing stops mid-note, so each one is held for
    /// as long as it needs and dropped after.
    private static var live: [ObjectIdentifier: NSSound] = [:]

    private static func retain(_ player: NSSound, for duration: TimeInterval) {
        let id = ObjectIdentifier(player)
        live[id] = player
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration + 0.2))
            live[id] = nil
        }
    }

    private var volume: Float {
        switch self {
        // Under the chime on purpose. The whoosh is a "hang on", not an announcement, and
        // at equal level it reads as the more important of the two.
        case .connecting: 0.28
        case .ready: 0.45
        }
    }

    // MARK: - Synthesis

    private static let sampleRate = 44_100

    private var samples: [Float] {
        switch self {
        case .connecting: Feedback.whoosh()
        case .ready: Feedback.chime()
        }
    }

    /// Noise pushed through a band-pass whose centre climbs 400 → 1600 Hz.
    ///
    /// The band-pass is the difference of two one-pole low-passes — cheap, and the gentle
    /// skirts are the point: a steep filter on noise sounds like a synthesizer, a shallow
    /// one sounds like air. It lands just under the chime's fundamental so the pair reads
    /// as one gesture resolving rather than two separate noises.
    private static func whoosh() -> [Float] {
        let duration = 0.42
        let count = Int(duration * Double(sampleRate))
        var samples = [Float](repeating: 0, count: count)

        var noise = Noise()
        var low: Double = 0
        var lower: Double = 0

        for index in 0..<count {
            let t = Double(index) / Double(count)

            // Cutoffs as one-pole coefficients. The upper edge sweeps; the lower edge
            // trails it at a fixed ratio, which keeps the band's width constant in octaves.
            let centre = 400 * pow(1600.0 / 400.0, t)
            let upper = coefficient(forHz: centre * 1.6)
            let bottom = coefficient(forHz: centre / 1.6)

            let input = noise.next()
            low += upper * (input - low)
            lower += bottom * (input - lower)

            // Raised-sine envelope: no click at either end, and the peak sits late enough
            // that the sweep is audible before the level drops away.
            let envelope = pow(sin(Double.pi * t), 1.4)
            samples[index] = Float((low - lower) * envelope * 3.2)
        }
        return samples
    }

    /// A fundamental with its fifth and octave above, all decaying exponentially.
    ///
    /// Partials rather than a single sine: one sine reads as a test tone. The higher the
    /// partial the faster it decays, which is what real struck metal does and what keeps
    /// this from sounding synthetic.
    private static func chime() -> [Float] {
        let duration = 0.55
        let count = Int(duration * Double(sampleRate))
        let partials: [(frequency: Double, amplitude: Double, decay: Double)] = [
            (1046.50, 1.00, 7.0),   // C6
            (1567.98, 0.45, 9.5),   // G6
            (2093.00, 0.18, 13.0),  // C7
        ]

        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let seconds = Double(index) / Double(sampleRate)
            var value = 0.0
            for partial in partials {
                value += sin(2 * .pi * partial.frequency * seconds)
                    * partial.amplitude
                    * exp(-seconds * partial.decay)
            }
            // 4 ms attack. Starting a bell at full amplitude puts a click in front of it.
            let attack = min(1, seconds / 0.004)
            samples[index] = Float(value * attack * 0.32)
        }
        return samples
    }

    /// One-pole low-pass coefficient for a cutoff in Hz.
    private static func coefficient(forHz hz: Double) -> Double {
        let x = exp(-2 * .pi * hz / Double(sampleRate))
        return 1 - x
    }

    /// xorshift32. Deterministic on purpose — the cue should sound identical every time,
    /// and a seeded generator makes it reproducible if the shape ever needs tuning.
    private struct Noise {
        private var state: UInt32 = 0x9E37_79B9

        mutating func next() -> Double {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return Double(state) / Double(UInt32.max) * 2 - 1
        }
    }

    // MARK: - Container

    /// 16-bit mono PCM in a WAV wrapper, so `AVAudioPlayer(data:)` can take it directly
    /// without a temporary file on disk.
    private static func wav(_ samples: [Float]) -> Data {
        let bitsPerSample = 16
        let channels = 1
        let blockAlign = channels * bitsPerSample / 8
        let payload = samples.count * blockAlign

        var data = Data(capacity: 44 + payload)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + payload))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                                   // subchunk size
        append(UInt16(1))                                    // PCM, uncompressed
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * blockAlign))              // byte rate
        append(UInt16(blockAlign))
        append(UInt16(bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(payload))

        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * 32_767))
        }
        return data
    }
}

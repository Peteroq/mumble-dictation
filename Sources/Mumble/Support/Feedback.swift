import AVFoundation
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

    func play() {
        guard let player = Self.player(for: self) else { return }
        // Re-arming the head matters: hold, release, hold again inside half a second is
        // normal use, and a player left at the end of its buffer plays nothing.
        player.currentTime = 0
        player.play()
    }

    /// Renders both cues up front. They fire on the path between key-down and the first
    /// word, which is the one stretch of this app where a few milliseconds are visible.
    static func prewarm() {
        _ = player(for: .connecting)
        _ = player(for: .ready)
    }

    // MARK: - Players

    private static var cache: [Feedback: AVAudioPlayer] = [:]

    private static func player(for cue: Feedback) -> AVAudioPlayer? {
        if let cached = cache[cue] { return cached }
        do {
            let player = try AVAudioPlayer(data: wav(cue.samples))
            player.volume = cue.volume
            player.prepareToPlay()
            cache[cue] = player
            return player
        } catch {
            Log.audio.error("cue \(String(describing: cue), privacy: .public) failed: \(error.localizedDescription)")
            return nil
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

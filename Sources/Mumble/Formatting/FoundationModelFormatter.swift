import MumbleCleanup
import Foundation
import FoundationModels

/// Cleanup via Apple's on-device LLM (macOS 26 Foundation Models).
///
/// This is the pass that separates dictation from *usable* dictation: it removes fillers,
/// restores punctuation and paragraphing, formats spoken lists, and — the thing rules can
/// never do — honors mid-sentence corrections like "make that three, actually".
///
/// Three properties make it safe to put in the hot path:
/// - **On-device.** Nothing leaves the Mac, so it's viable for anything you'd dictate.
/// - **Bounded.** A timeout falls back to `RuleBasedFormatter`, because a stalled model
///   must never cost you an utterance you already spoke.
/// - **Guarded.** Output is rejected if it looks like the model answered the text instead
///   of cleaning it — the classic failure when dictation reads as an instruction.
struct FoundationModelFormatter: TextFormatter {
    /// Deterministic fallback used on timeout, unavailability, or a rejected response.
    private let fallback: RuleBasedFormatter

    /// Built at init and warmed by `prewarm()`, because a cold session is the single
    /// largest cost in the whole post-release path — measured at ~2.6s cold versus ~1.0s
    /// warm on an M-series Mac. One session per utterance, never shared across them: a
    /// reused session accumulates every prior turn in its transcript and eventually
    /// throws `exceededContextWindowSize`.
    private let session: LanguageModelSession

    /// Past this, taking the raw text beats making the user wait.
    private let timeout: Duration = .seconds(4)

    /// How far this pass may go. Captured once per utterance rather than read at use: the
    /// session is built with the instructions for this strength and then prewarmed, so
    /// changing the setting mid-dictation must not reach the session already in flight.
    let strength: CleanupStrength

    init(strength: CleanupStrength = .standard) {
        self.strength = strength
        fallback = RuleBasedFormatter(strength: strength)
        session = LanguageModelSession(instructions: CleanupGuard.instructions(for: strength))
    }

    /// Loads model assets and primes the instructions while the user is still speaking.
    /// Returns immediately; the work happens in the background.
    func prewarm() {
        guard Self.isAvailable else { return }
        session.prewarm()
    }

    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "This Mac doesn't support Apple Intelligence."
            case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off in System Settings."
            case .modelNotReady: return "The on-device model is still downloading."
            @unknown default: return "The on-device model is unavailable."
            }
        @unknown default:
            return "The on-device model is unavailable."
        }
    }

    func format(_ raw: String) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        guard Self.isAvailable else {
            Log.speech.info("Foundation model unavailable — using rule-based cleanup")
            return await fallback.format(trimmed)
        }

        do {
            let cleaned = try await withThrowingTaskGroup(of: String.self) { group in
                let session = session
                group.addTask { try await Self.clean(trimmed, using: session) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw CleanupError.timedOut
                }
                // Whichever finishes first wins; cancel the loser.
                guard let first = try await group.next() else { throw CleanupError.timedOut }
                group.cancelAll()
                return first
            }

            guard CleanupGuard.isPlausibleCleanup(
                original: trimmed, cleaned: cleaned, strength: strength
            ) else {
                Log.speech.info("Foundation model output rejected — using rule-based cleanup")
                return await fallback.format(trimmed)
            }
            return cleaned
        } catch {
            Log.speech.info("Foundation model cleanup failed (\(Self.describe(error), privacy: .public)) — falling back")
            return await fallback.format(trimmed)
        }
    }

    /// Every failure here degrades to `RuleBasedFormatter` — the user still gets their
    /// words. This exists to make the *reason* legible in the log, because the cases have
    /// very different meanings: `guardrailViolation` and `refusal` are the model declining
    /// content (expected occasionally, not a bug), while `assetsUnavailable` means the
    /// feature is effectively off and the user should be told.
    private static func describe(_ error: Error) -> String {
        guard let error = error as? LanguageModelSession.GenerationError else {
            return error.localizedDescription
        }
        switch error {
        case .exceededContextWindowSize: return "input exceeded the context window"
        case .assetsUnavailable: return "model assets unavailable"
        case .guardrailViolation: return "blocked by safety guardrails"
        case .unsupportedGuide: return "unsupported generation guide"
        case .unsupportedLanguageOrLocale: return "unsupported language"
        case .decodingFailure: return "decoding failure"
        case .rateLimited: return "rate limited"
        case .concurrentRequests: return "concurrent request on one session"
        case .refusal: return "model refused the content"
        @unknown default: return error.localizedDescription
        }
    }

    private static func clean(_ text: String, using session: LanguageModelSession) async throws -> String {
        let response = try await session.respond(
            to: "Clean up this transcript:\n\n\(text)",
            options: GenerationOptions(
                // Near-deterministic: this is a formatting pass, not a creative one.
                temperature: 0.1,
                // Cleanup should never be much longer than the input; this bounds a runaway.
                maximumResponseTokens: 1_200
            )
        )

        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CleanupError: LocalizedError {
        case timedOut
        var errorDescription: String? { "on-device cleanup timed out" }
    }
}

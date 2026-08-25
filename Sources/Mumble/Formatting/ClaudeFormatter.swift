import Foundation

/// Cleanup via the Claude API — the optional higher-quality tier above the on-device model.
///
/// Same shape as `FoundationModelFormatter` on purpose: bounded by a timeout, guarded by
/// `CleanupGuard` against the model answering instead of cleaning, and always degrades to
/// `RuleBasedFormatter` rather than costing the user an utterance they already spoke. The
/// difference is the network round trip, which is why the timeout is longer and why
/// unavailability (no key configured, no network) is just another fallback path rather than
/// a special case.
struct ClaudeFormatter: TextFormatter {
    private let fallback = RuleBasedFormatter()

    /// Longer than the on-device tier's 4s — this pass leaves the machine.
    private let timeout: Duration = .seconds(8)

    /// Haiku, not Sonnet: this runs in the hot path of every dictation, so latency matters
    /// as much as quality. It's still a clear step up from the on-device model.
    private static let model = "claude-haiku-4-5-20251001"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"

    static var isAvailable: Bool { APIKeyStore.anthropicKey != nil }

    static var unavailableReason: String? {
        isAvailable ? nil : "Add an Anthropic API key in Settings to use this tier."
    }

    func format(_ raw: String) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        guard let apiKey = APIKeyStore.anthropicKey else {
            Log.speech.info("Claude cleanup unavailable — no API key — using rule-based cleanup")
            return await fallback.format(trimmed)
        }

        do {
            let cleaned = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await Self.clean(trimmed, apiKey: apiKey) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw CleanupError.timedOut
                }
                // Whichever finishes first wins; cancel the loser.
                guard let first = try await group.next() else { throw CleanupError.timedOut }
                group.cancelAll()
                return first
            }

            guard CleanupGuard.isPlausibleCleanup(original: trimmed, cleaned: cleaned) else {
                Log.speech.info("Claude cleanup rejected — using rule-based cleanup")
                return await fallback.format(trimmed)
            }
            return cleaned
        } catch {
            Log.speech.info("Claude cleanup failed (\(Self.describe(error), privacy: .public)) — falling back")
            return await fallback.format(trimmed)
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? CleanupError)?.errorDescription ?? error.localizedDescription
    }

    private static func clean(_ text: String, apiKey: String) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(RequestBody(
            model: model,
            maxTokens: 1_200,
            // Near-deterministic: this is a formatting pass, not a creative one.
            temperature: 0.1,
            system: CleanupGuard.instructions,
            messages: [Message(role: "user", content: "Clean up this transcript:\n\n\(text)")]
        ))

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CleanupError.requestFailed(status: status)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(ResponseBody.self, from: data)
        guard let text = decoded.content.first(where: { $0.type == "text" })?.text else {
            throw CleanupError.emptyResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct RequestBody: Encodable {
        let model: String
        let maxTokens: Int
        let temperature: Double
        let system: String
        let messages: [Message]
    }

    private struct Message: Encodable {
        let role: String
        let content: String
    }

    private struct ResponseBody: Decodable {
        let content: [ContentBlock]
    }

    private struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }

    private enum CleanupError: LocalizedError {
        case timedOut
        case requestFailed(status: Int)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .timedOut: "timed out"
            case .requestFailed(let status): "request failed (status \(status))"
            case .emptyResponse: "empty response"
            }
        }
    }
}

import Foundation
import Security

/// Stores the Anthropic API key in the login Keychain rather than `UserDefaults` — it's a
/// credential, not a preference, and `defaults` is a plist any local process can read.
enum APIKeyStore {
    private static let service = "ai.pivotstudio.mumble.anthropic-api-key"

    /// `ANTHROPIC_API_KEY` wins when set, so running from Terminal for development never
    /// needs the Keychain touched. The Settings field is what everyone else uses.
    static var anthropicKey: String? {
        if let fromEnvironment = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
           !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        return load()
    }

    /// What's actually in the Keychain, ignoring the environment override — this is what the
    /// Settings field should show and edit, so a dev-only `ANTHROPIC_API_KEY` never leaks
    /// into a UI control that writes back to the Keychain.
    static var storedKey: String? { load() }

    static func saveAnthropicKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete()
            return
        }

        var query = baseQuery
        query[kSecValueData as String] = Data(trimmed.utf8)

        // SecItemAdd fails on a duplicate rather than updating it, so delete first.
        SecItemDelete(baseQuery as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "default",
        ]
    }
}

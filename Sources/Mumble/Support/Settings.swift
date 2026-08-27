import MumbleCleanup
import Foundation
import Observation

/// Which speech engine transcribes an utterance.
enum SpeechEngineChoice: String, CaseIterable, Sendable {
    case apple
    case parakeet

    var displayName: String {
        switch self {
        case .apple: "Apple (streaming)"
        case .parakeet: "Parakeet (batch)"
        }
    }

    /// Apple shows text while you talk; Parakeet only resolves on release.
    var showsLiveText: Bool { self == .apple }
}

/// Which formatter cleans up the raw transcript before injection.
enum CleanupTier: String, CaseIterable, Sendable {
    case rules
    case onDevice
    case claude

    var displayName: String {
        switch self {
        case .rules: "Rules"
        case .onDevice: "On-device AI"
        case .claude: "Claude"
        }
    }

    /// `nil` means available now; otherwise the reason it's greyed out in the UI.
    var unavailableReason: String? {
        switch self {
        case .rules: nil
        case .onDevice: FoundationModelFormatter.unavailableReason
        case .claude: ClaudeFormatter.unavailableReason
        }
    }
}

@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    var pushToTalkKey: PushToTalkKey {
        didSet { defaults.set(pushToTalkKey.rawValue, forKey: Keys.pushToTalkKey) }
    }

    var engine: SpeechEngineChoice {
        didSet { defaults.set(engine.rawValue, forKey: Keys.engine) }
    }

    /// The input device Mumble records from, by UID, or nil to follow the system default.
    ///
    /// A pin exists for calls: FaceTime or Zoom takes the headset and moves the system
    /// default around, and dictation should keep working on the laptop mic rather than
    /// following whatever the call did.
    var inputDeviceUID: String? {
        didSet { defaults.set(inputDeviceUID, forKey: Keys.inputDeviceUID) }
    }

    /// Run every engine on each recording and show them side by side, instead of
    /// transcribing with one. Nothing is typed into the focused app in this mode.
    var compareMode: Bool {
        didSet { defaults.set(compareMode, forKey: Keys.compareMode) }
    }

    /// Run the cleanup pass before injecting. Off = raw engine output.
    var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Keys.cleanupEnabled) }
    }

    /// Which formatter runs when cleanup is on: deterministic rules, the on-device model,
    /// or Claude.
    var cleanupTier: CleanupTier {
        didSet { defaults.set(cleanupTier.rawValue, forKey: Keys.cleanupTier) }
    }

    /// How far the cleanup pass may go — punctuation only, through to repairing grammar.
    var cleanupStrength: CleanupStrength {
        didSet { defaults.set(cleanupStrength.rawValue, forKey: Keys.cleanupStrength) }
    }

    /// Play a short tick when capture starts and stops.
    var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let pushToTalkKey = "pushToTalkKey"
        static let cleanupEnabled = "cleanupEnabled"
        static let soundEnabled = "soundEnabled"
        static let engine = "engine"
        static let cleanupTier = "cleanupTier"
        static let cleanupStrength = "cleanupStrength"
        static let compareMode = "compareMode"
        static let inputDeviceUID = "inputDeviceUID"
    }

    private init() {
        let raw = defaults.string(forKey: Keys.pushToTalkKey) ?? PushToTalkKey.rightOption.rawValue
        pushToTalkKey = PushToTalkKey(rawValue: raw) ?? .rightOption
        // Apple by default: no download, no dependency, live text while speaking.
        engine = SpeechEngineChoice(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .apple
        cleanupEnabled = defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? true
        cleanupTier = CleanupTier(rawValue: defaults.string(forKey: Keys.cleanupTier) ?? "") ?? .rules
        // Standard by default: it is what cleanup did before this setting existed, so an
        // upgrade does not quietly change what lands in anyone's documents.
        cleanupStrength = CleanupStrength(rawValue: defaults.string(forKey: Keys.cleanupStrength) ?? "")
            ?? .standard
        compareMode = defaults.object(forKey: Keys.compareMode) as? Bool ?? false
        inputDeviceUID = defaults.string(forKey: Keys.inputDeviceUID)
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
    }
}

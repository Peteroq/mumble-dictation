import Foundation

/// How far the cleanup pass is allowed to go.
///
/// Cleanup used to be one fixed behaviour. It is a dial now because the right amount is a
/// matter of taste and of what you are dictating: notes to yourself want every word kept,
/// a message to a colleague wants the grammar fixed.
///
/// Each level moves two things together — what the model is told to do, and what
/// `CleanupGuard` will accept back. Loosening the instructions without loosening the guard
/// produces a tier that asks for rewriting and then rejects it, falling back to rules every
/// time; loosening the guard without the instructions gives the model licence it never uses.
public enum CleanupStrength: String, CaseIterable, Sendable {
    /// Punctuation, capitalisation and spacing. Every word you said is still there.
    case light
    /// Also fillers, false starts and spoken self-corrections.
    case standard
    /// Also grammar and phrasing: broken sentences are repaired, not just tidied.
    case polished

    public var displayName: String {
        switch self {
        case .light: "Light"
        case .standard: "Standard"
        case .polished: "Polished"
        }
    }

    public var explanation: String {
        switch self {
        case .light:
            "Punctuation, capitalisation and spacing only. Every word you said survives."
        case .standard:
            "Also removes fillers and false starts, and applies spoken corrections — "
                + "\"send it Tuesday, actually Wednesday\" becomes \"send it Wednesday\"."
        case .polished:
            "Also repairs grammar and tightens phrasing. It still cannot introduce a word "
                + "you did not say: that check is what stops the model answering your "
                + "dictation instead of cleaning it."
        }
    }
}

import Foundation

/// A saved prompt: something you want to say to a model again, kept so you don't have to
/// write it twice.
///
/// Most of these start life as a transcription. Dictating a long instruction is the fast way
/// to write one, and the history already has every one you have ever dictated — so the
/// library is fed from there rather than only from typing.
struct Prompt: Codable, Sendable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var text: String

    /// The folder this sits in, by name, or nil for the top level.
    ///
    /// A name and not an id, and a single optional rather than a path: a folder cannot name a
    /// parent, so the structure is one level deep because there is nowhere to put a second
    /// one. That is the constraint the feature was asked for, and enforcing it in the type is
    /// cheaper than checking for it everywhere a prompt is moved.
    var folder: String?

    var tags: [String] = []
    var isFavorite: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// The first line, or the opening of the only line — what a row shows under the title.
    var summary: String {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first ?? ""
        return String(firstLine).trimmingCharacters(in: .whitespaces)
    }

    /// Everything a search should look at. Folder and tags are in here so that typing a
    /// folder's name finds its contents, which is the obvious thing to try.
    func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if title.localizedStandardContains(trimmed) { return true }
        if text.localizedStandardContains(trimmed) { return true }
        if let folder, folder.localizedStandardContains(trimmed) { return true }
        return tags.contains { $0.localizedStandardContains(trimmed) }
    }

    /// A title for a prompt made out of a transcript, which arrives with no title at all.
    /// The opening few words, because that is what you would have typed anyway.
    static func title(from text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).prefix(7)
        let opening = words.joined(separator: " ")
        return opening.count < text.trimmingCharacters(in: .whitespacesAndNewlines).count
            ? opening + "…"
            : opening
    }

    /// Splits a comma-separated field into tags: trimmed, de-duplicated case-insensitively,
    /// and kept in the order they were typed.
    static func tags(from field: String) -> [String] {
        var seen = Set<String>()
        return field
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }
}

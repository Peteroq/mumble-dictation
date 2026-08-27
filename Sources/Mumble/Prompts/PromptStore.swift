import Foundation
import Observation

/// The prompt library, persisted as JSON in Application Support.
///
/// JSON and not the dictionary's hand-editable text format: a prompt is a paragraph with
/// newlines in it, and a line-based file would need an escaping scheme that no one would
/// want to type. It is still written pretty-printed with sorted keys so a diff of the file
/// is readable.
///
/// Folders are stored explicitly as well as being implied by the prompts in them. Deriving
/// them from the prompts alone is less code, but then a folder you have just made vanishes
/// the moment its last prompt moves out — including while you are in the middle of moving
/// prompts between two of them.
@MainActor
@Observable
final class PromptStore {
    static let shared = PromptStore()

    private(set) var prompts: [Prompt] = []
    private(set) var folders: [String] = []

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mumble", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("prompts.json")
    }

    private init() { load() }

    // MARK: - Editing

    func add(_ prompt: Prompt) {
        var prompt = prompt
        prompt.updatedAt = Date()
        prompts.append(prompt)
        adopt(prompt.folder)
        save()
    }

    func update(_ prompt: Prompt) {
        guard let index = prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        var prompt = prompt
        prompt.updatedAt = Date()
        prompts[index] = prompt
        adopt(prompt.folder)
        save()
    }

    func delete(_ prompt: Prompt) {
        prompts.removeAll { $0.id == prompt.id }
        save()
    }

    func toggleFavorite(_ prompt: Prompt) {
        guard let index = prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        prompts[index].isFavorite.toggle()
        prompts[index].updatedAt = Date()
        save()
    }

    /// Makes a folder that has nothing in it yet, so you can file prompts into it afterwards.
    func addFolder(_ name: String) {
        adopt(name)
        save()
    }

    /// Removes a folder and turns its contents loose rather than deleting them. Losing a
    /// paragraph you dictated because you tidied up a folder would be unforgivable, and there
    /// is no undo here.
    func deleteFolder(_ name: String) {
        folders.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        for index in prompts.indices where prompts[index].folder == name {
            prompts[index].folder = nil
        }
        save()
    }

    private func adopt(_ folder: String?) {
        guard let folder, !folder.isEmpty else { return }
        guard !folders.contains(where: { $0.caseInsensitiveCompare(folder) == .orderedSame }) else {
            return
        }
        folders.append(folder)
        folders.sort { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Reading

    /// Every tag in use, sorted, each one once regardless of how it was capitalised.
    var tags: [String] {
        var seen = Set<String>()
        return prompts
            .flatMap(\.tags)
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The library narrowed by the three filters the panel offers, newest first.
    func filtered(query: String, tag: String?, favoritesOnly: Bool) -> [Prompt] {
        prompts
            .filter { $0.matches(query) }
            .filter { tag == nil || $0.tags.contains { $0.caseInsensitiveCompare(tag!) == .orderedSame } }
            .filter { !favoritesOnly || $0.isFavorite }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Persistence

    private struct Library: Codable {
        var prompts: [Prompt]
        var folders: [String]
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let library = try? decoder.decode(Library.self, from: data) else {
            Log.app.error("prompts: could not read \(Self.fileURL.lastPathComponent, privacy: .public)")
            return
        }
        prompts = library.prompts
        folders = library.folders
        // A hand-edited file can name a folder in a prompt without listing it. Taking the
        // union means such a prompt still shows up under a heading rather than at the top
        // level, where it would look like the edit had silently dropped it.
        for prompt in prompts { adopt(prompt.folder) }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Library(prompts: prompts, folders: folders)) else {
            return
        }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

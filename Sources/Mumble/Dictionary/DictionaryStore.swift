import MumbleDictionary
import Foundation
import Observation

/// The dictionary, persisted as a plain text file you can edit by hand.
///
/// A text file rather than JSON, because the spec asks for something editable outside the UI
/// and JSON is only nominally that — quoting, escaping and a trailing-comma trap for anyone
/// adding a line in a hurry. The format is one entry per line:
///
/// ```
/// Anthropic
/// Vercel
/// cloud code -> Claude Code
/// # off: whisper flow -> Wispr Flow
/// ```
///
/// A bare line is a term. `X -> Y` is a correction. `#` starts a comment, and a disabled
/// entry is written as a `# off:` comment so it survives a round trip through the file
/// without silently disappearing.
///
/// The file is watched, so editing it in a text editor updates the UI live and vice versa.
@MainActor
@Observable
final class DictionaryStore {
    static let shared = DictionaryStore()

    private(set) var entries: [DictionaryEntry] = []

    /// Bumped whenever entries change, so the engine can rebuild its bias list lazily
    /// instead of on every transcription.
    private(set) var revision = 0

    private var watcher: DispatchSourceFileSystemObject?
    /// The text of our own last save. The watcher's event arrives after `save()` has
    /// returned, so a flag set during the write can't tell our save from a hand edit — and
    /// reloading our own save re-parses every entry under a new id, which silently drops an
    /// edit made against an entry captured before it.
    private var lastWritten: String?

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mumble", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("dictionary.txt")
    }

    private init() {
        load()
        startWatching()
    }

    // MARK: - Editing

    func add(_ entry: DictionaryEntry) {
        entries.append(entry)
        save()
    }

    func update(_ entry: DictionaryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        save()
    }

    func delete(_ entry: DictionaryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func delete(ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    /// Adds a correction, or rewrites the existing rule for the same trigger.
    ///
    /// Teaching from a transcript goes through here rather than `add`, because the obvious
    /// way to use the feature is to fix the same mishearing twice — and two rules with the
    /// same trigger is a dictionary that contradicts itself, where which one wins depends on
    /// file order.
    ///
    /// A disabled rule for the trigger is re-enabled: the user just asked for it.
    @discardableResult
    func teach(hear: String, write: String) -> DictionaryEntry {
        let trigger = hear.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = write.trimmingCharacters(in: .whitespacesAndNewlines)

        if var existing = correction(for: trigger) {
            existing.write = replacement
            existing.isEnabled = true
            update(existing)
            return existing
        }

        let entry = DictionaryEntry.correction(hear: trigger, write: replacement)
        add(entry)
        return entry
    }

    /// The enabled-or-not correction rule whose trigger is `hear`, if there is one.
    func correction(for hear: String) -> DictionaryEntry? {
        let trigger = hear.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty else { return nil }
        return entries.first {
            $0.kind == .correction
                && $0.hear.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(trigger) == .orderedSame
        }
    }

    /// Case- and diacritic-insensitive search across both sides of an entry.
    func filtered(by query: String) -> [DictionaryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter {
            $0.write.localizedStandardContains(trimmed) || $0.hear.localizedStandardContains(trimmed)
        }
    }

    /// A corrector over the current entries. Rebuilt on demand — compiling a few dozen small
    /// regexes is cheap next to transcription, and caching it invites staleness.
    var corrector: DictionaryCorrector { DictionaryCorrector(entries: entries) }

    var biasPhrases: [String] { DictionaryCorrector.biasPhrases(from: entries) }

    // MARK: - Persistence

    private func load() {
        // Missing mid-save — an editor that deletes and recreates — keeps what we had. If it
        // is still missing a second later, `startWatching` treats it as deleted on purpose.
        guard FileManager.default.fileExists(atPath: Self.fileURL.path) else { return }
        // A file that exists but can't be read — mid-replace by an editor, or saved in an
        // encoding other than UTF-8 — keeps what we had. Emptying the list here meant the
        // next in-app edit wrote a file holding only that edit, over the user's own.
        guard let text = try? String(contentsOf: Self.fileURL, encoding: .utf8) else {
            Log.app.error("dictionary: could not read \(Self.fileURL.lastPathComponent, privacy: .public); keeping the current entries")
            return
        }
        guard text != lastWritten else { return }
        entries = Self.parse(text)
        revision += 1
    }

    static func parse(_ text: String) -> [DictionaryEntry] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }

            // `# off:` is a disabled entry; any other comment is just a comment.
            var isEnabled = true
            if line.hasPrefix("#") {
                let stripped = line.dropFirst().trimmingCharacters(in: .whitespaces)
                guard stripped.lowercased().hasPrefix("off:") else { return nil }
                line = stripped.dropFirst(4).trimmingCharacters(in: .whitespaces)
                isEnabled = false
                guard !line.isEmpty else { return nil }
            }

            if let arrow = line.range(of: "->") {
                let hear = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                let write = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                guard !hear.isEmpty, !write.isEmpty else { return nil }
                return DictionaryEntry(kind: .correction, write: write, hear: hear, isEnabled: isEnabled)
            }

            return DictionaryEntry(kind: .term, write: line, isEnabled: isEnabled)
        }
    }

    private func save() {
        revision += 1

        let body = entries.map(\.fileLine).joined(separator: "\n")
        let text = Self.header + body + "\n"
        lastWritten = text
        try? text.write(to: Self.fileURL, atomically: true, encoding: .utf8)
    }

    private static let header = """
        # Mumble dictionary
        #
        #   Anthropic                 a term — the engine is told this word exists
        #   cloud code -> Claude Code a correction — when you hear X, write Y
        #   # off: some rule -> Rule  a disabled entry
        #
        # Edit this file directly if you like; the app picks up changes immediately.

        """

    // MARK: - External edits

    /// Watches the file so a hand edit shows up in the UI without a relaunch.
    ///
    /// Rearms after every event: an atomic write replaces the inode, so the descriptor we
    /// were watching is gone the moment the file changes — including when *we* save.
    private func startWatching(retrying: Bool = true) {
        watcher?.cancel()

        let descriptor = open(Self.fileURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // An editor that saves by delete-then-create leaves a moment with no file to
            // open. Giving up here stopped hand edits reaching the app for the rest of the
            // session, so look again shortly. If it is still missing then, it was deleted on
            // purpose: start a fresh one so there is something to watch.
            guard retrying else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if FileManager.default.fileExists(atPath: Self.fileURL.path) {
                    self.load()
                } else if !self.entries.isEmpty {
                    self.entries = []
                    self.save()
                }
                // Once only: a file that can't be created is not going to start existing.
                self.startWatching(retrying: false)
            }
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.load()
            self.startWatching()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()

        watcher = source
    }
}

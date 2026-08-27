import AppKit
import SwiftUI

/// The prompt library: things you want to say to a model again.
///
/// Organised one level deep, because that is the depth at which a folder list is still
/// scannable — and because most of what lands here arrives from the transcript list, where
/// the useful question is "which of these did I want to keep", not "where in a tree does it
/// belong". Tags do the cross-cutting that folders can't: a prompt lives in one folder and
/// carries as many tags as you like.
struct PromptsPanel: View {
    @State private var store = PromptStore.shared
    @State private var query = ""
    @State private var tag: String?
    @State private var favoritesOnly = false
    @State private var editing: PromptDraft?
    @State private var newFolder = ""
    @State private var isNamingFolder = false

    private var results: [Prompt] {
        store.filtered(query: query, tag: tag, favoritesOnly: favoritesOnly)
    }

    /// Whether anything is narrowing the list. Empty folders are worth showing while you are
    /// browsing and only noise while you are searching.
    private var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || tag != nil
            || favoritesOnly
    }

    var body: some View {
        VStack(spacing: DS.Space.base) {
            controls

            if !store.tags.isEmpty || favoritesOnly {
                filters
            }

            if store.prompts.isEmpty {
                EmptyPanel(
                    label: "No prompts",
                    detail: "Save one from a transcription, or write one here."
                )
            } else if results.isEmpty {
                EmptyPanel(label: "No matches", detail: "Try a different search or tag.")
            } else {
                library
            }

            footer
        }
        .sheet(item: $editing) { draft in
            PromptEditor(draft: draft) { saved in
                if draft.isNew { store.add(saved) } else { store.update(saved) }
            }
        }
    }

    // MARK: - Chrome

    private var controls: some View {
        HStack(spacing: DS.Space.base) {
            SearchField(text: $query, placeholder: "Search prompts, tags and folders")

            if isNamingFolder {
                Inset(radius: DS.Radius.control) {
                    TextField("Folder name", text: $newFolder)
                        .textFieldStyle(.plain)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.ink)
                        .frame(width: 150)
                        .padding(.horizontal, DS.Space.base)
                        .padding(.vertical, DS.Space.snug)
                        .onSubmit(commitFolder)
                }
                ActionButton(title: "Add", isProminent: true, isEnabled: !isBlank(newFolder)) {
                    commitFolder()
                }
            } else {
                ActionButton(title: "Folder", systemImage: "folder.badge.plus") {
                    withAnimation(DS.Motion.panel) { isNamingFolder = true }
                }
            }

            ActionButton(title: "New", systemImage: "plus", isProminent: true) {
                editing = PromptDraft(prompt: Prompt(title: "", text: ""), isNew: true)
            }
        }
    }

    private var filters: some View {
        HStack(spacing: DS.Space.snug) {
            ActionButton(
                title: "Favorites",
                systemImage: favoritesOnly ? "star.fill" : "star",
                isEngaged: favoritesOnly,
                engagedColor: DS.Color.ink
            ) {
                withAnimation(DS.Motion.panel) { favoritesOnly.toggle() }
            }

            ForEach(store.tags, id: \.self) { candidate in
                ActionButton(
                    title: candidate,
                    isEngaged: tag == candidate,
                    engagedColor: DS.Color.ink
                ) {
                    // Tapping the engaged tag clears it, so the filter never becomes a trap
                    // you have to hunt for an "All" button to escape.
                    withAnimation(DS.Motion.panel) { tag = tag == candidate ? nil : candidate }
                }
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            TextLabel(text: "\(store.prompts.count) prompt\(store.prompts.count == 1 ? "" : "s")")
            TextLabel(
                text: "Save a transcription as a prompt from its row",
                color: DS.Color.silkscreen
            )
            Spacer()
        }
    }

    // MARK: - The library

    private var library: some View {
        LazyVStack(alignment: .leading, spacing: DS.Space.base) {
            let loose = results.filter { $0.folder == nil }
            if !loose.isEmpty {
                rows(loose)
            }

            ForEach(store.folders, id: \.self) { folder in
                let contents = results.filter { $0.folder == folder }
                if !contents.isEmpty || !isFiltering {
                    FolderHeading(
                        name: folder,
                        count: contents.count,
                        onDelete: { store.deleteFolder(folder) }
                    )
                    if contents.isEmpty {
                        TextLabel(text: "Empty", color: DS.Color.silkscreen)
                            .padding(.leading, DS.Space.base)
                            .padding(.bottom, DS.Space.snug)
                    } else {
                        rows(contents)
                    }
                }
            }
        }
    }

    private func rows(_ prompts: [Prompt]) -> some View {
        ForEach(prompts) { prompt in
            PromptRow(
                prompt: prompt,
                onEdit: { editing = PromptDraft(prompt: prompt, isNew: false) },
                onFavorite: { store.toggleFavorite(prompt) },
                onDelete: { withAnimation(DS.Motion.panel) { store.delete(prompt) } }
            )
        }
    }

    private func commitFolder() {
        let name = newFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.addFolder(name)
        newFolder = ""
        withAnimation(DS.Motion.panel) { isNamingFolder = false }
    }

    private func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// What the editor sheet is editing. A wrapper rather than the prompt itself, because
/// `.sheet(item:)` keys on identity and a new prompt has to be distinguishable from the
/// existing one it was seeded from.
struct PromptDraft: Identifiable {
    let id = UUID()
    var prompt: Prompt
    var isNew: Bool
}

// MARK: - Folder heading

private struct FolderHeading: View {
    let name: String
    let count: Int
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.Color.inkSecondary)
            TextLabel(text: name, large: true, color: DS.Color.ink)
            TextLabel(text: "\(count)")
            Spacer()
            if isHovering {
                // Says what it does, because it does not do the obvious thing: the prompts
                // inside come back out to the top level rather than going with the folder.
                Button(action: onDelete) {
                    TextLabel(text: "Delete folder", color: DS.Color.inkSecondary)
                        .padding(.horizontal, DS.Space.snug)
                        .padding(.vertical, DS.Space.hair)
                        .background(DS.Color.well, in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Deletes the folder. Its prompts move to the top level.")
            }
        }
        .padding(.top, DS.Space.snug)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Row

private struct PromptRow: View {
    let prompt: Prompt
    let onEdit: () -> Void
    let onFavorite: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            HStack(spacing: DS.Space.snug) {
                Button(action: onFavorite) {
                    Image(systemName: prompt.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(prompt.isFavorite ? DS.Color.accent : DS.Color.inkSecondary)
                }
                .buttonStyle(.plain)
                .help(prompt.isFavorite ? "Remove from favorites" : "Add to favorites")

                Text(prompt.title)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.ink)
                    .lineLimit(1)

                Spacer()

                if isHovering {
                    rowButton(didCopy ? "Copied" : "Copy", tint: didCopy ? DS.Color.accent : nil) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(prompt.text, forType: .string)
                        didCopy = true
                        Task {
                            try? await Task.sleep(for: .seconds(DS.Motion.confirmationSeconds))
                            didCopy = false
                        }
                    }
                    rowButton("Edit", action: onEdit)
                    rowButton("Delete", action: onDelete)
                }
            }

            Text(prompt.summary)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.inkSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !prompt.tags.isEmpty {
                HStack(spacing: DS.Space.tight) {
                    ForEach(prompt.tags, id: \.self) { tag in
                        TextLabel(text: tag, color: DS.Color.inkSecondary)
                            .padding(.horizontal, DS.Space.snug)
                            .padding(.vertical, DS.Space.hair)
                            .background(DS.Color.well, in: Capsule(style: .continuous))
                    }
                    Spacer()
                }
            }
        }
        .padding(DS.Space.base)
        .background(Card(radius: DS.Radius.control))
        .overlay(
            dsShape(DS.Radius.control)
                .strokeBorder(isHovering ? DS.Color.selectionEdge : .clear,
                              lineWidth: DS.Border.hairline)
        )
        .animation(DS.Motion.lamp, value: isHovering)
        .onHover { isHovering = $0 }
    }

    private func rowButton(
        _ title: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            TextLabel(text: title, color: tint ?? DS.Color.inkSecondary)
                .padding(.horizontal, DS.Space.snug)
                .padding(.vertical, DS.Space.hair)
                .background(DS.Color.well, in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Editor

/// Write or rework one prompt. The same sheet whether it started as a transcription, a paste
/// or an empty page — a prompt from the history is not a different kind of thing, it just
/// arrives with its text already filled in.
struct PromptEditor: View {
    let draft: PromptDraft
    let onSave: (Prompt) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var store = PromptStore.shared
    @State private var title: String
    @State private var text: String
    @State private var folder: String?
    @State private var tagField: String
    @State private var isFavorite: Bool
    /// Typed here rather than picked, for a folder that does not exist yet. Wins over the
    /// menu when it has something in it, so there is no way to fill it in and be ignored.
    @State private var newFolder = ""

    init(draft: PromptDraft, onSave: @escaping (Prompt) -> Void) {
        self.draft = draft
        self.onSave = onSave
        _title = State(initialValue: draft.prompt.title)
        _text = State(initialValue: draft.prompt.text)
        _folder = State(initialValue: draft.prompt.folder)
        _tagField = State(initialValue: draft.prompt.tags.joined(separator: ", "))
        _isFavorite = State(initialValue: draft.prompt.isFavorite)
    }

    private var resolvedFolder: String? {
        let typed = newFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? folder : typed
    }

    private var result: Prompt {
        var prompt = draft.prompt
        prompt.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt.text = text
        prompt.folder = resolvedFolder
        prompt.tags = Prompt.tags(from: tagField)
        prompt.isFavorite = isFavorite
        return prompt
    }

    private var isValid: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.roomy) {
            TextLabel(text: draft.isNew ? "New prompt" : "Edit prompt", large: true)

            field("Title", text: $title, prompt: "Name it something you'll recognise")

            VStack(alignment: .leading, spacing: DS.Space.snug) {
                TextLabel(text: "Prompt")
                Inset(radius: DS.Radius.control) {
                    TextEditor(text: $text)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.ink)
                        .scrollContentBackground(.hidden)
                        .frame(height: 200)
                        .padding(DS.Space.snug)
                }
            }

            HStack(alignment: .top, spacing: DS.Space.base) {
                VStack(alignment: .leading, spacing: DS.Space.snug) {
                    TextLabel(text: "Folder")
                    folderPicker
                }
                field("Or a new folder", text: $newFolder, prompt: "Code review")
            }

            field("Tags", text: $tagField, prompt: "refactor, tests — comma separated")

            HStack(spacing: DS.Space.snug) {
                ActionButton(
                    title: "Favorite",
                    systemImage: isFavorite ? "star.fill" : "star",
                    isEngaged: isFavorite,
                    engagedColor: DS.Color.ink
                ) {
                    isFavorite.toggle()
                }
                Spacer()
                ActionButton(title: "Cancel") { dismiss() }
                ActionButton(title: "Save", isProminent: true, isEnabled: isValid) {
                    guard isValid else { return }
                    var saved = result
                    // A prompt with no title is still worth keeping; naming it after its own
                    // opening beats a library of blank rows.
                    if saved.title.isEmpty { saved.title = Prompt.title(from: saved.text) }
                    onSave(saved)
                    dismiss()
                }
            }
        }
        .padding(DS.Space.panel)
        .frame(width: 560)
        .background { AppBackground(isDense: true) }
    }

    private var folderPicker: some View {
        Menu {
            Picker(selection: $folder) {
                Text("None").tag(String?.none)
                ForEach(store.folders, id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: DS.Space.snug) {
                Text(folder ?? "None")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.Color.inkSecondary)
            }
            .padding(.horizontal, DS.Space.base)
            .frame(height: DS.Material.keyHeight)
            .background(DS.Color.well, in: dsShape(DS.Radius.control))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!newFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            TextLabel(text: label)
            Inset(radius: DS.Radius.control) {
                TextField(prompt, text: text)
                    .textFieldStyle(.plain)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                    .padding(.horizontal, DS.Space.base)
                    .padding(.vertical, DS.Space.snug)
            }
        }
    }
}

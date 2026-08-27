import MumbleDictionary
import AppKit
import SwiftUI

/// The dictionary: add, edit, delete, search.
///
/// Both entry kinds live in one list rather than separate tabs — they're two shapes of the
/// same idea and you want to see everything you've taught it at once. The kind is carried by
/// a small tag on each row.
struct DictionaryPanel: View {
    @State private var store = DictionaryStore.shared
    @State private var query = ""
    @State private var editing: DictionaryEntry?
    @State private var isAdding = false

    private var entries: [DictionaryEntry] { store.filtered(by: query) }

    var body: some View {
        VStack(spacing: DS.Space.base) {
            HStack(spacing: DS.Space.base) {
                SearchField(text: $query, placeholder: "Search dictionary")
                addButton
            }

            if entries.isEmpty {
                EmptyPanel(
                    label: store.entries.isEmpty ? "Dictionary empty" : "No matches",
                    detail: store.entries.isEmpty
                        ? "Add words it keeps getting wrong."
                        : "Try a different search."
                )
            } else {
                LazyVStack(spacing: DS.Space.snug) {
                    ForEach(entries) { entry in
                        DictionaryRow(
                            entry: entry,
                            onEdit: { editing = entry },
                            onToggle: {
                                var updated = entry
                                updated.isEnabled.toggle()
                                store.update(updated)
                            },
                            onDelete: { store.delete(entry) }
                        )
                    }
                }
            }

            footer
        }
        .sheet(isPresented: $isAdding) {
            DictionaryEditor(entry: nil) { store.add($0) }
        }
        .sheet(item: $editing) { entry in
            DictionaryEditor(entry: entry) { store.update($0) }
        }
    }

    private var addButton: some View {
        ActionButton(title: "Add", systemImage: "plus", isProminent: true) {
            isAdding = true
        }
        .keyboardShortcut("n", modifiers: .command)
    }

    /// The file path is shown because the spec asks for the dictionary to be editable outside
    /// the UI — which is only true if you can find it.
    private var footer: some View {
        HStack(spacing: DS.Space.snug) {
            TextLabel(text: "\(store.entries.count) entries")
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
            } label: {
                TextLabel(text: "Reveal dictionary.txt", color: DS.Color.inkSecondary)
            }
            .buttonStyle(.plain)
            .help(DictionaryStore.fileURL.path)
        }
    }
}

// MARK: - Row

private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DS.Space.base) {
            StatusDot(color: DS.Color.meterOn, isLit: entry.isEnabled, size: 7)

            TextLabel(text: entry.kind == .correction ? "Fix" : "Term")
                .frame(width: 36, alignment: .leading)

            if entry.kind == .correction {
                Text(entry.hear)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.inkSecondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.Color.inkSecondary)
            }

            Text(entry.write)
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)

            Spacer()

            if isHovering {
                rowButton("Edit", action: onEdit)
                rowButton(entry.isEnabled ? "Off" : "On", action: onToggle)
                rowButton("Delete", action: onDelete)
            }
        }
        .opacity(entry.isEnabled ? 1 : 0.45)
        .padding(.horizontal, DS.Space.base)
        .padding(.vertical, DS.Space.base)
        .background(
            isHovering ? DS.Color.hover : DS.Color.panel,
            in: dsShape(DS.Radius.control)
        )
        .onHover { isHovering = $0 }
    }

    private func rowButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            TextLabel(text: title, color: DS.Color.inkSecondary)
                .padding(.horizontal, DS.Space.snug)
                .padding(.vertical, DS.Space.hair)
                .background(DS.Color.well, in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Editor

/// Add or edit one entry, with the false-positive warning shown live as you type.
private struct DictionaryEditor: View {
    let entry: DictionaryEntry?
    let onSave: (DictionaryEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: DictionaryEntry.Kind
    @State private var hear: String
    @State private var write: String

    init(entry: DictionaryEntry?, onSave: @escaping (DictionaryEntry) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _kind = State(initialValue: entry?.kind ?? .term)
        _hear = State(initialValue: entry?.hear ?? "")
        _write = State(initialValue: entry?.write ?? "")
    }

    private var draft: DictionaryEntry {
        DictionaryEntry(
            id: entry?.id ?? UUID(),
            kind: kind,
            write: write.trimmingCharacters(in: .whitespacesAndNewlines),
            hear: kind == .correction ? hear.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            isEnabled: entry?.isEnabled ?? true
        )
    }

    private var warnings: [DictionaryWarning] { DictionaryWarning.check(draft) }

    private var isValid: Bool {
        !draft.write.isEmpty && (kind == .term || !draft.hear.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.roomy) {
            TextLabel(text: entry == nil ? "New entry" : "Edit entry", large: true)

            kindPicker

            VStack(alignment: .leading, spacing: DS.Space.base) {
                if kind == .correction {
                    field("When you hear", text: $hear, prompt: "cloud code")
                }
                field(
                    kind == .correction ? "Write" : "Word or phrase",
                    text: $write,
                    prompt: kind == .correction ? "Claude Code" : "Anthropic"
                )
            }

            ForEach(warnings) { warning in
                HStack(alignment: .top, spacing: DS.Space.snug) {
                    StatusDot(color: DS.Color.meterFlag, isLit: true, size: 7)
                        .padding(.top, 3)
                    Text(warning.message)
                        .font(DS.Font.label)
                        .foregroundStyle(DS.Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DS.Space.base)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    DS.Color.meterFlag.opacity(DS.Material.noteTint),
                    in: dsShape(DS.Radius.control)
                )
            }

            HStack(spacing: DS.Space.snug) {
                Spacer()
                ActionButton(title: "Cancel") { dismiss() }
                ActionButton(title: "Save", isProminent: true, isEnabled: isValid) {
                    guard isValid else { return }
                    onSave(draft)
                    dismiss()
                }
            }
        }
        .padding(DS.Space.panel)
        .frame(width: 500)
        // The same glass as the window, so a sheet reads as a pane of the app rather than an
        // opaque card dropped on top of it. `DS.Color.panel` alone is translucent now, which
        // over a sheet's own shadow reads as a smudge.
        .background { AppBackground(isDense: true) }
    }

    private var kindPicker: some View {
        HStack(spacing: DS.Space.snug) {
            ForEach([DictionaryEntry.Kind.term, .correction], id: \.self) { candidate in
                ActionButton(
                    title: candidate == .term ? "Term" : "Correction",
                    isEngaged: kind == candidate,
                    engagedColor: DS.Color.ink
                ) {
                    withAnimation(DS.Motion.panel) { kind = candidate }
                }
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            TextLabel(text: label)
            Inset {
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

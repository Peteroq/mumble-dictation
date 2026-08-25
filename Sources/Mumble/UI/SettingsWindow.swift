import SwiftUI

/// Settings — hotkey and model, per the brief. Opens on ⌘, via the standard `Settings` scene,
/// so the system wires up the menu item and the shortcut.
struct SettingsWindow: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared
    @State private var apiKeyInput = APIKeyStore.storedKey ?? ""

    var body: some View {
        ZStack {
            DS.Color.chassis.ignoresSafeArea()

            VStack(alignment: .leading, spacing: DS.Space.wide) {
                panel(label: "Push to talk") {
                    HStack(spacing: DS.Space.snug) {
                        ForEach(PushToTalkKey.allCases, id: \.self) { key in
                            TransportKey(
                                title: key.displayName,
                                isEngaged: settings.pushToTalkKey == key,
                                engagedColor: DS.Color.ink
                            ) {
                                settings.pushToTalkKey = key
                                controller.reloadHotkey()
                            }
                            .background {
                                if settings.pushToTalkKey == key {
                                    RoundedRectangle(cornerRadius: DS.Radius.control)
                                        .fill(DS.Color.selection)
                                }
                            }
                        }
                    }
                    note("Hold this key anywhere to dictate. The window's Record button works "
                        + "regardless of what's focused.")
                }

                panel(label: "Model") {
                    HStack(spacing: DS.Space.snug) {
                        ForEach(SpeechEngineChoice.allCases, id: \.self) { choice in
                            TransportKey(
                                title: choice == .apple ? "Apple" : "Parakeet",
                                isEngaged: settings.engine == choice,
                                engagedColor: DS.Color.ink
                            ) {
                                settings.engine = choice
                            }
                            .background {
                                if settings.engine == choice {
                                    RoundedRectangle(cornerRadius: DS.Radius.control)
                                        .fill(DS.Color.selection)
                                }
                            }
                        }
                    }
                    note(settings.engine == .apple
                        ? "Apple's on-device transcriber. Streams text while you speak; no download."
                        : "Parakeet on the Neural Engine. Resolves on release; ~470 MB model.")
                }

                panel(label: "Cleanup") {
                    Toggle(isOn: $settings.cleanupEnabled) {
                        Silkscreen(text: "Clean up transcripts")
                    }
                    .toggleStyle(.switch)
                    note("Strips fillers, fixes spacing and punctuation. The dictionary's "
                        + "corrections run either way.")

                    if settings.cleanupEnabled {
                        HStack(spacing: DS.Space.snug) {
                            ForEach(CleanupTier.allCases, id: \.self) { tier in
                                TransportKey(
                                    title: tier.displayName,
                                    isEngaged: settings.cleanupTier == tier,
                                    engagedColor: DS.Color.ink
                                ) {
                                    settings.cleanupTier = tier
                                }
                                .disabled(tier.unavailableReason != nil)
                                .background {
                                    if settings.cleanupTier == tier {
                                        RoundedRectangle(cornerRadius: DS.Radius.control)
                                            .fill(DS.Color.selection)
                                    }
                                }
                            }
                        }
                        .padding(.top, DS.Space.tight)

                        switch settings.cleanupTier {
                        case .rules:
                            note("Deterministic and instant. No model, no network.")
                        case .onDevice:
                            note(FoundationModelFormatter.unavailableReason
                                ?? "Apple's on-device model. Falls back to rules on timeout.")
                        case .claude:
                            secureField(
                                "Anthropic API key",
                                text: $apiKeyInput,
                                prompt: "sk-ant-…"
                            )
                            .onChange(of: apiKeyInput) { _, newValue in
                                APIKeyStore.saveAnthropicKey(newValue)
                            }
                            note("Stored in the Keychain, sent only to api.anthropic.com. "
                                + "Falls back to rules on timeout or error.")
                        }
                    }
                }

                Spacer()
            }
            .padding(DS.Space.panel)
        }
        .frame(width: 520, height: 540)
    }

    private func panel<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            Silkscreen(text: label, large: true)
            content()
        }
        .padding(DS.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrushedPanel())
    }

    private func secureField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            Silkscreen(text: label)
            SecureField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.inkOnDeck)
                .padding(.horizontal, DS.Space.snug)
                .padding(.vertical, DS.Space.snug)
                .background(DS.Color.deck, in: .rect(cornerRadius: DS.Radius.chip))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.chip)
                        .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
                )
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.label)
            .foregroundStyle(DS.Color.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

import MumbleCleanup
import SwiftUI

/// Settings — a page of the main window rather than a window of its own.
///
/// It was a separate `SwiftUI.Settings` scene, which is the conventional macOS answer and the
/// wrong one here: every setting on this page changes what the *next dictation* does, and
/// checking one meant leaving the window that shows you what the last one produced. As a page
/// it sits beside the transcripts it affects, and it scrolls with the rest of the app rather
/// than owning a scroll view and a fixed 560×620 frame.
struct SettingsPanel: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared
    @State private var apiKeyInput = APIKeyStore.storedKey ?? ""

    var body: some View {
            VStack(alignment: .leading, spacing: DS.Space.wide) {
                panel(label: "Push to talk") {
                    HStack(spacing: DS.Space.snug) {
                        ForEach(PushToTalkKey.allCases, id: \.self) { key in
                            ActionButton(
                                title: key.displayName,
                                isEngaged: settings.pushToTalkKey == key,
                                engagedColor: DS.Color.ink
                            ) {
                                settings.pushToTalkKey = key
                                controller.reloadHotkey()
                            }
                        }
                    }
                    note("Hold this key anywhere to dictate. The window's Record button works "
                        + "regardless of what's focused.")
                }

                panel(label: "Microphone") {
                    inputPicker
                    note(settings.inputDeviceUID == nil
                        ? "Following the system default, which macOS moves when a headset "
                            + "connects — including when a call takes it."
                        : "Pinned. Mumble records from this device whatever the system "
                            + "default does, so dictation keeps working while you're on a call.")
                }

                panel(label: "Model") {
                    HStack(spacing: DS.Space.snug) {
                        ForEach(SpeechEngineChoice.allCases, id: \.self) { choice in
                            ActionButton(
                                title: choice == .apple ? "Apple" : "Parakeet",
                                isEngaged: settings.engine == choice,
                                engagedColor: DS.Color.ink
                            ) {
                                settings.engine = choice
                            }
                        }
                    }
                    note(settings.engine == .apple
                        ? "Apple's on-device transcriber. Streams text while you speak; no download."
                        : "Parakeet on the Neural Engine. Resolves on release; ~470 MB model.")
                }

                panel(label: "Cleanup") {
                    Toggle(isOn: $settings.cleanupEnabled) {
                        TextLabel(text: "Clean up transcripts")
                    }
                    .toggleStyle(.switch)
                    note("Strips fillers, fixes spacing and punctuation. The dictionary's "
                        + "corrections run either way.")

                    if settings.cleanupEnabled {
                        // How far, before which engine does it. The two are independent and
                        // asking them in this order matches how people decide: you know how
                        // much help you want long before you care what runs.
                        VStack(alignment: .leading, spacing: DS.Space.snug) {
                            TextLabel(text: "How much help")
                            HStack(spacing: DS.Space.snug) {
                                ForEach(CleanupStrength.allCases, id: \.self) { level in
                                    ActionButton(
                                        title: level.displayName,
                                        isEngaged: settings.cleanupStrength == level,
                                        engagedColor: DS.Color.ink
                                    ) {
                                        settings.cleanupStrength = level
                                    }
                                }
                            }
                            note(settings.cleanupStrength.explanation)
                        }
                        .padding(.top, DS.Space.tight)

                        Divider().overlay(DS.Color.seam)

                        TextLabel(text: "What runs it")
                        HStack(spacing: DS.Space.snug) {
                            ForEach(CleanupTier.allCases, id: \.self) { tier in
                                ActionButton(
                                    title: tier.displayName,
                                    isEngaged: settings.cleanupTier == tier,
                                    engagedColor: DS.Color.ink
                                ) {
                                    settings.cleanupTier = tier
                                }
                                // Only on-device is disabled when unavailable — there's
                                // nothing to configure in-app for it. Claude must stay
                                // selectable even with no key yet, because selecting it is
                                // how the key field below appears.
                                .disabled(tier == .onDevice && FoundationModelFormatter.unavailableReason != nil)
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

            }
            // Leading, so a panel keeps its width when the stack is measured by the page's
            // scroll view rather than by a fixed frame.
            .frame(maxWidth: .infinity, alignment: .leading)
    }


    /// System default plus every connected input.
    ///
    /// Rebuilt on each appearance rather than observed: devices come and go, and a stale list
    /// here is a preference pointing at something unplugged. `AudioCapture` falls back in
    /// that case, but the picker should not be the thing that causes it.
    private var inputPicker: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            ActionButton(
                title: "System default",
                isEngaged: settings.inputDeviceUID == nil,
                engagedColor: DS.Color.ink
            ) {
                settings.inputDeviceUID = nil
                controller.reloadInputDevice()
            }

            ForEach(devices) { device in
                ActionButton(
                    title: device.name,
                    isEngaged: settings.inputDeviceUID == device.uid,
                    engagedColor: DS.Color.ink
                ) {
                    settings.inputDeviceUID = device.uid
                    controller.reloadInputDevice()
                }
            }
        }
    }

    private var devices: [AudioInputDevice] { AudioInputDevice.all }

    private func panel<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            TextLabel(text: label, large: true)
            content()
        }
        .padding(DS.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Card())
    }

    private func secureField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            TextLabel(text: label)
            Inset {
                SecureField(prompt, text: text)
                    .textFieldStyle(.plain)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                    .padding(.horizontal, DS.Space.base)
                    .padding(.vertical, DS.Space.snug)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.label)
            .foregroundStyle(DS.Color.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

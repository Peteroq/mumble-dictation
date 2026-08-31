import AppKit
import SwiftUI

@main
struct MumbleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The main window. A `Window` rather than a `WindowGroup`: this app has one front
        // panel, and letting ⌘N spawn a second copy of a tape deck makes no sense.
        Window("Mumble", id: "main") {
            MainWindow(controller: delegate.controller)
                // Transparent, so `AppBackground`'s glass is what fills the window. Without
                // this the system paints an opaque window background first and the backdrop
                // blur has nothing behind it to blur.
                .containerBackground(Color.clear, for: .window)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 860, height: 620)
        .windowResizability(.contentMinSize)
        // The app's ground is glass, and a title bar with its own material sitting on top of
        // it is a second surface with a visible seam. Hidden, the window is one plane from
        // the traffic lights down.
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Settings is a page of the main window now, so ⌘, has to route there rather
            // than open a scene. Replacing the standard item keeps the shortcut and the
            // menu position; without this the app would show a Settings item that opens
            // nothing, since there is no longer a `Settings` scene behind it.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    Navigation.shared.section = .settings
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first { $0.title == "Mumble" }?.makeKeyAndOrderFront(nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Reveal Dictionary File") {
                    NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
                }
            }
        }

        // Secondary now: status and the hotkey while you're working in another app.
        MenuBarExtra {
            MenuContent(controller: delegate.controller)
                .preferredColorScheme(.dark)
        } label: {
            Image(systemName: delegate.controller.state.isActive ? "waveform.circle.fill" : "waveform")
        }

        Window("Engine comparison", id: "comparison") {
            ComparisonWindow(controller: delegate.controller)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 640, height: 560)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DictationController()
    private var hud: HUDPanel?
    private var stateObservation: NSObjectProtocol?
    private var supervisor: Supervisor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A regular app now: dock icon, app menu, standard windows. The HUD is still a
        // non-activating panel, so dictating into another app never steals its focus — that
        // property belongs to the panel, not to the activation policy.
        NSApp.setActivationPolicy(.regular)

        // Pinned dark, on every machine, deliberately.
        //
        // The tokens in `DS.Color` each carry a light and a dark value and resolve against
        // whatever `NSAppearance` is current, which means the app looked like a different
        // product on a Mac set to Light — the same build, pulled from the same commit,
        // rendering a bright glass instead of the near-black one it is designed as. The orb's
        // palette is a violet-to-pink ramp lifted from its own shader constants, and it was
        // chosen against a dark ground; the light face was always the weaker of the two.
        //
        // Set on `NSApp` rather than per window so it reaches everything AppKit resolves for
        // us — the HUD panel, the menu bar extra, materials, and the dynamic `NSColor`
        // providers behind `DS.Color.face`. The SwiftUI side is pinned alongside it with
        // `.preferredColorScheme(.dark)`, because SwiftUI resolves its own semantic colors
        // rather than asking AppKit.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        hud = HUDPanel(controller: controller)

        if !controller.activate() {
            Permissions.promptForAccessibility()
            // The tap can only be created once the user grants Accessibility, and there's
            // no notification for that — poll until it takes.
            retryActivation()
        }

        // Write the dashboard up front so the menu item always opens something, even
        // before the first dictation.
        RunLog.regenerate()

        // Parakeet's models take ~20s to load from disk, and that cost lands on whichever
        // dictation touches them first — so the first hold after every launch would stall
        // with the HUD showing nothing. Warm them in the background instead, but only when
        // they're actually going to be used and are already downloaded.
        let willUseParakeet = Settings.shared.compareMode || Settings.shared.engine == .parakeet
        if willUseParakeet, ParakeetModels.isDownloaded {
            Task.detached(priority: .utility) {
                _ = try? await ParakeetModels.shared.manager()
            }
        }

        // Every `make install` relaunches the app and drops its windows. Restoring the
        // window when it was open last time keeps it from vanishing on each rebuild.
        if UserDefaults.standard.bool(forKey: "comparisonWindowOpen") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                Self.showComparisonWindow()
            }
        }

        observeState()

        // Started last, and started unconditionally — including when `activate` failed above,
        // because "the hotkey is not armed" is exactly one of the things it watches for and
        // it is how the app notices Accessibility being granted, or taken away, later on.
        let supervisor = Supervisor(controller: controller) { [weak self] in self?.hud }
        supervisor.start()
        self.supervisor = supervisor

        // Recorded because this is the thing that used to differ between machines, and a
        // screenshot from the other Mac is a slow way to find out which face it drew.
        Log.app.info(
            """
            appearance pinned to \(NSApp.effectiveAppearance.name.rawValue, privacy: .public) \
            (system is \(UserDefaults.standard.string(forKey: "AppleInterfaceStyle") ?? "Light", privacy: .public))
            """
        )
        Log.app.info("Mumble ready — hold \(Settings.shared.pushToTalkKey.displayName) to dictate")
    }

    /// `mumble-dictation://clear` and `mumble-dictation://show`, used by the legacy HTML
    /// dashboard and as a scriptable way to raise the window. Not bare "mumble" — that scheme
    /// belongs to the open-source Mumble VoIP client.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "mumble-dictation" {
            switch url.host {
            case "clear":
                RunLog.clear()
                RunStore.shared.reload()
            case "show":
                Self.showComparisonWindow()
            default:
                break
            }
        }
    }

    /// Raises the comparison window without needing SwiftUI's `openWindow` environment
    /// value — usable from the app delegate and from a URL handler.
    static func showComparisonWindow() {
        RunStore.shared.reload()
        if let existing = NSApp.windows.first(where: { $0.title == "Engine comparison" }) {
            existing.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        let isOpen = NSApp.windows.contains { $0.title == "Engine comparison" && $0.isVisible }
        UserDefaults.standard.set(isOpen, forKey: "comparisonWindowOpen")
        supervisor?.stop()
        controller.deactivate()
    }

    /// Shows and hides the HUD in step with the controller's state.
    private func observeState() {
        withObservationTracking {
            _ = controller.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.controller.state.showsHUD {
                    self.hud?.present()
                } else {
                    self.hud?.dismiss()
                }
                self.observeState()
            }
        }
    }

    private func retryActivation() {
        Task { @MainActor in
            while !Permissions.hasAccessibility {
                try? await Task.sleep(for: .seconds(1))
            }
            controller.activate()
            Log.app.info("Accessibility granted — hotkey armed")
        }
    }
}

private struct MenuContent: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared
    @Environment(\.openWindow) private var openWindow
    @State private var isPreloadingParakeet = false
    @State private var parakeetOnDisk = ParakeetModels.isDownloaded

    private var parakeetStatus: String {
        if isPreloadingParakeet { return "Loading Parakeet models…" }
        // Reflects what's actually on disk, not just what this menu instance has done.
        return parakeetOnDisk ? "Parakeet models installed ✓" : "Download Parakeet models…"
    }

    private func preloadParakeet() {
        guard !isPreloadingParakeet else { return }
        isPreloadingParakeet = true
        Task {
            do {
                _ = try await ParakeetModels.shared.manager()
                parakeetOnDisk = ParakeetModels.isDownloaded
            } catch {
                Log.speech.error("Parakeet preload failed: \(error.localizedDescription)")
            }
            isPreloadingParakeet = false
        }
    }

    var body: some View {
        Text("Hold \(settings.pushToTalkKey.displayName) to dictate")

        Divider()

        Picker("Push-to-talk key", selection: Binding(
            get: { settings.pushToTalkKey },
            set: { key in
                settings.pushToTalkKey = key
                controller.reloadHotkey()
            }
        )) {
            ForEach(PushToTalkKey.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }

        Toggle("Compare mode (both engines)", isOn: $settings.compareMode)

        if !settings.compareMode {
            Picker("Engine", selection: $settings.engine) {
                ForEach(SpeechEngineChoice.allCases, id: \.self) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
        }

        Toggle("Clean up text", isOn: $settings.cleanupEnabled)

        if settings.cleanupEnabled {
            Picker("Cleanup tier", selection: $settings.cleanupTier) {
                ForEach(CleanupTier.allCases, id: \.self) { tier in
                    Text(tier.displayName).tag(tier)
                        // Only on-device is disabled when unavailable — Claude has no
                        // in-menu way to add a key, so it must stay selectable; pick it
                        // here, then paste the key in Settings.
                        .disabled(tier == .onDevice && FoundationModelFormatter.unavailableReason != nil)
                }
            }
            if let reason = settings.cleanupTier.unavailableReason {
                Text(reason).font(.caption)
            }
        }

        Toggle("Sound", isOn: $settings.soundEnabled)

        Divider()

        Button("Show comparison window") {
            RunStore.shared.reload()
            openWindow(id: "comparison")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("d")

        // Downloading ~470 MB on the first hold would look like a hang, so offer to do it
        // deliberately instead.
        if settings.engine == .parakeet {
            Button(parakeetStatus) { preloadParakeet() }
                .disabled(isPreloadingParakeet || parakeetOnDisk)
        }

        if !Permissions.hasAccessibility {
            Button("Grant Accessibility…") { Permissions.openAccessibilitySettings() }
        }
        if !Permissions.hasMicrophone {
            Button("Grant Microphone…") { Permissions.openMicrophoneSettings() }
        }

        Button("Quit Mumble") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

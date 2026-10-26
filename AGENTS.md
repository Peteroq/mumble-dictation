# Mumble

Push-to-talk dictation for macOS. Hold a key, speak, release, and cleaned-up text is typed into whatever had focus. Speech stays on the Mac (Apple `SpeechAnalyzer`, or Parakeet via FluidAudio) unless the Claude cleanup tier is turned on.

The macOS app is in daily use. Bundle id `ai.pivotstudio.mumble`. Requires macOS 26, Swift tools 6.2, language mode 6.

A second app in `windows/` (C# / .NET 10, Avalonia) implements the same dictation behaviour. CI builds and tests it. A person has not yet held the key and spoken into it. Details live in `windows/README.md`.

## Layout

| Path | What |
|---|---|
| `Sources/Mumble/` | App: capture, hotkey, injection, SwiftUI, orb |
| `Sources/MumbleDictionary/` | Correction engine. Shared contract with the C# app |
| `Sources/MumbleCleanup/` | Guard that stops a model answering the dictation |
| `Sources/MumbleObjC/` | One `@try` around AVAudio exceptions Swift cannot catch |
| `Tests/` | Platform-neutral tests. They must not link the app target |
| `shared/dictionary-test-vectors.json` | Specification for correction behaviour |
| `Resources/` | `Info.plist`, `Mumble.entitlements`, icon |
| `Makefile` | Assembles and signs `Mumble.app` outside the repo |
| `.github/workflows/macos-app.yml` | App build and GitHub Release. Workflow name: `macOS app` |
| `.github/workflows/macos.yml` | `swift test` for the dictionary contract. Workflow name: `macOS` |
| `windows/` | Windows app |

`make app` stages the bundle in `~/Library/Caches/MumbleBuild`, not in the repo. A `.build/` directory inside the tree is a scratch path to avoid.

## Builds and releases

Agents cannot build this app. The owner's machine has the Command Line Tools, not full Xcode, and an agent session has no Xcode either. The app needs the macOS 26 SDK. Leave `swift build`, `make app`, and `make install` unrun. Verify through GitHub Actions.

**App and release:** `.github/workflows/macos-app.yml` on the `macos-26` runner. It selects `/Applications/Xcode.app`, runs `make app CONFIG=release FORCE_ADHOC=1`, checks an ad-hoc arm64 signature, and uploads `Mumble-<version>-<7-char-sha>-arm64.zip`.

It starts on:

- pull requests and pushes to `main` that change `Sources/**`, `Resources/**`, `Package.swift`, `Package.resolved`, `Makefile`, or `.github/workflows/macos-app.yml`
- version tags `vMAJOR.MINOR.PATCH` (tags this workflow creates, `v0.1.0-<sha>`, do not match)
- `workflow_dispatch`, input `publish_release` (boolean, default false)

A push to `main`, a version tag, or a dispatch with `publish_release=true` also attaches that zip to a GitHub Release. Pull requests upload the artifact only.

Trigger a build of the current branch without publishing:

```bash
gh workflow run macos-app.yml --ref "$(git branch --show-current)" -f publish_release=false
```

Logs, the zip name, and the release tag are in `.cursor/skills/ci-build-and-release/SKILL.md`.

**Tests:** `.github/workflows/macos.yml` runs `swift test` on `macos-15`. It does not produce `Mumble.app`.

## Conventions

- Edit correction behaviour in `shared/dictionary-test-vectors.json` first, then copy that file to `Tests/MumbleDictionaryTests/dictionary-test-vectors.json`. The Swift workflow and the Windows workflow both run it. A one-sided fix is how the two apps diverge.
- Test targets stay independent of the `Mumble` executable. Linking the app pulls FoundationModels into the test bundle, which then fails to load on the `macos-15` runner.
- Colours, sizes, radii, durations, and materials come from `Sources/Mumble/UI/DesignSystem.swift`. Palette stops come from `OrbParameters`. Views take tokens from there.
- Compare mode runs every engine on one recording and types nothing, so two transcripts cannot fight over one field.
- The app is not sandboxed. Microphone, Accessibility, Swift 6 isolation, and the API key are covered by `.cursor/rules/swift.mdc`.
- CI signs ad-hoc (`FORCE_ADHOC=1`) because the repo has no Apple Developer certificate. The `Makefile` chooses the identity. Certificates, provisioning profiles, and API keys stay out of the tree.
- On a Mac, the Windows projects that are not `net10.0-windows` build with `dotnet build windows/Mumble.CrossPlatform.slnf`. `Mumble.sln` fails there with `NETSDK1073`.

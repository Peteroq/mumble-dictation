# Mumble

Push-to-talk dictation for macOS. Hold a key, talk, let go — cleaned-up text lands in
whatever field has focus. Everything runs on your Mac unless you deliberately turn on the
Claude tier.

---

## Get started

Four steps, about five minutes, most of it Xcode downloading Swift packages.

### 1. Check the machine

```bash
git clone https://github.com/Peteroq/mumble-dictation.git
cd mumble-dictation
make doctor
```

`make doctor` tells you what's missing before you spend time on a build that can't work:

```
  macOS         26.2
  Swift         6.3.3
  Developer dir /Applications/Xcode.app/Contents/Developer
  Signing       Apple Development: Your Name (TEAMID)
  Installed     not yet — run 'make install'
```

You need **macOS 26 or later** and **Xcode** (not just the Command Line Tools — they can't
build a SwiftUI app). If `doctor` reports the developer directory as `CommandLineTools`:

```bash
sudo xcode-select -s /Applications/Xcode.app
```

### 2. Build and install

```bash
make install
```

Builds, assembles a real `.app`, signs it, copies it to `/Applications`, and launches it.

### 3. Grant two permissions

Neither can be requested silently, and the app is deaf and mute without them.

| Permission | Where | Needed for |
|---|---|---|
| **Accessibility** | System Settings ▸ Privacy & Security ▸ Accessibility ▸ **+** ▸ Mumble | Seeing the hotkey anywhere, and typing text into the focused app |
| **Microphone** | Prompted on your first recording | Recording you |

**Quit and reopen Mumble after granting Accessibility.** The event tap is created at launch.

### 4. Talk

Hold **fn** (or Right ⌥ / Right ⌘ — pick one in Settings) anywhere on the system and speak.
Let go and the text is typed where your cursor is.

Or **double-tap** the key to keep the mic open with nothing held, and tap once more to stop.

---

## If something doesn't work

**The hotkey does nothing.** Accessibility was granted but Mumble wasn't relaunched, or the
grant got wedged. Reset just that row and re-add it:

```bash
tccutil reset Accessibility ai.pivotstudio.mumble
```

> Always pass the bundle ID. A bare `tccutil reset Accessibility` wipes **every app on the
> machine.** Quit System Settings entirely (⌘Q) before reopening — that pane caches its list
> and will otherwise show the row you just deleted.

**The hotkey worked and then stopped after a rebuild.** You're on an ad-hoc signature. macOS
keys permissions to the *code signature*, and an ad-hoc one changes on every single build,
so the app you rebuilt is a different app as far as the system is concerned. The symptom is
nasty: the Accessibility toggle still reads **on** while the app is untrusted.

```bash
make signing
```

prints which identity you have and, if there isn't one, the two ways to get a stable one —
signing in to Xcode with any Apple ID, or making a self-signed certificate in Keychain
Access. Either works; you only have to do it once.

**Nothing is transcribed on the first run.** macOS downloads the speech model for your
locale the first time it's needed. Give it a minute and try again.

**You already run another dictation app.** Give each a different push-to-talk key. Two apps
on one key both record, and whichever types first fights the other. Mumble's event tap
inspects only its own keycode and passes everything else through.

---

## What it does

**Dictate anywhere.** A `CGEventTap` sees the hotkey no matter which app is focused. The HUD
is a non-activating panel, so your text field never loses focus and there is always
something to type into.

**Clean up what you said.** Cleanup has two independent controls, in Settings:

- *How much help* — **Light** fixes punctuation and keeps every word; **Standard** also
  removes fillers and applies spoken corrections ("send it Tuesday, actually Wednesday");
  **Polished** also repairs grammar and tightens phrasing.
- *What runs it* — **Rules** (deterministic, instant, no model), **On-device AI** (Apple's
  Foundation Models), or **Claude** (needs an API key; the only path that leaves your Mac).

Whatever you pick, a guard checks the result is recognisably a cleaned version of what you
said and falls back to the rules if it isn't. That check is what stops a model *answering*
your dictation instead of cleaning it — dictate "what is the capital of france" and you get
your sentence back, not "Paris".

**Teach it your words.** The Dictionary holds terms to bias the recogniser toward
("Anthropic", "Supabase") and correction pairs ("cloud code" → "Claude Code"). Highlight a
word in any past transcript to teach it on the spot. It's a plain text file you can also
edit by hand; the app picks up changes live.

**Keep your prompts.** Dictating a long instruction is the fast way to write one, so any
transcript can be saved to the Prompts tab with one click, then organised into folders,
tagged, and searched.

**Two speech engines.** Apple's `SpeechAnalyzer` (default — streams text while you talk, no
download) or Parakeet v3 on the Neural Engine (more accurate on English, resolves on
release, ~470 MB). Switch in Settings.

---

## Everyday commands

| | |
|---|---|
| `make install` | build, sign, install to `/Applications`, launch |
| `make doctor` | preflight: OS, toolchain, signing, install state |
| `make signing` | which identity signs the app, and how to get one |
| `make run` | run from the staging directory without installing |
| `make app` | build the bundle only |
| `make clean` | remove all build products |
| `swift test` | run the test suites |

Build products and the staged `.app` live in `~/Library/Caches/MumbleBuild`, deliberately
outside the repo: iCloud-synced folders mutate files inside a bundle and break its
signature.

---

## How it fits together

```
 hold key ─► HotkeyMonitor ──► DictationController ◄── Settings
                                │
                     ┌──────────┼──────────┐
                     ▼          ▼          ▼
              AudioCapture  HUDPanel   TranscriptionEngine
                     │                      │
                (AudioChunk) ──ordered──► Apple / Parakeet
                                            │
                                       (transcript)
                                            ▼
                                   Dictionary ─► TextFormatter ─► CleanupGuard
                                                                       ▼
                                                        TextInjector ─► focused app
```

```
Sources/Mumble/
├── MumbleApp.swift          @main, AppDelegate, MenuBarExtra
├── Core/                    hotkey, capture, dictation state machine, injection
├── Transcription/           TranscriptionEngine protocol, Apple + Parakeet
├── Formatting/              TextFormatter protocol, rules / on-device / Claude, CleanupGuard
├── Dictionary/              the store behind MumbleDictionary
├── Prompts/                 prompt library model and store
├── Orb/                     the Metal orb: renderer, shaders, tuned parameters
├── UI/                      main window, settings page, HUD, design system
└── Support/                 settings, logging, permissions, run log
```

### Decisions worth knowing before you change anything

**The HUD must never take focus.** `HUDPanel` is a `.nonactivatingPanel` with
`canBecomeKey == false`. If the overlay took key status the user's text field would lose
focus and there'd be nothing left to type into. Everything else here is replaceable.

**The hotkey needs a `CGEventTap`.** `fn` and left/right modifier discrimination don't
surface through `NSEvent` or the Carbon hotkey API. That's why Accessibility is a hard
requirement and not a nicety.

**`AVAudioEngine` already follows the system default input.** An earlier version pinned the
input node with `setDeviceID` and broke AirPods entirely — it knocks the node off the
default-device aggregate and the tap captures nothing. Pinning is opt-in, for the case where
a call takes your headset and you want dictation to stay on the laptop mic.

**Audio ordering is explicit.** Buffers go through an `AsyncStream` drained by one task.
A `Task` per buffer would be simpler and would silently scramble the transcript.

**Buffers are copied, never borrowed.** `AVAudioEngine` recycles the buffer it hands a tap
the moment the callback returns.

**The orb's parameters are pixel-absolute.** Dot size is a point sprite measured in pixels,
so `OrbRenderer` scales it against the size the parameters were tuned at. Render it smaller
without that and the sphere fills in solid.

---

## Also in this repo

- `Sources/MumbleDictionary/` — the dictionary engine as its own target, because its
  behaviour is a cross-platform contract. `Tests/MumbleDictionaryTests` runs the vectors in
  `shared/dictionary-test-vectors.json`, and the Windows app runs the same file.
- `windows/` — an Avalonia port sharing those vectors. See `windows/README.md`.
- `bench/` — a standalone benchmark package.
- `prototypes/orb-lab.html` — the WebGL lab the orb was designed in, with every parameter on
  a slider. The Metal renderer is a port of it.
- `docs/PARAKEET-WINDOWS.md` — model acquisition notes.

## Requirements

macOS 26+, Xcode with a Swift 6.2 toolchain, Apple silicon recommended (the orb and Parakeet
both want the GPU and Neural Engine).

---
name: ci-build-and-release
description: >-
  Trigger the macOS app GitHub Actions workflow
  (.github/workflows/macos-app.yml), read its logs, and download the
  Mumble.app zip from the run artifact or the GitHub Release. Use when a
  change needs a build or a release and a local Xcode build is unavailable.
---

# CI build and release

Repo: `Peteroq/mumble-dictation`. Workflow file: `.github/workflows/macos-app.yml`. Workflow name: `macOS app` (id `389888141`). Job name: `Build Mumble.app`. Runner: `macos-26`. Timeout: 45 minutes.

This is the only way to compile `Mumble.app` from an agent session. The owner's machine has Command Line Tools only, and agent sessions have no Xcode. The package requires the macOS 26 SDK. Leave `swift build` and `make` unrun.

The other workflow named `macOS` (`.github/workflows/macos.yml`) runs `swift test` on `macos-15`. It produces no app and no release.

Commands assume `gh` is already authenticated. The workflow's own `GH_TOKEN` is `github.token` with `contents: write`. Do not mint a token for these commands.

## When a run starts by itself

`macos-app.yml` runs on a pull request or a push to `main` only when the change touches one of:

- `Sources/**`
- `Resources/**`
- `Package.swift`
- `Package.resolved`
- `Makefile`
- `.github/workflows/macos-app.yml`

A docs-only or `.cursor/` change does not start it. Concurrency group `macos-app-macOS app-<ref>` cancels the previous run on that ref.

Pull request runs check out `github.event.pull_request.head.sha` (the branch commit), not the synthetic merge commit, and stamp that sha into the zip.

## Trigger

Push the branch first. `workflow_dispatch` runs the workflow file that is already on that remote ref. This dispatch does not publish a release (`publish_release` defaults to false; the workflow compares the input to the string `true`).

```bash
gh workflow run macos-app.yml --repo Peteroq/mumble-dictation \
  --ref "$(git branch --show-current)" \
  -f publish_release=false
```

Publish only when a release was requested:

```bash
gh workflow run macos-app.yml --repo Peteroq/mumble-dictation \
  --ref "$(git branch --show-current)" \
  -f publish_release=true
```

`gh workflow run` prints the run URL when GitHub has created it. If it does not, list the newest dispatch on that branch:

```bash
gh run list --repo Peteroq/mumble-dictation \
  --workflow macos-app.yml \
  --branch "$(git branch --show-current)" \
  --limit 5
```

Match `event` `workflow_dispatch` and the branch. A pull request may also have an older `pull_request` run for the same branch; use the id from the dispatch you just started.

## Read the logs

```bash
gh run watch <run-id> --repo Peteroq/mumble-dictation --exit-status
gh run view <run-id> --repo Peteroq/mumble-dictation
gh run view <run-id> --repo Peteroq/mumble-dictation --log-failed
```

`--log` prints the full log. Steps, in order: **Select Xcode**, **Build the app**, **Verify and zip**, **Upload the zip**, **Publish GitHub Release** (skipped unless this run is allowed to publish).

Select Xcode fails closed when `sw_vers` is below 26 or `/Applications/Xcode.app` is missing. It pins `xcode-select` to `/Applications/Xcode.app/Contents/Developer` (the image's stable Xcode, not a preview that sorts later).

Build the app is:

```bash
make app CONFIG=release FORCE_ADHOC=1 \
  SOURCE_COMMIT="$SOURCE_SHA" \
  SOURCE_REF="$SOURCE_REF" \
  BUILD_NUMBER="$GITHUB_RUN_NUMBER" \
  SOURCE_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
```

`SOURCE_SHA` is the pull request head sha, otherwise `github.sha`. The bundle is `$HOME/Library/Caches/MumbleBuild/Mumble.app`.

Verify and zip fails the run unless all of these hold:

- `Contents/MacOS/Mumble` exists and `codesign --verify --deep --strict` passes
- the signature is ad-hoc
- `lipo -archs` is `arm64`
- dependency lines from `otool -L` do not mention `MumbleBuild`, `/Users/runner/work`, or `.build/` (the first line is the binary itself and is ignored)
- `MumbleSourceCommit` in Info.plist equals `SOURCE_SHA`, and `Contents/Resources/VERSION.txt` contains that sha
- `CFBundleVersion` equals `GITHUB_RUN_NUMBER`
- the ditto zip round-trips `codesign --verify` and the same commit stamp

The marketing version (`CFBundleShortVersionString`) stays whatever `Resources/Info.plist` says. The run number becomes `CFBundleVersion`.

## Find the zip

Artifact name and zip name are the same string:

```text
Mumble-<CFBundleShortVersionString>-<first 7 of SOURCE_SHA>-arm64.zip
```

`gh run download` unwraps GitHub's artifact archive and leaves that zip in the output directory. The workflow uploads with `compression-level: 0` because the payload is already a `ditto` zip (plain `zip` would strip the signature).

```bash
gh api repos/Peteroq/mumble-dictation/actions/runs/<run-id>/artifacts \
  --jq '.artifacts[] | {name,expired,size_in_bytes}'

gh run download <run-id> --repo Peteroq/mumble-dictation \
  -n "<artifact name>" \
  --dir dist
```

The run's step summary repeats the name and the same download command. The web log is `https://github.com/Peteroq/mumble-dictation/actions/runs/<run-id>`.

Shape, from the successful `main` push run `39450226575` (commit `9d03a5ab2f43f34a50b37813080e12b3e3c3d8d4`, version `0.1.0`):

| | |
|---|---|
| Artifact | `Mumble-0.1.0-9d03a5a-arm64.zip` |
| Release tag | `v0.1.0-9d03a5a` |
| Release title | `Mumble 0.1.0 (9d03a5a)` |

Read the name from the run you just watched. That zip is an example of the pattern, not a pin.

## Find the GitHub Release

**Publish GitHub Release** runs only when:

- the event is `push` and the ref is `refs/heads/main` or `refs/tags/v*`, or
- the event is `workflow_dispatch` and `publish_release` is `true`

On an exact version tag (`v1.2.3`), the release tag is that tag. Every other publish uses `v<version>-<7-char-sha>`, for example `v0.1.0-9d03a5a`. Those build tags do not match the workflow's tag filter, so creating the release does not start another build. A second run of the same commit updates the asset in place (`gh release upload --clobber`).

The step prints `Release: https://github.com/Peteroq/mumble-dictation/releases/tag/<tag>`.

```bash
gh release view <tag> --repo Peteroq/mumble-dictation
gh release download <tag> --repo Peteroq/mumble-dictation \
  --pattern 'Mumble-*-arm64.zip' \
  --dir dist
```

Latest release on the repo, after a `main` push has published:

```bash
gh release view --repo Peteroq/mumble-dictation
gh release download --repo Peteroq/mumble-dictation \
  --pattern 'Mumble-*-arm64.zip'
```

A pull request run has an artifact and no release. Skip `gh release view` for that run.

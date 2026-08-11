# Octo – Dev Notes for Agents

This file provides guidance for coding agents working in this repo.

## Project Overview

Octo is a macOS menu bar application for on‑device voice‑to‑text. It supports Whisper (Core ML via WhisperKit) and Parakeet TDT v3 (Core ML via FluidAudio). Users activate transcription with hotkeys; text can be auto‑pasted into the active app.

## UX Changes

Changes to existing user experience must be explicitly confirmed by the user. Never change existing UX autonomously.

## Build & Development Commands

Local Debug builds may only be run when the user explicitly requests them.

All checkouts and agent threads share one canonical Debug bundle. Never run a raw
Debug `xcodebuild`, override its output paths, or launch a wildcard DerivedData path.
The wrapper serializes concurrent builds so separate worktrees overwrite the same
bundle instead of creating additional app locations and permission entries.

```bash
# Local development build (the default for feature work): uses Apple Development signing
# so macOS TCC permissions such as Accessibility and Input Monitoring remain stable.
# Do not run tests, archives, Developer ID signing, DMGs, or release builds unless explicitly requested.
./dev/build-debug.sh

# Compile-only fallback for machines without an Apple Development identity.
# Do not use this build to validate macOS permission registration.
./dev/build-debug.sh --unsigned

# Build and launch the one canonical locally built bundle
./dev/build-debug.sh --launch

# Canonical app path (shared by the main checkout and every worktree)
open ~/Library/Developer/Xcode/DerivedData/OctoDebugShared/Build/Products/Debug/'Octo Debug.app'

# Tests are opt-in only: run them only when the user explicitly asks.
# Unit tests (must be run from HexCore directory)
cd HexCore && swift test

# Or run all tests via Xcode
./dev/build-debug.sh --test

# Open in Xcode (recommended for development)
open Hex.xcodeproj
```

### Xcode 26 / macOS Tahoe local-build hang

On macOS Tahoe 26.4.1, `SWBBuildService` can hang before compilation while running
`clang -v -E -dM` SDK probes. This is an Xcode build-service issue, not a Hex source,
signing, or packaging failure. If the local Debug build stops after `CreateBuildDescription`,
leave that build running and kill only the stuck probe processes, then let it continue:

```bash
ps -axo pid=,command= | awk '$0 ~ /\/clang -v -E -dM/ {print $1}' | xargs -r kill -9
```

Do not switch to `xcodebuild test`, a Release build, cleaning DerivedData, or a release
workflow to work around this. Restarting the Mac is a last resort; restarting Xcode is
irrelevant when only command-line builds are running.

## Architecture

The app uses **The Composable Architecture (TCA)** for state management. Key architectural components:

### Features (TCA Reducers)
- `AppFeature`: Root feature coordinating the app lifecycle
- `TranscriptionFeature`: Core recording and transcription logic
- `SettingsFeature`: User preferences and configuration
- `HistoryFeature`: Transcription history management

### Dependency Clients
- `TranscriptionClient`: WhisperKit integration for ML transcription
- `RecordingClient`: AVAudioRecorder wrapper for audio capture
- `PasteboardClient`: Clipboard operations
- `KeyEventMonitorClient`: Global hotkey monitoring via Sauce framework

### Key Dependencies
- **WhisperKit**: Core ML transcription (tracking main branch)
- **FluidAudio (Parakeet)**: Core ML ASR (multilingual) default model
- **Sauce**: Keyboard event monitoring
- **Sparkle**: Auto-updates (feed: https://blackforestboi.github.io/Octo/appcast.xml)
- **Swift Composable Architecture**: State management
- **Inject** Hot Reloading for SwiftUI

## Important Implementation Details

1. **Hotkey Recording Modes**: The app supports both press-and-hold and double-tap recording modes, implemented in `HotKeyProcessor.swift`. See `docs/hotkey-semantics.md` for detailed behavior specifications including:
   - **Modifier-only hotkeys** (e.g., Option) use a **0.3s threshold** to prevent accidental triggers from OS shortcuts
   - **Regular hotkeys** (e.g., Cmd+A) use user's `minimumKeyTime` setting (default 0.2s)
   - Mouse clicks and extra modifiers are discarded within threshold, ignored after
   - Only ESC cancels recordings after the threshold

2. **Model Management**: Models are managed by `ModelDownloadFeature`. Curated defaults live in `Hex/Resources/Data/models.json`. The Settings UI shows a compact opinionated list (Parakeet + three Whisper sizes). No dropdowns.

3. **Sound Effects**: Audio feedback is provided via `SoundEffect.swift` using files in `Resources/Audio/`

4. **Window Management**: Uses an `InvisibleWindow` for the transcription indicator overlay

5. **Permissions**: Requires audio input and automation entitlements (see `Hex.entitlements`)

6. **Logging**: All diagnostics should use the unified logging helper `HexLog` (`HexCore/Sources/HexCore/Logging.swift`). Pick an existing category (e.g., `.transcription`, `.recording`, `.settings`) or add a new case so Console predicates stay consistent. Avoid `print` and prefer privacy annotations (`, privacy: .private`) for anything potentially sensitive like transcript text or file paths.

## Models (2025‑11)

- Default: Parakeet TDT v3 (multilingual) via FluidAudio
- Additional curated: Whisper Small (Tiny), Whisper Medium (Base), Whisper Large v3
- Note: Distil‑Whisper is English‑only and not shown by default

### Storage Locations

- WhisperKit models
  - `~/Library/Application Support/io.github.blackforestboi.Octo/models/argmaxinc/whisperkit-coreml/<model>`
- Parakeet (FluidAudio)
  - We set `XDG_CACHE_HOME` on launch so Parakeet caches under the app container:
  - `~/Library/Containers/io.github.blackforestboi.Octo/Data/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml`
  - Legacy `~/.cache/fluidaudio/Models/…` is not visible to the sandbox; re‑download or import.

### Progress + Availability

- WhisperKit: native progress
- Parakeet: best‑effort progress by polling the model directory size during download
- Availability detection scans both `Application Support/FluidAudio/Models` and our app cache path

## Building & Running

- macOS 14+, Xcode 15+

### Packages

- WhisperKit: `https://github.com/argmaxinc/WhisperKit`
- FluidAudio: `https://github.com/FluidInference/FluidAudio.git` (link `FluidAudio` to Hex target)

### Signing and Entitlements

- App Sandbox is disabled because Octo uses Accessibility APIs for focused-field and selected-text handling. Sandboxed apps cannot register for Accessibility access.
- Hardened Runtime remains enabled for Developer ID distribution and notarization.
- `com.apple.security.network.client = true` (HF downloads)
- `com.apple.security.files.user-selected.read-write = true` (optional import)
- `com.apple.security.automation.apple-events = true` (media control)

### Cache root (Parakeet)

Set at app launch and logged:

```
New installs: ~/Library/Application Support/io.github.blackforestboi.Octo/cache
Existing installs: ~/Library/Containers/io.github.blackforestboi.Octo/Data/Library/Application Support/io.github.blackforestboi.Octo/cache
```

FluidAudio models reside under `Application Support/FluidAudio/Models`.

## UI

- Settings → Transcription Model shows a compact list with radio selection, accuracy/speed dots, size on right, and trailing menu / download‑check icon.
- Context menu offers Show in Finder / Delete.

## Troubleshooting

- Missing or repeated permission registration during debug: unsigned `CODE_SIGNING_ALLOWED=NO` builds use an ad-hoc linker signature and are not suitable for testing TCC permissions. Run from Xcode with Apple Development signing, or test a Developer ID-signed release build.
- Sandbox network errors (‑1003): add `com.apple.security.network.client = true` (already set)
- Parakeet not detected: ensure it resides under the container path above; downloading from Hex places it correctly.

## Changelog Workflow Expectations

1. **Always add a changeset:** Any feature, UX change, or bug fix that ships to users must come with a `.changeset/*.md` fragment. The summary should mention the user-facing impact plus the GitHub issue/PR number (for example, "Improve Fn hotkey stability (#89)").
2. **Use non-interactive changeset creation:** AI agents should use the non-interactive script:
   ```bash
   bun run changeset:add-ai patch "Your summary here"
   bun run changeset:add-ai minor "Add new feature"
   bun run changeset:add-ai major "Breaking change"
   ```
3. **Only create changesets, don't process them:** Agents should only create changeset fragments. The release tool is responsible for running `changeset version` to collect changesets into `CHANGELOG.md` and syncing to `Hex/Resources/changelog.md`.
4. **Reference GitHub issues:** When a change addresses a filed issue, link it in code comments and the changeset entry (`(#123)`) so release notes and Sparkle updates point users back to the discussion. If the work should close an issue, include "Fixes #123" (or "Closes #123") in the commit or PR description so GitHub auto-closes it once merged.

## Git Commit Messages

- Use a concise, descriptive subject line that captures the user-facing impact (roughly 50–70 characters).
- Follow up with as much context as needed in the body. Include the rationale, notable tradeoffs, relevant logs, or reproduction steps—future debugging benefits from having the full story directly in git history.
- Reference any related GitHub issues in the body if the change tracks ongoing work.

## Releasing a New Version

Releases are automated via `release/local-release.sh`. The canonical entrypoint
is `bun run release`; `--local-build` selects local archive, signing,
notarization, stapling, and packaging while the rest of the release flow remains
unchanged. `bun run release:local` is a convenience alias.

### Prerequisites

1. **Developer ID signing** must be available for team `5YUPQC9D96`.

2. **Notarization credentials** must be stored in the keychain (one-time setup):
   ```bash
   xcrun notarytool store-credentials "AC_PASSWORD"
   ```

3. **GitHub CLI** must be authenticated with repository write access.

4. **Dependencies installed** at project root:
   ```bash
   bun install
   ```

### Release Steps

1. **Ensure all changes are committed** - the release tool requires a clean working tree

2. **Run a Release compile preflight before pushing a release tag** - this catches
   macOS deployment-target availability errors and Swift type-checking failures
   before the signed local archive begins:
   ```bash
   xcodebuild -scheme Octo -configuration Release \
     -skipMacroValidation -skipPackagePluginValidation \
     ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
     CODE_SIGNING_ALLOWED=NO build
   ```
   Fix all compiler errors first. In particular, guard APIs introduced after the
   macOS 14 deployment target with `#available` and keep numeric animation
   expressions explicit when Swift cannot infer a single numeric type.

3. **Prepare the release metadata** - apply pending changesets, sync the
   changelog, and commit the release version before invoking the publisher. The
   command requires `CFBundleShortVersionString` to already match the tag.

4. **Run the release command** from project root:
   ```bash
   bun run release -- --local-build --tag v<version> --publish
   ```

### What the Release Tool Does

1. Checks for a clean default-branch working tree
2. Verifies that the tag matches `CFBundleShortVersionString` and that the
   project and plist build metadata agree
3. For a new tag, increments the Sparkle build number when it is
   not newer than the live or committed appcast
4. Archives an Apple Silicon-only (`arm64`) app with xcodebuild using the persistent
   Release DerivedData cache; version/build-number edits do not invalidate it,
   and it clears that cache only when dependency inputs or the Xcode toolchain
   fingerprint changes
5. Re-signs and validates the app, notarizes the app and DMG, and creates the
   ZIP and DMG locally
6. Verifies the archived app and generated appcast contain matching release and
   build values
7. Creates or updates the GitHub Release and commits the signed appcast

### Artifacts

Each release produces Apple Silicon-only artifacts:
- `Octo-{version}.dmg` - Signed, notarized DMG
- `Octo-{version}.zip` - For Homebrew cask
- `appcast.xml` - Sparkle update feed

### Troubleshooting

- **"Working tree is not clean"**: Commit or stash all changes before releasing
- **Notarization fails**: Check Apple ID credentials and app-specific password
- **GitHub upload fails**: Verify `gh auth status` and repository write access
- **Build fails**: Ensure Xcode 16+ and valid code signing certificates

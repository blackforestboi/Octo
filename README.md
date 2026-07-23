# Octo — Voice → Text

Press-and-hold a hotkey to transcribe your voice and paste the result wherever you're typing.

**[Download Octo for macOS](https://github.com/blackforestboi/Octo/releases/latest)**

> **Note:** Octo is currently only available for **Apple Silicon** Macs.

Octo is an independently maintained fork of [Hex](https://github.com/kitlangton/Hex) by Kit Langton. It has substantially evolved while retaining the upstream MIT license and its attribution. Octo supports both [Parakeet TDT v3](https://github.com/FluidInference/FluidAudio) via [FluidAudio](https://github.com/FluidInference/FluidAudio) and [WhisperKit](https://github.com/argmaxinc/WhisperKit) for on-device transcription. It uses [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) for state management.

## Instructions

Once you open Octo, you'll need to grant it microphone and accessibility permissions—so it can record your voice and paste the transcribed text into any application, respectively.

Once you've configured a global hotkey, there are **two recording modes**:

1. **Press-and-hold** the hotkey to begin recording, say whatever you want, and then release the hotkey to start the transcription process. 
2. **Double-tap** the hotkey to *lock recording*, say whatever you want, and then **tap** the hotkey once more to start the transcription process.

## Contributing

**Issue reports are welcome!** If you encounter bugs or have feature requests, please [open an issue](https://github.com/blackforestboi/Octo/issues).

**Note on Pull Requests:** At this stage, I'm not actively reviewing code contributions for significant features or core logic changes. The project is evolving rapidly and it's easier for me to work directly from issue reports. Bug fixes and documentation improvements are still appreciated, but please open an issue first to discuss before investing time in a large PR. Thanks for understanding!

### Changelog workflow

- **For AI agents:** Run `bun run changeset:add-ai <type> "summary"` (e.g., `bun run changeset:add-ai patch "Fix clipboard timing"`) to create a changeset non-interactively.
- **For humans:** Run `bunx changeset` when your PR needs release notes. Pick `patch`, `minor`, or `major` and write a short summary—this creates a `.changeset/*.md` fragment.
- Check what will ship with `bunx changeset status --verbose`.
- `npm run sync-changelog` (or `bun run tools/scripts/sync-changelog.ts`) mirrors the root `CHANGELOG.md` into `Hex/Resources/changelog.md` so the in-app sheet always matches GitHub releases.
- The release tool consumes the pending fragments, bumps `package.json` + `Info.plist`, regenerates `CHANGELOG.md`, and feeds the resulting section to GitHub + Sparkle automatically. Releases fail fast if no changesets are queued, so you can't forget.
- If you truly need to ship without pending Changesets (for example, re-running a failed publish), the release script will now prompt you to confirm and choose a `patch`/`minor`/`major` bump interactively before continuing.

## Attribution and license

Octo is licensed under the MIT License. The original copyright notice for Hex by Kit Langton remains in [LICENSE](LICENSE), as required by that license.

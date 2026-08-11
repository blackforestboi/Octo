# Octo — Voice → Text

Press-and-hold a hotkey to transcribe your voice and paste the result wherever you're typing.

**[Download Octo for macOS](https://github.com/blackforestboi/Octo/releases/latest)**

> **Note:** Octo is currently only available for **Apple Silicon** Macs.

> **Fork notice:** Octo is a new project based on a fork of [Hex](https://github.com/kitlangton/Hex) by Kit Langton. It retains Hex's MIT license and attribution while developing independently under the Octo name.

Octo supports both [Parakeet TDT v3](https://github.com/FluidInference/FluidAudio) via [FluidAudio](https://github.com/FluidInference/FluidAudio) and [WhisperKit](https://github.com/argmaxinc/WhisperKit) for on-device transcription. It uses [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) for state management.

## What Octo improves

- Refine selected text from the current screen or a selected portion of the screen using custom prompts.
- Use your own OpenAI or cloud subscription for AI workflows.
- Use OpenRouter, OpenAI, and direct cloud APIs for AI workflows.
- Enjoy an improved recording pill and recording indicator.
- Keep an extensive history of everything recorded, transcribed, or processed by AI, including every output.
- Rely on a more fail-safe recording, transcription, and AI-processing workflow.
- Reposition and resize the recording indicator to fit your workspace.

## Instructions

Once you open Octo, you'll need to grant it microphone and accessibility permissions—so it can record your voice and paste the transcribed text into any application, respectively.

Once you've configured a global hotkey, there are **three recording modes**:

1. **Press-and-hold** the hotkey to begin recording, say whatever you want, and then release the hotkey to start the transcription process. 
2. **Single-tap** the hotkey to start and lock recording, then tap it once more to finish.
3. **Double-tap** the hotkey to *lock recording*, say whatever you want, and then **tap** the hotkey once more to start the transcription process.

## Contributing

**Issue reports are welcome!** If you encounter bugs or have feature requests, please [open an issue](https://github.com/blackforestboi/Octo/issues).

**Note on Pull Requests:** At this stage, I'm not actively reviewing code contributions for significant features or core logic changes. The project is evolving rapidly and it's easier for me to work directly from issue reports. Bug fixes and documentation improvements are still appreciated, but please open an issue first to discuss before investing time in a large PR. Thanks for understanding!

### Changelog workflow

- **For AI agents:** Run `bun run changeset:add-ai <type> "summary"` (e.g., `bun run changeset:add-ai patch "Fix clipboard timing"`) to create a changeset non-interactively.
- **For humans:** Run `bunx changeset` when your PR needs release notes. Pick `patch`, `minor`, or `major` and write a short summary—this creates a `.changeset/*.md` fragment.
- Check what will ship with `bunx changeset status --verbose`.
- `npm run sync-changelog` (or `bun run tools/scripts/sync-changelog.ts`) mirrors the root `CHANGELOG.md` into `Hex/Resources/changelog.md` so the in-app sheet always matches GitHub releases.
- Build and notarize releases locally through the canonical flow with `bun run release -- --local-build --tag v<version> --publish`. It uploads the completed ZIP and DMG to GitHub Releases and commits the signed Sparkle appcast; GitHub Actions only deploys that static feed to Pages. `bun run release:local -- --tag v<version> --publish` is a convenience alias.
- The local command is production-only and refuses to create a tag, GitHub Release, or appcast update without `--publish`.

## Attribution and license

Octo is licensed under the MIT License. The original copyright notice for Hex by Kit Langton remains in [LICENSE](LICENSE), as required by that license.

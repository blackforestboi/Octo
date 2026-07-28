---
title: Menu Bar Refinement Model Picker - Plan
type: feat
created_at: 2026-07-28
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Menu Bar Refinement Model Picker - Plan

## Goal Capsule

- **Objective:** Add a native hover-opened submenu to Octo's menu-bar menu for viewing and changing the model used by the currently selected refinement provider.
- **Authority:** The user's requested label, hover behavior, provider scoping, and replacement semantics are authoritative; existing refinement settings and catalog clients define persistence and model availability.
- **Execution profile:** Extend the SwiftUI `MenuBarExtra` content, reuse the shared `HexSettings` value and existing provider catalogs, add focused app-target regression coverage, and ship a patch changeset.
- **Stop conditions:** Do not add a provider picker, change transcription-model selection, change screen-aware fallback models, alter provider authentication, or redesign the Settings model pickers.
- **Tail ownership:** The executor owns implementation, focused verification, the required changeset, commit, push, pull request, and CI follow-through.

## Product Contract

### Summary

Octo's menu-bar menu will include a `Model: [current model]` item for the active refinement provider. Because the item is implemented as a native submenu, hovering over it opens the provider's available text-model list without requiring a click. Choosing a model persists it in the existing provider-specific settings slot, replaces the previous selection, updates the menu label, and affects subsequent refinement requests.

### Problem Frame

Changing refinement models currently requires opening Settings and then opening a separate picker. The menu bar already exposes the refinement action, but it does not expose the model that action will use or provide a quick way to switch it.

### Requirements

**Menu behavior**

- R1. The main menu contains an item labeled `Model: [current model]`, where the suffix reflects the active refinement provider's current selection or provider default.
- R2. Hovering the model item opens a submenu through native macOS menu behavior; opening the submenu must not require clicking the parent item.
- R3. The submenu lists all text models from the selected refinement provider's current successful catalog response. OpenRouter may show its last known cached catalog while refreshing, but cached rows become non-selectable if the refresh fails.
- R4. The current model is exposed with native selected semantics in the submenu. If the saved model is absent from the successful catalog, it remains the parent title and appears as a disabled checked `[model] (Unavailable)` row until the user selects an available replacement.

**Selection and persistence**

- R5. Selecting a different model writes to the active provider's existing provider-specific model setting and replaces the previous value.
- R6. The parent label updates to `Model: [selected model]` after selection and subsequent refinement requests use that model.
- R7. Apple Intelligence and Gemini expose their existing fixed model/default as a single current option; direct API, OpenRouter, Codex subscription, and Claude subscription providers reuse their existing catalog behavior.

**Resilience and delivery**

- R8. Loading, missing credentials, missing CLI authentication, empty catalogs, and catalog errors leave the menu usable, communicate the specific recovery state, and never change the saved selection.
- R9. The change includes focused app-target regression coverage for provider-specific selection/title behavior and a patch changeset describing the user-facing shortcut.

### Acceptance Examples

- AE1. Given OpenRouter is selected and a catalog is available, when the user hovers `Model: Claude 3.7 Sonnet`, the submenu opens and lists the catalog's text models with Claude 3.7 Sonnet checked.
- AE2. Given OpenAI is selected, when the user chooses `gpt-5.4`, the OpenAI model setting becomes `gpt-5.4`, the prior OpenAI selection is replaced, and the parent item reads `Model: gpt-5.4`.
- AE3. Given the active provider changes from OpenAI to Claude subscription, when the menu is next presented, the title and submenu use the Claude subscription selection and catalog rather than the OpenAI selection.
- AE4. Given a direct provider has no stored API key or its catalog request fails, when the menu opens, the saved model remains unchanged and the submenu displays a non-selectable unavailable state.
- AE5. Given Apple Intelligence is selected, when the submenu opens, it shows the Apple Intelligence default as the sole checked option.
- AE6. Given an OpenRouter cache is shown while refreshing and the refresh fails, when the failure state appears, the cached rows remain visible but cannot be selected because their current availability is unverified.

### Scope Boundaries

- The selected provider remains controlled in Settings.
- This picker controls refinement models, not local Whisper or Parakeet transcription models.
- Screen-aware fallback image-model selection remains unchanged.
- Existing Settings pickers, API-key storage, CLI authentication, and remote catalog endpoints remain authoritative and are not redesigned.

## Planning Contract

### Key Technical Decisions

- **Use a SwiftUI `Menu` inside `MenuBarExtra`.** On macOS this renders as a native submenu, providing hover-to-open behavior and the standard submenu affordance without custom pointer handling.
- **Bind directly to shared settings.** A dedicated menu view will observe `@Shared(.hexSettings)` so provider changes and model selections update the title and future refinement requests through the same persisted source of truth used by Settings.
- **Normalize catalogs behind an injectable loader.** The menu view will map provider-specific model types from `OpenRouterModelCatalog`, `DirectProviderModelCatalog`, and `CLIRefinementClient` into stable ID/name options, while supplying fixed options for Apple Intelligence and Gemini. A narrow async loader value, defaulted to the production adapters and injectable in tests, keeps network, Keychain, and CLI work out of deterministic state tests without introducing a general catalog framework.
- **Preserve per-provider storage.** Selection applies to `openRouterModelID`, `openAIModelID`, `anthropicModelID`, `codexCLIModelID`, or `claudeCLIModelID` according to the active provider. Existing legacy fallback reads may determine an initial title, but a new selection is written to the provider's own slot.
- **Bind asynchronous work to the initiating provider.** Provider changes cancel or invalidate the prior load, immediately clear provider-mismatched options, and only publish a response when its captured provider still matches the active provider. Selection commands carry the option's provider identity rather than consulting whichever provider happens to be active when the command runs.
- **Keep failure handling local and non-destructive.** Catalog refresh errors retain both the last usable option list and the saved model, but last-known cached rows are disabled when current availability cannot be verified. Missing current IDs remain visible as disabled checked unavailable rows. No transcript, model ID, credential, or file path is logged.
- **Keep the native submenu exhaustive and deterministic.** Available rows are sorted by localized display name and then model ID. The submenu intentionally lists every model as requested; the existing Settings picker remains the searchable/sortable discovery surface for very large catalogs.
- **Use native selection semantics.** Model rows expose checked/selected state to VoiceOver and preserve standard macOS arrow-key and Return behavior rather than relying only on a decorative checkmark image.

### Assumptions

- “Selected provider” means the refinement provider configured in `HexSettings.refinementProvider`, because the requested menu sits next to `Refine Selected Text`.
- “All models currently available” means text-capable models exposed by the same provider catalog already used by the Settings picker.
- The submenu may briefly show a loading row while a dynamic provider catalog is fetched; fixed providers render immediately and OpenRouter can seed from its existing cache.
- The repository's test commands remain opt-in, so implementation adds focused coverage but final validation runs the required unsigned Debug build unless the user separately requests tests.

### Sources

- `Hex/App/HexApp.swift` defines the current `MenuBarExtra` ordering.
- `Hex/App/MenuBarRefineSelectedTextButton.swift` demonstrates app-menu access to shared refinement settings.
- `Hex/Features/Settings/RefinementSectionView.swift` defines provider-specific current-model labels and selection bindings.
- `Hex/Clients/OpenRouterModelCatalog.swift`, `Hex/Clients/DirectProviderModelCatalog.swift`, and `Hex/Clients/CLIRefinementClient.swift` are the existing model sources.
- `HexCore/Sources/HexCore/Settings/HexSettings.swift` owns provider-specific model persistence and refinement-request routing.
- `HexTests/CLIRefinementClientTests.swift` demonstrates app-target XCTest style for refinement model behavior.

### Sequencing

1. Add the normalized provider-aware model-menu component, its injectable loader seam, and focused tests.
2. Insert the component into the menu-bar menu in the requested location.
3. Add the patch changeset and run the unsigned Debug build.
4. Complete the pipeline's commit, push, pull-request, and CI follow-through stages as applicable.

## Implementation Units

### U1. Provider-aware menu model state

- **Goal:** Encapsulate current-title resolution, provider-specific catalog loading, option normalization, checked-state calculation, and selection persistence.
- **Requirements:** R1, R3, R4, R5, R6, R7, R8; AE2, AE3, AE4, AE5.
- **Files:** Create `Hex/App/MenuBarRefinementModelPicker.swift`; create `HexTests/MenuBarRefinementModelPickerTests.swift`; reuse `Hex/Clients/OpenRouterModelCatalog.swift`, `Hex/Clients/DirectProviderModelCatalog.swift`, `Hex/Clients/CLIRefinementClient.swift`, and the API-key stores without changing their public behavior.
- **Patterns:** Follow `MenuBarRefineSelectedTextButton` for `@Shared(.hexSettings)`, the Settings model pickers for catalog loading, and existing `HexTests` XCTest organization.
- **Approach:** Introduce a small normalized option model plus provider-aware helpers for current ID/title and applying a selection. Accept a narrow injected async loader whose production default adapts the existing catalogs, API-key stores, and CLI client; tests supply deterministic fixtures. Load fixed providers synchronously, seed OpenRouter from cache before refresh, and refresh direct/CLI providers asynchronously. Key every load and selection to its captured provider, cancel or discard stale completions after provider changes, retain a missing saved model as a disabled checked unavailable row, and sort available rows deterministically. Status rows use: `Loading models…`, `Add [provider] API key in Settings`, `Sign in to [provider] CLI`, `No models available`, `Couldn't load models`, or `Couldn't refresh; showing last known models`. Last-known rows are disabled after a failed refresh.
- **Test Scenarios:** Verify each provider resolves the correct stored model or default title; verify selecting an option replaces only the captured provider's model slot; verify a legacy fallback title is replaced by a new provider-specific selection; verify normalized options preserve display names and checked-state matching; verify an absent saved model produces a disabled checked unavailable row; verify fixed providers expose one checked default; verify injected loading, missing-credential, empty, error, and retained-cache results do not mutate settings; verify a stale completion after a provider switch is discarded.
- **Verification:** Focused test-source review confirms the `OctoTests` cases cover provider state without live network or CLI dependencies; the Debug app build compiles the new menu component.

### U2. Native hover submenu integration

- **Goal:** Place the model picker in the main menu with native hover behavior and live title updates.
- **Requirements:** R1, R2, R4, R6; AE1, AE2.
- **Files:** Modify `Hex/App/HexApp.swift`; use `Hex/App/MenuBarRefinementModelPicker.swift`.
- **Dependencies:** U1.
- **Patterns:** Preserve the existing `MenuBarExtra` item order and use SwiftUI's native `Menu` hierarchy.
- **Approach:** Insert the picker after `Refine Selected Text` and before navigation/settings actions. Render the required `Model: [current model]` label, make each available model a submenu command, and expose native selected semantics for the current option. Rely on the platform submenu rather than adding click or hover gesture state.
- **Test Scenarios:** Verify the view model's title changes immediately after selection; verify the compiled hierarchy uses a submenu rather than a parent button action; manually confirm hovering opens the submenu and selecting an item leaves the outer label updated on the next menu presentation; confirm keyboard navigation and VoiceOver announce the selected model.
- **Verification:** The unsigned Debug build succeeds; manual inspection of the built app confirms native hover opening, selection replacement, arrow-key/Return navigation, and selected-state announcement.

### U3. User-facing release fragment

- **Goal:** Record the new quick model switching behavior for release automation.
- **Requirements:** R9.
- **Files:** Create `.changeset/<generated-name>.md`.
- **Dependencies:** U1, U2.
- **Patterns:** Use `bun run changeset:add-ai patch` and describe the user-facing menu behavior.
- **Approach:** Generate one patch changeset after implementation using the repository's non-interactive script.
- **Test expectation:** None — this unit is release metadata only.
- **Verification:** A new changeset fragment exists and is not processed into `CHANGELOG.md`.

## Verification Contract

| Check | Applies to | Expected result |
| --- | --- | --- |
| Focused `OctoTests` source review | U1, U2 | Provider title/selection/error cases are represented without live network or CLI dependencies. |
| `xcodebuild -scheme Octo -configuration Debug -skipMacroValidation -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build` | U1, U2 | The unsigned Debug app builds successfully. |
| Manual menu smoke check when practical | U2 | Hovering opens the submenu; choosing a model updates the parent label and checked item. |
| Changeset inspection | U3 | One unprocessed patch fragment names the quick model-switching impact. |
| Shipping tail | All units | The pipeline commits and pushes the final diff, opens or updates the pull request, and follows CI as applicable. |

The repository explicitly makes test execution opt-in, so this run will not invoke `xcodebuild test` or `swift test` without a separate user request.

## Definition of Done

- The menu displays `Model: [current model]` for the selected refinement provider.
- Hovering the item opens a native submenu without clicking the parent.
- Dynamic providers list their currently available text models and fixed providers list their default.
- Selecting another model replaces the previous provider-specific selection, updates the label, and affects later refinement.
- Empty/error states preserve saved settings and leave the outer menu functional.
- Focused app-target regression coverage is present, the unsigned Debug build passes, and the patch changeset exists.
- The pipeline's commit, push, pull-request, and CI follow-through stages complete as applicable.
- No provider picker, transcription-model behavior, screen-aware fallback selection, authentication flow, or unrelated menu behavior changes.
- Abandoned implementation experiments and unrelated edits are absent from the final diff.

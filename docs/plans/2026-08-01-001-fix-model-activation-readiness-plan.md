---
title: Model Activation Readiness - Plan
type: fix
date: 2026-08-01
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
---

# Model Activation Readiness - Plan

## Goal Capsule

Keep transcription unavailable from the beginning of a model download until that model has completed its in-memory activation.

Present the final activation period distinctly in Settings so a downloaded model is not presented as ready too early.

## Product Contract

### Summary

Model download is a two-stage user journey: transfer model assets, then finalize and activate the model.

### Requirements

- R1. Beginning any model download marks transcription unavailable, including when another model is already installed.
- R2. A recording start while the selected model is downloading or finalizing follows the existing unavailable-model path and never creates a memo that can wait on activation.
- R3. Settings continues to show progress during activation and labels the distinct finalization step when model assets are local but the runtime is still loading.
- R4. A successful completion restores readiness only after the download-and-load client operation has returned; failures and cancellation leave readiness unavailable.

### Scope Boundaries

- Included: model readiness state, download-progress presentation, and reducer tests.
- Excluded: changing model providers, download cancellation semantics, or recording/transcription retry behavior.

## Planning Contract

### Key Technical Decisions

- Use the existing shared `ModelBootstrapState.isModelReady` as the recording gate, extended with an explicit preparation phase that prevents disk scans from reopening it early.
- Expose phase-tagged preparation updates from `TranscriptionClient` because its existing operation spans both provider download and in-memory activation.
- Prepare an already-downloaded selected model at startup so the first hotkey cannot initiate an invisible load.

### Assumptions

- The existing client completion is emitted only once activation has either succeeded or failed.
- Blocking a new recording during an optional model switch is the intended safety trade-off for preventing hung memos.

## Implementation Units

### U1. Keep the shared recording gate closed through activation

**Goal:** Represent every in-progress model download as unavailable until its client operation completes.

**Requirements:** R1, R2, R4.

**Dependencies:** None.

**Files:** `Hex/Clients/TranscriptionClient.swift`, `Hex/Clients/ParakeetClient.swift`, `Hex/Features/App/AppFeature.swift`, `Hex/Features/Settings/ModelDownload/ModelDownloadFeature.swift`, `Hex/Models/ModelBootstrapState.swift`.

**Approach:** Set the shared readiness state to unavailable when any download or startup preparation begins, preserve that state while model lists refresh or progress arrives, and set it ready only on the matching successful completion. Add phase-tagged callbacks at the actual provider download-to-runtime activation boundary.

**Patterns to follow:** Existing stale-download ID checks and the `TranscriptionFeature.handleStartRecording` shared readiness guard.

**Test scenarios:**

- Starting a download while another model is installed sets the shared readiness gate false.
- Stale progress and completion actions cannot alter the active download’s readiness.
- A matching successful completion marks the downloaded target available and restores readiness.
- A failure or cancellation leaves readiness false and exposes the existing error state.

**Verification:** A new recording cannot proceed while a model’s effect remains active, and the selected model becomes available only after the matching completion action.

### U2. Explain model activation in the download UI

**Goal:** Tell the user that the last part of the progress bar is model finalization rather than a stalled download.

**Requirements:** R3.

**Dependencies:** U1.

**Files:** `Hex/Features/Settings/ModelDownload/ModelDownloadFeature.swift`, `Hex/Features/Settings/ModelDownload/ModelDownloadView.swift`.

**Approach:** Use the client's explicit preparation phase in both the selected-model summary and library row so the wording changes from downloading to finalizing/activating at the real activation boundary.

**Test expectation:** none -- SwiftUI wording is derived from reducer state and reducer behavior is covered in U3.

**Verification:** Settings visibly retains the active progress UI and describes the activation step until readiness returns.

### U3. Characterize the lifecycle in reducer tests

**Goal:** Prevent a future change from treating on-disk availability as activated readiness.

**Requirements:** R1, R4.

**Dependencies:** U1, U2.

**Files:** `HexTests/ModelDownloadFeatureTests.swift`, `HexTests/RecordingRaceTests.swift`.

**Approach:** Extend the existing TCA test store coverage around manually delivered download actions and shared-state assertions.

**Execution note:** Add characterization coverage before relying on the lifecycle change.

**Test scenarios:**

- An installed fallback model does not leave readiness true after a different model’s download starts.
- Progress in the final activation range reports the finalization state while readiness remains false.
- Completion restores readiness only for the active request.

**Verification:** Reducer assertions distinguish on-disk download progress from final activated readiness.

## Verification Contract

- Inspect the reducer tests for the download lifecycle and run them only when explicitly requested, per repository policy.
- Confirm the UI derives its finalization label from the same active request that owns readiness.

## Definition of Done

- No new voice memo can start between model download initiation and successful activation completion.
- The UI labels the post-download activation period clearly.
- Failures, cancellation, and stale completion events do not accidentally mark a model ready.
- A changeset describes the user-visible fix.

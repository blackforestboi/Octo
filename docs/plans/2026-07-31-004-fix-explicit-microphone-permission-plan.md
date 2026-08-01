---
title: "fix: Make microphone permission explicitly user initiated"
date: 2026-07-31
type: fix
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Fix: Make Microphone Permission Explicitly User Initiated

## Goal Capsule

- **Objective:** Ensure only the Settings permission row's Grant action can request macOS microphone access, then update the row immediately when the request completes.
- **Authority:** The user's explicit interaction requirement overrides recorder warm-up and low-latency capture behavior until permission is granted.
- **Stop condition:** No capture path can trigger the system prompt before Grant, and granted/denied Grant outcomes are reflected without a second click.
- **Execution profile:** Preserve the existing TCA permission flow and the user's unrelated working-tree changes.

## Product Contract

### Summary

Octo will ask for microphone access only after the user clicks Grant in Settings. Recording and warm-up attempts made before authorization will not touch microphone capture hardware.

### Problem Frame

The recording engine can currently trigger macOS's microphone dialog while warming or starting capture. That bypasses the visible permission action, leaves the settings row disconnected from the interaction, and makes the onboarding sequence unclear.

### Requirements

- R1. Only the Settings Microphone Grant action may call the macOS microphone permission request API.
- R2. Recorder warm-up, idle rearming, and recording starts must skip microphone capture while authorization is not granted.
- R3. A successful Grant response must mark microphone permission granted without requiring another click.
- R4. Grant must invoke the native microphone permission request for every non-granted state and must not open System Settings directly.
- R5. A recording attempt without permission must fail cleanly and explain that access is granted from Settings.
- R6. Existing Input Monitoring permission edits and other unrelated working-tree changes must remain untouched.

### Acceptance Examples

- AE1. Given microphone status is not determined, when Octo starts or warms the recorder, then no system permission dialog appears.
- AE2. Given microphone status is not determined, when the user clicks Grant and allows access, then the settings state becomes granted and the row disappears or shows completion without a second click.
- AE3. Given microphone status is denied, when the user clicks Grant, then Octo retries the native permission request and does not open System Settings directly.
- AE4. Given microphone status is not granted, when the user triggers recording, then capture does not start and Octo explains that Grant in Settings is required.

## Planning Contract

### Key Technical Decisions

- KTD1. Keep `PermissionClient.requestMicrophone` as the sole owner of `AVCaptureDevice.requestAccess(for: .audio)` and remove the unused duplicate request capability from `RecordingClient`.
- KTD2. Enforce authorization inside `RecordingClientLive` before warm-up, idle engine rearming, and recording setup so future callers cannot bypass the interaction contract.
- KTD3. Model missing authorization separately from unavailable hardware in `RecordingStartResult` so the transcription reducer can present accurate guidance.
- KTD4. Use the Boolean completion returned by the explicit request to update AppFeature state immediately, then retain the normal non-prompting status refresh as confirmation.
- KTD5. After a successful grant, warm the recorder through the existing dependency so super-fast mode recovers its intended latency only after authorization exists.

### Assumptions

- `AVCaptureDevice.authorizationStatus(for: .audio)` is a non-prompting status read.
- The existing app-activation observer remains responsible for detecting changes made manually in System Settings.
- No GitHub issue or PR number was supplied for the changeset summary.

## Implementation Units

### U1. Gate microphone capture behind authorization

- **Goal:** Prevent all recorder-owned capture activation before microphone permission is granted.
- **Requirements:** R1, R2, R5, R6; AE1, AE4.
- **Dependencies:** None.
- **Files:** `Hex/Clients/RecordingClient.swift`, `Hex/Features/Transcription/TranscriptionFeature.swift`, `HexTests/RecordingRaceTests.swift`.
- **Approach:** Remove the duplicate recording-client request API, add a shared authorization predicate in the live recorder, guard recording start before side effects, guard warm-up and idle super-fast rearming, and return a permission-specific start result that maps to clear Settings guidance.
- **Patterns to follow:** Existing `RecordingStartResult` handling and `RecordingRaceTests` TestStore dependency injection.
- **Test scenarios:** Covers AE4. A permission-required start result discards the optimistic recording state, plays the existing cancellation feedback, and shows Settings/Grant guidance. Existing unavailable-hardware behavior remains unchanged.
- **Verification:** Source inspection finds exactly one microphone `requestAccess` call, owned by `PermissionClient`; every capture-engine activation path is preceded by an authorized-status gate.

### U2. Make Grant completion authoritative

- **Goal:** Keep the permission row synchronized with the explicit interaction and handle previously denied access usefully.
- **Requirements:** R1, R3, R4, R6; AE2, AE3.
- **Dependencies:** U1.
- **Files:** `Hex/Features/App/AppFeature.swift`, `HexTests/AppFeatureTests.swift`.
- **Approach:** Ignore Grant only when permission is already granted; otherwise invoke the native permission request, update microphone state from its completion, confirm via the existing permission check, and warm capture only after a grant.
- **Patterns to follow:** Existing parent handling of delegated Settings actions and permission refresh effects in `AppFeature`.
- **Test scenarios:** Covers AE2. Allowing the explicit request immediately changes state to granted and invokes post-grant warm-up. Covers AE3. A denied state retries native request access and never opens System Settings directly. A status-only permission check never calls request access.
- **Verification:** AppFeature tests observe the correct injected dependency calls and final permission state without relying on live TCC state.

### U3. Record the user-facing fix

- **Goal:** Add the required release-note fragment.
- **Requirements:** R1-R5.
- **Dependencies:** U1, U2.
- **Files:** `.changeset/*.md`.
- **Approach:** Create a patch changeset describing that Octo requests microphone permission only from Grant and updates the row automatically.
- **Patterns to follow:** Repository `changeset:add-ai` workflow and existing concise user-facing summaries.
- **Test expectation:** None -- release metadata only.
- **Verification:** A new patch fragment exists and does not process or rewrite the changelog.

## Verification Contract

- Inspect the diff to confirm unrelated user changes, especially in `HexCore/Sources/HexCore/PermissionClient/`, are preserved.
- Search for `AVCaptureDevice.requestAccess(for: .audio)` and confirm the only remaining call is in the live PermissionClient.
- Add focused AppFeature and TranscriptionFeature tests for the explicit-request and permission-required paths.
- Do not run Xcode builds or tests without explicit user authorization, per repository instructions; report that limitation clearly.

## Definition of Done

- U1 prevents implicit microphone prompts from warm-up, environment changes, and recording attempts.
- U2 makes Grant the only permission-request action and reflects its result automatically.
- U3 adds one unprocessed patch changeset.
- Existing unrelated working-tree content is unchanged.
- No abandoned or superseded implementation remains in the diff.

---
title: Session Unpasted Preview Suppression - Plan
type: fix
date: 2026-08-04
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Session Unpasted Preview Suppression - Plan

## Goal Capsule

- **Objective:** Do not show the completed-transcript fallback preview while a recording session is active.
- **Authority:** The user's requested session behavior overrides the older general fallback behavior only for active sessions; existing repository rules and current non-session behavior remain authoritative elsewhere.
- **Stop conditions:** Stop if suppressing the preview would require changing paste behavior for editable destinations or removing the durable session transcript.
- **Execution profile:** Make the narrow reducer change, add focused regression coverage, and add a patch changeset.
- **Tail ownership:** The caller owns validation and shipping after implementation returns.

## Product Contract

### Summary

Suppress the unpasted-result preview during an active recording session because session takes already remain available in the durable session transcript and History.

### Problem Frame

The no-focus fallback predates recording sessions and currently creates `completedTranscriptPresentation` for session takes. That presentation takes priority over the recording indicator and produces a redundant result card while the user is still working in the session.

### Requirements

- R1. A completed-transcript preview must not remain visible or be created while `hasActiveRecordingSession` is true.
- R2. Available editable destinations must retain the existing paste behavior during a session.
- R3. Absent and indeterminate destinations must retain the existing preview behavior when no session is active, including after a retained session reaches an ended state.
- R4. The change must preserve existing session transcript persistence, History behavior, and all unrelated dirty worktree changes.
- R5. The user-facing fix must include a patch changeset.

### Acceptance Examples

- AE1. Given a paused or recording session and an absent editable destination, when a completed result reaches the fallback action, no preview state is created and no paste occurs.
- AE2. Given an active session and an available editable destination, when a result completes, the existing paste path still runs.
- AE3. Given no active session, including a retained ended session, when a result cannot be pasted, the existing preview still appears.
- AE4. Given an expanded preview, when a recording session begins, the preview clears as soon as the session enters its preparing phase.

### Scope Boundaries

- In scope: presentation-state gating in the transcription reducer, focused reducer tests, and a changeset.
- Out of scope: changing editable-target detection, changing session persistence, hiding presentation only at the SwiftUI layer, or changing result behavior outside active sessions.

## Planning Contract

### Key Technical Decisions

- KTD1. Guard `.showCompletedTranscript` with `hasActiveRecordingSession` so the latest state is evaluated after the asynchronous focus probe completes, and clear any existing presentation when `.startRecordingSession` activates a new session.
- KTD2. Do not guard `.pasteCompletedTranscript`; doing so would suppress valid pastes and broaden the requested UX change.
- KTD3. Use the derived active-session predicate rather than testing `recordingSession != nil`, because ended session state is retained and should not suppress later ordinary previews.

### Assumptions

- “Currently in a session” includes preparing, recording, draining, and paused phases, and excludes ended or ended-with-error phases.
- Session results remain recoverable from the durable session transcript and History when the transient preview is suppressed.

### Sources and Research

- `Hex/Features/Transcription/TranscriptionFeature.swift` owns the active-session predicate and completed-transcript presentation reducer actions.
- `HexTests/TranscriptionFallbackPresentationTests.swift` contains the existing absent and indeterminate destination coverage.
- `docs/plans/2026-07-29-001-feat-no-focus-transcript-fallback-plan.md` defines the original fallback purpose.
- `docs/plans/2026-08-03-feat-recording-sessions-plan.md` defines durable recording-session transcript behavior.

## Implementation Units

### U1. Suppress fallback presentation during active sessions

- **Goal:** Prevent active session takes from creating the transient unpasted-result preview without changing valid paste behavior or post-session fallback behavior.
- **Requirements:** R1-R4, AE1-AE4.
- **Dependencies:** None.
- **Files:** `Hex/Features/Transcription/TranscriptionFeature.swift`, `HexTests/TranscriptionFallbackPresentationTests.swift`.
- **Approach:** Return without mutating presentation state when `.showCompletedTranscript` arrives during an active session, and clear any existing presentation when a new session enters its preparing phase. Add focused TestStore coverage in the existing fallback presentation suite.
- **Patterns to follow:** Existing `hasActiveRecordingSession` guards in `TranscriptionFeature` and the current pasteboard probes in `TranscriptionFallbackPresentationTests`.
- **Test scenarios:** Active paused session plus absent destination creates no presentation and performs no paste; active session plus available destination still pastes; retained ended session plus absent destination still creates the preview; starting a session clears an existing preview immediately.
- **Verification:** Reducer assertions distinguish active sessions from ended or absent sessions while existing no-session tests remain unchanged.

### U2. Record the user-facing fix

- **Goal:** Include the session-specific preview suppression in release notes.
- **Requirements:** R5.
- **Dependencies:** U1.
- **Files:** `.changeset/<generated>.md`.
- **Approach:** Use the repository's non-interactive changeset script to create one patch fragment describing the user-facing behavior.
- **Test expectation:** none -- changeset metadata has no executable behavior.
- **Verification:** The new fragment describes suppressing unpasted-result previews during active recording sessions and does not modify existing untracked fragments.

## Verification Contract

- Inspect the existing fallback presentation tests and add the focused active-session regression scenarios in `HexTests/TranscriptionFallbackPresentationTests.swift`.
- Run `git diff --check` after implementation.
- Do not run the Debug build or test suite unless the user explicitly requests it; repository instructions make both opt-in. Report that exception with the unrun focused test target.
- Review the final diff to confirm only the intended reducer branch, regression tests, plan, and newly generated changeset were changed by this task.

## Definition of Done

- Active recording sessions neither retain nor create `completedTranscriptPresentation` for unpasted results.
- Valid in-session pastes and all non-active-session fallback behavior remain unchanged.
- Focused regression coverage documents active and ended session boundaries.
- One patch changeset records the fix.
- Unrelated dirty worktree changes remain untouched and no abandoned implementation remains in the diff.

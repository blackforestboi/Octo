---
title: "feat: Show active recording capabilities in the pill"
date: 2026-07-29
type: feat
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# feat: Show active recording capabilities in the pill

## Goal Capsule

- **Objective:** Surface the active speaker-identification and system-audio recording options beside the waveform without reducing its visible width.
- **Authority:** Implement only the recording-pill presentation change and its release-note fragment; preserve the existing in-flight recording snapshots and waveform behavior.
- **Stop conditions:** The recording and screen-aware pills accurately show zero, one, or two capability symbols, retain the configured waveform width, and the unsigned Debug build succeeds.
- **Execution profile:** UI-only SwiftUI change; use the existing preview matrix and Debug build rather than adding or running opt-in tests.

---

## Product Contract

### Summary

The recording pill should make optional capture capabilities visible at a glance while keeping the waveform equally useful in every enabled combination.

### Problem Frame

Speaker identification and system-audio capture can be active for an in-flight recording, but the live pill currently provides no indication of either capability.

### Requirements

- R1. When speaker identification was enabled for the active recording, display a people symbol to the left of the waveform.
- R2. When system audio was enabled for the active recording, display a loudspeaker symbol to the left of the waveform.
- R3. When both capabilities are active, display both symbols in a consistent left-to-right order, before the existing screen-aware symbol when that state is active.
- R4. Reserve additional pill width for the visible symbols and their spacing so `PillWaveform` keeps its configured width.
- R5. Continue to show no capability-symbol area when neither capability is active.
- R6. Preserve screen-aware feedback, waveform sample history, animations, accessibility, and measured-pill-frame reporting; announce active recording capabilities once through the pill’s accessibility label while treating the individual symbols as decorative.

### Scope Boundaries

- **In scope:** Recording and screen-aware waveform states, using the already-snapshotted active recording settings.
- **Out of scope:** Changing settings controls, capture behavior, transcription/loading states, or the system-audio permission flow.

---

## Planning Contract

### Key Technical Decisions

- KTD1. Pass `activeSpeakerIdentificationEnabled` and `activeSystemAudioEnabled` from `TranscriptionIndicatorOverlayView` to the pill rather than reading mutable preferences in the view. This keeps the indicator truthful to the recording that actually started when the menu-bar settings change mid-recording.
- KTD2. Model the visual state as an ordered list of fixed-width symbols. Add its width and gaps only to the recording and screen-aware waveform-state metrics, while `PillWaveform` continues to receive the existing waveform metric.
- KTD3. Render capability symbols for both recording and screen-aware waveform states. In screen-aware mode, place the capability group before the existing screen-aware symbol, then the waveform, so the pre-existing feedback remains visually adjacent to the waveform.
- KTD4. Keep individual capability symbols decorative and append their active names to the pill’s accessibility label. This communicates the new status once instead of producing fragmented VoiceOver announcements.

### High-Level Technical Design

| Active speaker ID | Active system audio | Left of waveform | Waveform width |
| --- | --- | --- | --- |
| No | No | Nothing | Existing configured width |
| Yes | No | People | Existing configured width |
| No | Yes | Loudspeaker | Existing configured width |
| Yes | Yes | People, loudspeaker | Existing configured width |

### Assumptions

- “Enabled” means enabled for the active recording, as captured when recording starts; the existing reducer already snapshots both values.
- The symbols need not represent a successful system-audio permission result; they communicate the selected active-recording configuration.

### Sequencing

Implement the recording capability layout and its overlay inputs together, then update the preview coverage and add the release note.

---

## Implementation Units

### U1. Add recording-capability indicators without shrinking the waveform

- **Goal:** Render optional speaker-identification and system-audio symbols at the waveform’s leading edge while expanding the pill only by the symbols’ fixed layout width.
- **Requirements:** R1, R2, R3, R4, R5, R6.
- **Dependencies:** None.
- **Files:** `Hex/Features/Transcription/TranscriptionIndicatorView.swift`, `.changeset/<generated>.md`.
- **Approach:** Feed the two active-recording snapshots from the overlay into `TranscriptionIndicatorView`. Derive an ordered symbol group from those inputs, calculate its fixed icon-and-gap width, and add that to both recording and screen-aware pill sizing. Render the group before the existing screen-aware icon when present, keep the waveform frame width untouched, expose the combined capability state in the pill label, and add previews for the relevant combinations.
- **Patterns to follow:** The screen-aware recording symbol, `PillWaveform` sample retention, and `onCardSizeChange` frame reporting in `TranscriptionIndicatorView`; the active-recording snapshots established by `TranscriptionFeature`.
- **Test scenarios:** Verify in Xcode previews that neither enabled shows the current waveform-only layout; either enabled shows its single leading symbol; both enabled show both symbols in the defined order; screen-aware recording places the capability group before its existing feedback symbol; all variants retain the same waveform span for a given indicator size; VoiceOver reports enabled capabilities once through the pill label.
- **Test expectation:** No unit-test file — this is a local SwiftUI layout change with no existing view-test seam, and repository policy makes test execution opt-in.
- **Verification:** The Debug target compiles; visual preview inspection confirms the four combinations and stable waveform width; the generated changeset describes the new feedback.

---

## Verification Contract

| Gate | Applies to | Done signal |
| --- | --- | --- |
| Preview matrix | U1 | Recording and screen-aware examples cover none, speaker ID, system audio, and both capabilities without compressing the waveform. |
| Debug build | U1 | The unsigned `Octo` Debug build succeeds. |
| Release note | U1 | A new patch changeset explains that the recording pill shows active speaker identification and system audio. |

---

## Definition of Done

- The recording and screen-aware pills use people and loudspeaker symbols only for the corresponding active snapshots, with the capability group preceding the screen-aware symbol.
- The visual order is stable when both options are active.
- The waveform retains its former configured width in every combination, with pill width increasing only as needed for the symbols.
- Existing screen-aware feedback, combined accessibility labels, animations, and measured frame updates remain intact.
- A patch changeset and successful unsigned Debug build are present.

---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
created: 2026-07-23
---

# Transcription pill waveform and placement

## Goal Capsule

Make the floating transcription pill configurable and legible: users can choose its size and screen placement, see a white right-to-left audio waveform while speaking (including screen-aware dictation), get a compact processing state, and open History by clicking the visible pill.

## Scope Boundaries

- Keep the pill red; do not alter recording, transcription, or screen-capture behavior.
- Replace the internal glow/pulse rather than adding a second, competing audio visualization.
- Do not persist waveform samples or add a transcript preview.

## Requirements

- R1: Persist a pill size and one of six screen-edge placements, preserving the current top-center default.
- R2: Render a less-rounded red pill with a white waveform whose new samples enter at the right, pushing history left. Widening the pill reveals retained samples instead of restarting its waveform.
- R3: Feed the audio meter to the waveform for normal and screen-aware recording. Screen-aware mode shows a compact screen icon and exposes its label on hover.
- R4: Show an unobtrusive animated processing indication while transcription/refinement is underway.
- R5: Clicking the visible pill opens the app’s History tab without making the surrounding transparent overlay intercept clicks.

## Key Technical Decisions

- Store enum-backed preferences in `HexSettings` and use its explicit schema so older settings decode to the current top-center/regular defaults.
- Keep waveform history in `TranscriptionIndicatorView` state. The view appends normalized meter samples while recording and draws only the trailing samples that fit its current width; resizing therefore changes the visible window, not its history.
- Keep the overlay click-through by restricting `InvisibleWindow` hit testing to the pill’s measured SwiftUI frame. The pill sends the frame to the window and posts the existing app-window notification path when tapped.

## Implementation Units

### U1. Persist presentation preferences

**Files:** `HexCore/Sources/HexCore/Settings/HexSettings.swift`, `HexCore/Tests/HexCoreTests/HexSettingsMigrationTests.swift`

Add size and placement enums and fields to the settings initializer/schema. Prove defaults and a non-default encode/decode round trip.

### U2. Add settings controls and overlay positioning

**Files:** `Hex/Features/Settings/SettingsView.swift`, `Hex/Features/Settings/IndicatorSectionView.swift`, `Hex/Features/Transcription/TranscriptionFeature.swift`

Expose concise menu controls for size and placement and use the settings to align the indicator in the overlay.

### U3. Replace the pill visual and add safe History interaction

**Files:** `Hex/Features/Transcription/TranscriptionIndicatorView.swift`, `Hex/Views/InvisibleWindow.swift`, `Hex/App/HexAppDelegate.swift`, `Hex/App/Notifications.swift`

Draw persistent waveform history, icon-only screen-aware feedback, a process indicator, and constrained click handling that opens History.

## Verification Contract

- Compile the Debug app with the project’s unsigned local build command.
- Inspect settings migration coverage for defaults and persisted enum values.
- Manually smoke-check the visible states in the SwiftUI previews and confirm no full-screen click interception is introduced.

## Definition of Done

The controls persist, waveform state survives width/status changes during a recording, screen-aware recording receives meter feedback, process states are visually distinct, and the pill opens History while the rest of the transparent overlay remains click-through.

---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
created: 2026-07-28
---

# Add an in-app Featurebase support portal

## Goal Capsule

Give Octo users a clear Support destination in the settings window that loads the public Featurebase portal without taking them out of the app.

## Product Contract

- R1: The settings sidebar includes a **Support** item after **About**, using a recognisable support/help symbol.
- R2: Selecting Support presents Octo's public Featurebase portal at `https://octovoice.featurebase.app` in the detail pane.
- R3: The portal remains usable for submitting feedback, voting, and reading updates; web navigation stays inside the embedded view.
- R4: The embedded web view fills the detail pane and shows native loading feedback while its initial request is in progress.

## Scope

In scope: a new navigation tab, a small reusable SwiftUI `WKWebView` wrapper, and a changeset.

Out of scope: Featurebase SSO, anonymous identity handoff, changing Featurebase portal configuration, and web-content moderation.

## Key Technical Decisions

- Use `WKWebView` through `NSViewRepresentable`. It is the macOS-native embedded browser and keeps the public Featurebase portal within the app.
- Load the known live portal URL directly rather than attempting Featurebase's JavaScript SDK; this desktop app has no web runtime or authenticated application user to pass to the SDK.
- Keep navigation state in `AppFeature.ActiveTab`, matching the existing Settings, Transforms, History, and About destinations.

## Implementation Units

### U1 — Support web view

Files: `Hex/Features/Settings/SupportView.swift`

Create a SwiftUI support page with a `WKWebView` bridge, loading the Featurebase portal once and exposing loading/error state appropriate to the app's detail pane.

Scenarios: the initial portal URL loads; user navigation remains in the embedded web view; a failed initial request leaves a clear retry path.

### U2 — App navigation

Files: `Hex/Features/App/AppFeature.swift`

Add `.support` to `ActiveTab`, a Support sidebar button labelled exactly "Support", and the `SupportView` detail branch with the navigation title "Support".

Scenarios: selecting Support updates the active tab; the detail pane resolves to `SupportView`; all existing destinations remain exhaustive.

### U3 — Release note

Files: `.changeset/*.md`

Create a patch changeset noting that users can now open the Featurebase support portal from Octo.

## Verification Contract

- Build the Debug app with the repository-prescribed unsigned `xcodebuild` command.
- Confirm the Swift switch remains exhaustive and the app target compiles the new view.
- Manually inspect the Support tab in the running Debug app to confirm the Featurebase portal loads and is interactive.

## Definition of Done

The settings sidebar displays Support; selecting it embeds `https://octovoice.featurebase.app` in the detail pane; failures are recoverable; and a patch changeset documents the user-facing addition.

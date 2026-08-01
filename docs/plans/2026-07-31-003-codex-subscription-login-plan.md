---
title: Codex subscription sign-in on provider selection
date: 2026-07-31
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Codex subscription sign-in on provider selection

## Goal Capsule

- Let users select OpenAI Subscription refinement without first installing and signing into a standalone Codex CLI.
- Reuse an already authenticated Codex runtime without prompting.
- Start Codex-managed ChatGPT sign-in only when authentication is missing, and persist the provider selection only after sign-in succeeds.
- Keep Claude subscription behavior and first-install provider detection unchanged.

---

## Product Contract

### Problem Frame

Octo resolves a standalone Codex CLI before the Codex executable bundled with ChatGPT.app. Existing CLI users therefore work when their shared Codex credential cache is authenticated, while ChatGPT-only users can manually select OpenAI Subscription but cannot complete refinement because no reusable Codex login exists.

### Requirements

- R1. Selecting OpenAI Subscription must first reuse a valid existing Codex authentication when available.
- R2. When Codex is available but unauthenticated, selecting OpenAI Subscription must start Codex's ChatGPT browser login and wait for completion.
- R3. Octo must persist OpenAI Subscription as the refinement provider only after authentication succeeds.
- R4. A cancelled or failed login must keep the previous refinement provider and show an actionable error without exposing credentials or transcript content.
- R5. Existing authenticated standalone CLI users must not see a login prompt.
- R6. First-install automatic provider detection and Agent Handoff must remain non-interactive and behaviorally unchanged.

### Scope Boundaries

- No direct access to ChatGPT.app's private credential storage.
- No API-key collection or direct OpenAI API integration.
- No changes to Claude subscription selection in this unit.
- No Codex runtime redistribution or installer work; login uses the resolved Codex executable already supported by Octo.

---

## Planning Contract

- KTD1. Keep Codex as the owner of OAuth, token storage, and refresh by invoking its supported login command rather than handling tokens in Octo.
- KTD2. Intercept the refinement-provider picker selection before mutating shared settings so failed login cannot leave an unusable provider selected.
- KTD3. Preserve the current executable precedence: authenticated standalone Codex first, then the ChatGPT.app-bundled runtime where available.
- KTD4. Treat the existing Codex authentication check as the source of truth; login is attempted only after that check fails.

### Assumptions

- The resolved Codex runtime supports `codex login` and opens the ChatGPT browser authorization flow.
- Successful login writes to the same Codex credential storage used by subsequent `codex login status` and `codex exec` calls.

---

## Implementation Units

### U1. Codex authentication command

- **Goal:** Add a login operation that reuses valid authentication, otherwise invokes Codex-managed ChatGPT login and verifies the resulting session.
- **Files:** `Hex/Clients/CLIRefinementClient.swift`, `HexTests/CLIRefinementClientTests.swift`
- **Patterns:** Existing executable resolution, process runner, authentication command, and privacy-preserving diagnostics.
- **Test Scenarios:** Already authenticated returns without login; unauthenticated Codex constructs `login`; successful login passes post-login verification; cancelled or failed login returns a bounded actionable error; missing executable remains distinguishable.
- **Covers:** R1, R2, R4, R5.

### U2. Provider-selection gate

- **Goal:** Route OpenAI Subscription picker selection through authentication and commit the shared setting only on success.
- **Files:** `Hex/Features/Settings/RefinementSectionView.swift`
- **Patterns:** View-local asynchronous settings flows and existing settings alerts.
- **Test Scenarios:** Authenticated selection commits immediately after validation; login success commits; login failure keeps the old provider; repeated selection is disabled while connecting; other provider selections remain synchronous.
- **Covers:** R1, R2, R3, R4, R5, R6.

### U3. Release note

- **Goal:** Document that OpenAI Subscription selection can guide unauthenticated users through ChatGPT sign-in.
- **Files:** `.changeset/*.md`
- **Covers:** R2, R3.

---

## Verification Contract

- Inspect the generated Codex login and status command arguments without launching an OAuth flow.
- Parse all modified Swift files with the compiler frontend when available.
- Do not run the Xcode build or test suite without explicit user permission, per repository policy.
- Review the diff to verify first-install detection and Agent Handoff paths are unchanged.

---

## Definition of Done

- OpenAI Subscription selection never persists an unauthenticated provider.
- Existing authenticated Codex users receive no login prompt.
- Users with an available but unauthenticated Codex runtime receive Codex's ChatGPT authorization flow.
- Login cancellation or failure preserves the prior provider and surfaces a safe error.
- Required focused tests and a changeset are present, with executable verification deferred only where repository policy forbids running it.

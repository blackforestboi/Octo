---
title: Native Agent Handoffs - Plan
type: feat
date: 2026-07-29
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
---

# Native Agent Handoffs - Plan

## Goal Capsule

- **Objective:** Let a user use Shift with the configured recording hotkey to end an ordinary recording as a handoff. For Codex, Octo performs an ephemeral planning-only run, durably buffers the resulting bounded packages, then creates and starts one visible native task per package.
- **Authority:** The user's existing Codex/Claude configuration, tools, skills, plugins, MCP servers, and approval rules remain authoritative for each child task. Octo owns only the planner manifest, durability journal, native task registration, and exact-thread runner binding.
- **Stop conditions:** Do not implement a handoff for direct API refinement providers, do not expose planner tool discovery/execution, and do not add Nomen or a custom discovery bridge.
- **Execution profile:** Native macOS/TCA feature work. Run the unsigned Debug build after implementation; XCTest is opt-in unless requested.

## Product Contract

### Summary

Every recording starts with the user's normal recording hotkey. Shift plus that hotkey is an explicit terminating gesture that routes the completed ordinary recording to handoff. After transcription, Codex receives one read-only, ephemeral planning request that returns focused packages and cannot execute or create tasks. Octo journals those packages before task creation, then starts a canonical projectless thread and an exact `turn/start` against that returned thread ID for every package. There is no visible master/coordinator task. Each child discovers and uses the user's normal native capabilities to execute its bounded work.

> Implementation note: this revision supersedes the earlier coordinator-only design in the remaining historical planning sections below. The current implementation deliberately buffers packages and creates the canonical child threads so a post-planning failure cannot discard handoff work.

### Problem Frame

Regular CLI refinement is intentionally stateless and isolated: its processes run in a temporary directory with tools disabled or restricted. That makes it right for fast text transformation but wrong for work that should continue as visible Codex or Claude tasks using the user's configured environment.

### Requirements

- **R1:** Shift plus the configured recording hotkey ends an ordinary recording as a handoff without changing how ordinary recording starts.
- **R2:** Handoff recording transcribes speech but neither refines nor pastes text into the active application.
- **R3:** A handoff is available only when the selected refinement provider is Codex CLI or Claude CLI and the Shift gesture is unambiguous. After transcription but before coordinator launch, Octo performs a read-only provider/workspace preflight. A failed preflight shows an unavailable/setup state and creates no coordinator or child task.
- **R4:** On first use, Octo explains that native tasks need a dedicated workspace and offers `Create and use ~/Agent Handoffs` or `Choose another folder`. It establishes a security-scoped bookmark for the selected folder; later handoffs reuse it as the coordinator and child-task project directory.
- **R5:** Octo starts exactly one persistent coordinator session per handoff. It preserves the selected provider/model but enforces an immutable coordinator profile that exposes only native child-session creation and lifecycle primitives. Full user configuration is loaded only by child tasks.
- **R6:** The coordinator receives the transcript as the user's request. It separates every independently actionable bounded objective and creates one native, visible child task for each; there is no task-count cap.
- **R7:** The coordinator does not execute work packages or choose tools. Each child task receives its bounded objective and independently discovers and uses appropriate configured native tools, skills, plugins, and MCP servers under the user's normal approval rules.
- **R8:** Octo is a narrow lifecycle integration host, not a package dispatcher: it does not receive or parse a work-package manifest and does not create child tasks. It observes provider-native child-session handles only when they correlate to the current coordinator, fresh handoff token, workspace, and launch ordinal. Coordinator lifecycle messages contain stage/count only and are advisory UI status—not a source of handles, packages, or completion truth.
- **R9:** The indicator presents compact progress milestones: handoff received, coordinator processing, launching tasks, observed tasks launched, and handoff complete. It may show `Found N tasks` as advisory coordinator status when available. Complete means the coordinator has terminally reported launch success and every observed child has a validated durable native handle; it never means that child work is finished.
- **R10:** Clicking a completed handoff indicator opens the native child with launch ordinal 1, as recorded by the coordinator—not merely the first event Octo happens to receive.
- **R11:** Failures, unavailable provider capabilities, missing CLI authentication, denied folder access, coordinator approval/input, zero-task results, and provider-reported partial child launch are reported in the existing overlay without affecting normal refinement. When a coordinator or any validated child exists, its card keeps an action to open that native task. A partial handoff has no whole-handoff retry; recovery stays in the original coordinator.
- **R12:** The handoff system has no Nomen dependency and no Octo-provided discovery tool or bridge.
- **R13:** Octo does not log, persist, place in lifecycle events, analytics, errors, or test fixtures the handoff transcript or package content. The coordinator gives each child only the minimum relevant request context and first-use copy explains that the request becomes persistent native provider task content governed by that provider's normal configuration.

### Acceptance Examples

1. With a non-Shift refinement gesture, Octo retains the current isolated refinement flow and pastes only the refined text.
2. With Shift plus a valid recording-ending gesture, Octo routes the completed ordinary recording to a handoff, transcribes it, then shows `Handoff received` rather than refining or pasting the transcription.
3. A transcript that contains three independent objectives leads the coordinator to launch three native child tasks. Octo only sees their native handles and reports that three were launched.
4. A Codex child task is a persistent native thread that opens through `codex resume <thread-id>`; a Claude child task appears as an attachable background session in `claude agents`.
5. If native visible-task creation is unavailable for the selected provider/version, Octo reports the provider capability as unavailable and never substitutes its own dispatch logic.

### Scope Boundaries

- No new settings toggle beyond the Shift-modified ending gesture: using it is the user's explicit handoff choice. The existing hotkey surface may display the Shift-collision validation message.
- No Nomen integration, external discovery service, custom MCP server, transcript-to-manifest protocol, or task completion monitoring.
- No changes to API-provider refinement, normal `CLIRefinementClient`, ordinary refinement prompts, or normal transcript paste behavior.
- No forced use of an existing user repository. `~/Agent Handoffs` is a generic dedicated project root.
- No persistence of handoff data in transcription History. Native provider task lists remain the durable task record.
- No Octo transcript retention beyond the in-flight coordinator request; logs use `HexLog` privacy annotations and test fixtures contain lifecycle metadata only.

## Planning Contract

### Key Technical Decisions

1. **Use a separate `AgentHandoffClient`, not `CLIRefinementClient`.** The latter must remain temporary, tool-restricted, non-persistent, and configuration-isolated. The new client has its own provider adapters, lifecycle event stream, and normal-config process environment.
2. **Certify provider-native child creation, then preflight it read-only.** Before shipping support for a provider/runtime version, a development-only live proof must establish the complete native child lifecycle. Codex must expose a model-visible persistent child-thread mechanism through the managed app-server collaboration path; Claude must expose full Agent View background sessions, not internal Agent/Task subagents. At runtime, Octo performs only read-only version/config/workspace checks before coordinator launch. An uncertified or unmet capability fails closed; opening uses their documented native `resume`/`attach` commands.
3. **Let the coordinator own decomposition and launch.** The coordinator's single instruction is to classify the user's transcript into bounded objectives and open native child tasks. Octo neither asks for a JSON manifest nor maps packages to sessions.
4. **Use provider-native handles plus advisory lifecycle status, never package content.** `AgentHandoffClient` converts app-server collaboration/thread events or Claude Agent View session events into app-local progress. The coordinator reports only `found(count)`, `launchAttempt(ordinal)`, and terminal status; it never returns a work-package manifest, task content, or handle. The app accepts child handles only from correlated provider-native events and retains ordinal 1 for R10.
5. **Restrict the coordinator; preserve normal provider configuration for children.** Start the coordinator with the selected CLI model and an immutable native profile that allows only persistent child-session creation/lifecycle. The transcript is a distinct user input, never interpolated into policy. Its child launches use the authorized workspace and normal user configuration, tools, skills, plugins, MCP servers, and approval rules. Do not reuse the refinement isolation profile for either route, and do not grant a coordinator arbitrary work tools merely because children need them.
6. **Use a security-scoped workspace bookmark.** The app sandbox cannot assume broad home-directory access. The default folder name is `Agent Handoffs`, but the user selects/authorizes it once and the bookmark supplies the future working URL.
7. **Represent Shift as a first-class pre-recording intent.** Extend the single existing hotkey processor/session, rather than adding a competing monitor or reinterpreting Shift after recording begins. Existing modifier-only thresholds, dirty-chord rules, double-tap semantics, and Esc cancellation stay intact.
8. **Validate handles and disconnect rather than terminate user work.** Accept a task handle only from a documented provider-native creation/list event correlated to the coordinator's parent ID, fresh handoff token, authorized workspace, and launch ordinal. Open it through `Process` argument arrays, never shell interpolation. Before any child is created, cancellation can stop the coordinator. Once a native child exists, Octo only cancels its observation and keeps all created children and the coordinator running under provider ownership. It never auto-approves or auto-terminates native tasks.

### High-Level Technical Design

```mermaid
sequenceDiagram
  participant U as User
  participant O as Octo
  participant C as Native coordinator
  participant P as Codex or Claude native runtime
  participant T as Visible child tasks

  U->>O: Normal recording hotkey; speak; Shift + hotkey to end
  O->>O: Transcribe ordinary recording marked for handoff
  O->>P: Start one coordinator in authorized Agent Handoffs workspace
  P->>C: Transcript + coordinator instruction
  C->>C: Split only into independent bounded objectives
  C->>P: Use native child-task/session creation per objective
  P-->>T: Persistent visible child threads/sessions
  P-->>O: Native launch handles and lifecycle events
  O-->>U: Processing, found N, launched N, complete
  U->>O: Click complete
  O->>P: Open first native child task
```

#### Provider paths

- **Codex CLI:** connect to the managed app-server daemon/proxy so the restricted coordinator and normal-profile child threads use the selected model and authorized workspace. Start one thread and turn; map `thread/started`, collaboration `spawnAgent`, parent IDs, and durable child status notifications to lifecycle events. The coordinator uses the model-visible native collaboration child-thread mechanism; it must create persistent threads in the same authorized workspace rather than ephemeral subagents. Open a validated child with `codex resume <thread-id>`.
- **Claude CLI:** start one restricted coordinator session in the authorized workspace with the selected model and observe its native JSON/session lifecycle. The coordinator creates full Agent View background sessions using Claude's native background-session dispatcher (`claude --bg` semantics), passing the same authorized workspace, selected model, and fresh handoff token/ordinal for every child—not the Agent/Task subagent tool because subagents are not separate Agent View rows. If the dispatcher is exposed through Bash, its coordinator profile permits only the fixed native `claude --bg` launcher with argument vectors, never general shell access. Accept a child only after the certified `claude agents --json` correlation confirms its session ID/status. Open a validated handle with the installed CLI's `claude --resume <session-id>` command.
- **Capability gate:** certify the exact installed provider route during development, then make runtime support a read-only version/config/workspace decision before coordinator launch. This gate is an integration seam, not a fallback that lets Octo dispatch tasks.

#### Provider certification prerequisite

The application must not infer these capabilities from help text alone. Before U1 ships a provider adapter, run a disposable end-to-end proof through an Octo build carrying the production sandbox entitlements and capture redacted event fixtures:

- **Codex:** prove that a coordinator turn receives the model-visible collaboration spawn primitive, emits a child `threadId` and `parentThreadId`, leaves the child persistent after coordinator completion, surfaces approvals through the user's normal native Codex experience, uses the authorized workspace/selected model, and opens with `codex resume <thread-id>`.
- **Claude:** prove that a coordinator creates a full `claude --bg` child under the authorized workspace/selected model; that `claude agents --json` exposes a stable handoff correlation marker plus session ID/status for the child; that the child retains normal configured settings/plugins/MCP/default approvals; and that `claude --resume <session-id>` opens it.
- **Sandbox boundary:** prove the provider-native route—not an Octo-created helper/bridge—can access its normal user configuration while the app uses only the selected workspace bookmark. Do not assume a workspace bookmark grants access to provider homes, credentials, plugins, or MCP configuration.

Failure of any item marks that provider unavailable. It does not permit an Octo-owned package dispatcher, a custom discovery bridge, weakened sandboxing, or auto-approval. The bookmark gates Octo's own folder access; it is not a sandbox for a normal-authority native provider, and first-use copy/documentation must disclose that distinction.

#### Coordinator and child instructions

The coordinator instruction must be provider-specific only where the provider names its native child-session primitive. Its behavioral contract is common:

1. Treat the transcript as the user's request and preserve the context needed by each child.
2. Do not inspect, choose, or use the user's work tools; do not carry out any package. The native runtime must enforce this profile; this instruction is not the only boundary.
3. Identify every independent objective that can proceed alone. Keep genuinely dependent work together.
4. Create one full, persistent, visible native task for each objective. Record the native handles through the provider runtime.
5. Seed every child with its objective, relevant request context, and this instruction: complete only that objective; first discover the appropriate configured native tools/skills/plugins/MCP servers; then execute under normal approval rules. Do not split the task again unless the provider's own task semantics require it.
6. Emit lifecycle-only status before and during launch: `found(expectedCount)` and launch ordinals only. Do not expose package descriptions or native handles in this status stream.
7. Finish after reporting native creation outcomes. A partial launch is failure, never a silent smaller handoff. Recover failed launches only from this coordinator's native state; a new handoff may create duplicates and must say so.

#### Handoff card interaction matrix

| Coordinator state | Card copy | Primary action |
| --- | --- | --- |
| Authorizing workspace | `Set up Agent Handoffs` | Return to the folder authorization flow; cancel returns to idle and permits a later retry. |
| Processing / launching | `Launching tasks…` or `Launched N tasks` | No task action until a native handle exists. |
| Needs approval or input | `Handoff needs your input` | Open the coordinator so the user answers through the provider's normal UI. |
| Complete with children | `Launched N tasks` | Open the first launched child task. |
| No actionable task | `No separate task was created` | Open the coordinator to inspect or continue it. |
| Partial launch | `Launched N tasks; more need attention` | Open the first validated child or coordinator. The coordinator, not Octo, may retry only failed native launches. |
| Provider/open failure | Provider-specific error | Open the existing coordinator when present. A fresh recording is a new handoff and may duplicate prior tasks; Octo never creates missing tasks. |

The task action is a named accessibility button. Each state supplies a concise accessibility label and announces a milestone once. Only the measured card is interactive; the surrounding overlay remains click-through.

### Assumptions

- The currently installed native runtimes remain available from Octo's process environment and their accounts are authenticated as the existing CLI validation flow expects.
- Codex collaboration-created child threads are persistent and can be reopened through the installed CLI's documented `codex resume <thread-id>` path.
- Claude Code's Agent View remains enabled and its documented background session handles can be listed and attached from the CLI.
- A configured recording hotkey that already includes Shift has no distinct Shift-modified ending variant. The existing hotkey settings surface states, `Agent handoff is unavailable because this recording hotkey already includes Shift. Choose a hotkey without Shift.` Adding Shift while an ordinary recording is active selects that recording's handoff destination at termination.

### Risks & Dependencies

- Native thread/session APIs are versioned external capabilities. Pin support to runtime capability checks and emit a clear unsupported state instead of inventing an Octo-owned alternative.
- The selected `~/Agent Handoffs` folder requires a user-selected security scope. Losing or revoking the bookmark must return the user to folder authorization, not execute in a temporary directory.
- Child-task creation can prompt under normal approval rules. The progress model must represent `needs user input` and leave the native task accessible rather than timing out or changing permissions.
- Provider output schemas may change. Keep parsing limited to documented lifecycle/session handles and cover representative event fixtures.
- Handoff content becomes native provider session content. Minimize child context and never surface it through Octo diagnostics, telemetry, errors, or fixtures.

### Sequencing

U0 certifies each provider's runtime boundary before code relies on it. U1 and U2 establish the capability/workspace foundations. U4 defines the coordinator/child contract; U3 then implements its provider adapters and native opener against that fixed contract. U5 routes the explicit gesture and lifecycle through the TCA feature. U6 presents native-task actions. U7 supplies regression coverage and user-facing documentation.

### Sources and Research

- `Hex/Clients/CLIRefinementClient.swift:137-193, 406-471` — the intentionally isolated regular-refinement command/environment that must stay untouched.
- `Hex/Features/Transcription/TranscriptionFeature.swift:149-154, 422-496, 780-790, 1012-1019, 1027-1233` — recording source, hotkey, cleanup, and lifecycle seams.
- `HexCore/Sources/HexCore/Logic/HotKeyProcessor.swift:217-260` and `docs/hotkey-semantics.md` — exact-chord and modifier-state rules.
- `Hex/Features/Transcription/TranscriptionIndicatorView.swift:15-121` and `Hex/App/HexAppDelegate.swift:123-137` — status, sizing, hit-testing, and overlay callback seams.
- `Hex/Hex.entitlements:5-14` — user-selected filesystem access requires security-scoped bookmark handling.
- [Claude Code Agent View documentation](https://code.claude.com/docs/en/agent-view) — background sessions are full attachable conversations; Agent/Task subagents do not appear as separate Agent View rows.
- [Claude Code subagents documentation](https://code.claude.com/docs/en/sub-agents) — the Agent tool creates subagents and inherits normal tool/permission context, which is not the desired visible-session primitive here.

## Implementation Units

### U0. Certify the native provider routes before enabling product support

- **Goal:** Establish redacted, reproducible proof that each supported provider can satisfy the no-Octo-dispatch contract from Octo's sandboxed process boundary and produces a child visible/reopenable in that provider's normal client.
- **Requirements:** R3, R5, R6, R7, R8, R10, R11, R12, R13.
- **Files:** Add redacted Codex/Claude lifecycle fixtures under `HexTests/Fixtures/AgentHandoff/`; add a short developer verification note to this plan's Sources and Research section when each route is proven.
- **Approach:** Execute the exact certification matrix in Provider certification prerequisite with a disposable handoff request and no external user work. Capture only lifecycle fields, versions, handles, correlation markers, workspace/model assertions, approval routing, and open/attach results. Review the captured protocol before writing each live adapter. Runtime checks must be read-only and match the proven version/capability path; they must never create a probe child task for an end user.
- **Test scenarios:** Codex and Claude success fixtures; missing collaboration/Agent View capability; sandboxed provider configuration inaccessible; missing Claude correlation field; nonpersistent Codex child; failed approval routing; incorrect child workspace/model; and unavailable provider with no coordinator launch.
- **Verification:** A reviewer can reproduce the certified provider flow from an app build carrying the production sandbox entitlements and confirm Octo starts only the coordinator while the provider creates every child, then shows/reopens that child in its normal client. Do not proceed with the provider's U3 implementation if any certification row fails.

### U1. Define the native handoff domain and dependency boundary

- **Goal:** Add testable core models for a handoff request, progress phase, native task handle, capability result, and structured error; expose them through a separate TCA dependency.
- **Requirements:** R3, R5, R8, R10, R11, R12, R13.
- **Files:** Add `HexCore/Sources/HexCore/Models/AgentHandoff.swift`; add `Hex/Clients/AgentHandoffClient.swift`; update `Hex/App/HexApp.swift` or the existing dependency registration seam; add focused client tests beside `HexTests/CLIRefinementClientTests.swift`.
- **Approach:** Model `AgentHandoffRequest` with provider, selected model, transcript, authorized workspace, and fresh handoff token. Model an `AsyncThrowingStream<AgentHandoffEvent>` whose events are readiness, coordinator-started(handle), processing, advisory `tasksFound(expectedCount)`, launch-attempt(ordinal), validated-child-created(handle, ordinal), observed-launch-count, needs-user-input(target handle), no-actionable-task(coordinator handle), provider-reported-partial-launch, completed, and failed. The client owns only validated opaque native handles, counts, and ordinal; it has no `WorkPackage` or manifest type. Keep transcript and provider output out of logs/errors and mark unavoidable diagnostics private with `HexLog`.
- **Test scenarios:** Dependency test values can emit each event order, cancellation terminates observation without terminating native children, launch ordinal rather than delivery order selects the first child, zero and partial launches retain coordinator/child handles, selected models map into requests, and a provider without read-only `supportsVisibleChildCreation` returns unavailable before coordinator launch. Negative fixtures reject forged, stale, duplicate, foreign-parent, mismatched-token, and mismatched-workspace handles.
- **Verification:** Compile the core model and client tests; confirm no call site changes `CLIRefinementClient` command construction.

### U2. Authorize and retain the dedicated handoff workspace

- **Goal:** Resolve a stable, user-authorized `Agent Handoffs` project URL for all coordinator and child sessions.
- **Requirements:** R4, R5, R11.
- **Files:** Add a workspace/bookmark client under `Hex/Clients/`; add a small persisted settings/bookmark model under `HexCore/Sources/HexCore/Settings/`; update entitlement-aware app setup only if required; add unit tests for bookmark resolution/error states.
- **Approach:** On first handoff, explain the dedicated workspace and offer `Create and use ~/Agent Handoffs` or `Choose another folder`. Both paths use a native directory selection flow that grants access to the exact resulting folder; the default path lets the user create/select `Agent Handoffs` through that picker and never grants the home directory as a substitute. Start security-scoped access only after selection, then save a bookmark. Resolve and refresh stale bookmarks before every launch. Treat cancellation as setup cancelled/idle and never replace missing authorization with `temporaryDirectory` or an arbitrary existing project.
- **Test scenarios:** first-use exact-folder authorization required, default-folder creation through the picker, alternate-folder selection, home-directory rejection, picker cancellation, valid bookmark resolution, stale/revoked bookmark reauthorization, and a failure that stops before coordinator launch.
- **Verification:** Exercise the client with temporary bookmark fixtures and manually confirm a sandboxed debug app can resolve a selected folder after relaunch.

### U3. Implement provider-native coordinator adapters and native opening

- **Goal:** Start exactly one normal-config coordinator and observe only native child-session lifecycle/handles for Codex CLI and Claude CLI.
- **Requirements:** R3, R5, R6, R8, R10, R11, R12, R13.
- **Files:** `Hex/Clients/AgentHandoffClient.swift`; add provider-specific helpers under `Hex/Clients/AgentHandoff/`; add fixture tests in `HexTests/`.
- **Approach:** Implement this unit only after U4 fixes the coordinator contract. Reuse `Process`, pipes, cancellation, executable discovery, and JSON-RPC framing patterns from `CLIRefinementClient`, but use a distinct non-isolated environment and the authorized workspace as `currentDirectoryURL`. Codex uses the managed app-server/proxy and maps native collaboration/thread/parent IDs. Claude uses normal session/background-agent interfaces and maps certified Agent View session correlation. Both adapters perform read-only `supportsVisibleChildCreation` preflight; only the running coordinator calls the native child-creation primitive. Enforce the immutable coordinator profile at launch and pass the transcript separately as user input. `AgentHandoffClient.open(handle:)` centrally invokes documented `codex resume` or installed `claude --resume` commands through argument arrays for either a coordinator or child.
- **Test scenarios:** Codex and Claude command/session builders carry the selected model and authorized workspace, enforce the coordinator-only capability profile, and ensure each child inherits the workspace/normal profile. Native advisory count, launch ordinal, user-input target, validated child-created, partial-failure, completion, cancellation, and unsupported-version fixture streams map to the correct events. Forged, stale, foreign-parent/token/workspace, and duplicate handles do not become open targets.
- **Verification:** With authenticated development CLIs, manually run a disposable coordinator against the handoff workspace and verify one child can be reopened by `codex resume <thread-id>` or `claude --resume <session-id>` for each supported provider.

### U4. Encode the coordinator and child-task contracts

- **Goal:** Give one coordinator the whole spoken request and make it, rather than Octo, create all child tasks.
- **Requirements:** R5, R6, R7, R8, R12.
- **Files:** Add `Hex/AgentHandoff/CoordinatorPrompt.swift` (or keep a focused template within the new client); add prompt-contract tests in `HexTests/`.
- **Approach:** Build an immutable provider-specific coordinator policy plus a distinct transcript user input. The policy forbids coordinator execution and tool discovery, requires all independent tasks to be launched, and gives every child its bounded objective plus the minimum relevant request context and full-native discovery/execution instruction. Require the lifecycle-only count/ordinal envelope, not a package manifest or handle output.
- **Test scenarios:** Prompt snapshots prove the transcript is treated as the user's request but cannot change coordinator policy, child instructions contain native discovery and approval guidance, no Nomen/custom discovery language exists, lifecycle status contains no package content or handle, and no count cap or Octo dispatch instruction appears.
- **Verification:** Review generated prompts against the Product Contract and inspect a live coordinator transcript to confirm it opens children rather than working a package itself.

### U5. Add a Shift-modified handoff ending intent and reducer lifecycle

- **Goal:** Preflight the explicit gesture, then route it through recording, transcription, one coordinator effect, cleanup, and error handling without disturbing existing hotkey semantics.
- **Requirements:** R1, R2, R3, R5, R8, R9, R11.
- **Files:** `HexCore/Sources/HexCore/Logic/HotKeyProcessor.swift`; `HexCore/Sources/HexCore/Models/HotKey.swift`; `Hex/Features/Settings/HotKeySectionView.swift`; `Hex/Features/Transcription/TranscriptionFeature.swift`; `HexCore/Tests/HexCoreTests/HotKeyProcessorTests.swift`; add `HexTests/TranscriptionFeatureTests.swift`.
- **Approach:** Keep `RecordingSource` as an ordinary recording source and add a first-class terminal intent that recognizes Shift only while an ordinary recording is active. The original hotkey always starts recording; the Shift-modified ending gesture marks that active session for handoff, stops it, and bypasses the normal refine/paste branch after transcription. Resolve workspace and run one cancellable `AgentHandoffClient` effect. Show the existing hotkey setting's collision message when the configured recording hotkey already includes Shift. Clear intent, meters, tasks, and temporary state on every terminal path. Before child creation, cancellation stops only the coordinator; after child creation it detaches Octo's observation without stopping provider-native work.
- **Test scenarios:** Shift-modified press-and-hold ending, modifier-only ending, double-tap lock ending, Shift added after start, exact normal refinement, Esc cancellation, hotkey containing Shift and its validation text, preflight failure with no coordinator launch, transcription failure, cancellation before/after first child creation, zero-task result, and partial-launch error.
- **Verification:** The normal/refined hotkey suites remain green; reducer assertions show exactly one coordinator launch only after transcription and passed preflight, correct cancellation ownership, and zero Octo child-dispatch calls.

### U6. Present coordinator progress and open the first native task

- **Goal:** Turn native lifecycle events into a compact progress card that opens the first launched task on completion.
- **Requirements:** R9, R10, R11.
- **Files:** `Hex/Features/Transcription/TranscriptionIndicatorView.swift`; `Hex/Features/Transcription/TranscriptionFeature.swift`; `Hex/App/HexAppDelegate.swift`; focused view/reducer tests.
- **Approach:** Add a handoff-specific indicator status with progress text/count and the interaction matrix above. Keep its card interactive only inside the measured frame. Wire app callbacks to select the coordinator or first-child handle and call `AgentHandoffClient.open(handle:)`. Route unavailable/open errors back to the overlay and expose state/action labels to accessibility.
- **Test scenarios:** each milestone resizes correctly, background overlay remains click-through, completion opens only the first child, approval opens the coordinator, zero-task opens the coordinator, partial launch preserves the first child action, accessibility labels/actions match the card state, and open failure becomes an error status.
- **Verification:** Manual Debug-app check for recording-to-completion, first-task opening, and unaffected History/normal refinement interactions.

### U7. Document, release-note, and regression-proof the gesture

- **Goal:** Make the behavior supportable and ship-ready without broadening the existing refinement contract.
- **Requirements:** R1, R2, R3, R11, R12, R13.
- **Files:** `docs/hotkey-semantics.md`; `.changeset/<generated>.md`; targeted XCTest fixtures from U1–U6.
- **Approach:** Document the pre-recording-only Shift variant, its unavailable collision when a hotkey already contains Shift, folder authorization, that the bookmark authorizes Octo rather than sandboxing normal-authority providers, native-provider requirements, persistent provider task-content/privacy boundary, completion meaning, and no-Nomen boundary. Add a user-facing minor changeset using `bun run changeset:add-ai minor` once implementation is complete.
- **Test scenarios:** Documentation names normal versus handoff semantics and release note describes visible native tasks rather than generic refinement.
- **Verification:** Review the changeset, run the agreed build, and manually test both native providers that pass capability probes.

## Verification Contract

- Run the unsigned Debug build only: `xcodebuild -scheme Octo -configuration Debug -skipMacroValidation -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build`.
- Do not run XCTest unless the user opts in. If opted in, run the focused `HotKeyProcessorTests`, `AgentHandoffClient` fixtures, and `TranscriptionFeatureTests` before the wider suite.
- Manual acceptance requires: an authorized `Agent Handoffs` folder, a normal recording/refinement control run, a Shift-modified ending handoff run for each supported native CLI, visible child task/session creation, normal approval prompts preserved, first-child opening, and a failing capability run that leaves no Octo-created child task.

## Definition of Done

- The Shift-modified ending handoff flow meets R1–R13 while ordinary refinement stays byte-for-byte on its isolated command path.
- Octo launches one coordinator and observes native child handles; it never parses tasks or dispatches them.
- Every supported provider creates visible, persistent child tasks in the authorized workspace and the completion card opens the first one.
- Unsupported native capability, folder access, launch, partial creation, and task-opening failures are explicit and recoverable.
- The hotkey documentation and user-facing changeset are present, focused coverage exists, the Debug build passes, and no abandoned fallback/experimental dispatch path remains in the diff.

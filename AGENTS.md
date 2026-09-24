# Tether app contributor guide

## What this repository is

Tether is a native macOS SwiftUI client for Claude Code. It is intentionally a thin client: it presents hosts, sessions, streamed transcript items, prompts, and settings while `../tether-server` owns Claude Agent SDK queries and long-lived session state.

This repository builds on its own. Clone it, open `Tether.xcodeproj`, and build:

- `TetherKit/Package.swift` depends on the `TetherProtocol` package published by `AFRUITPIE/tether-server`, pinned by version. The generated sources are committed there, so nothing has to be generated to consume them.
- The app target's build phase (`Scripts/fetch-server-binaries.sh`) puts the standalone server binaries in the bundle. It prefers a sibling `../tether-server/dist` when that has binaries for the pinned version, and otherwise downloads that version's GitHub release once and caches it under `DERIVED_FILE_DIR`.
- `.tether-server-version` is the pin. Bump it when the app needs a newer server, after that version has been released.

`tether-server` is public, so SwiftPM can resolve the protocol package without credentials. The app repository remains private.

Working on the protocol or the server at the same time still wants both checkouts side by side. Override the package with the local copy rather than editing the manifest:

```sh
swift package edit TetherProtocol --path ../../tether-server   # undo with: swift package unedit TetherProtocol
```

or add `../tether-server` to the Xcode workspace, which takes precedence over the remote. Run `mise run compile` there and the build phase picks the binaries up from `dist/` automatically.

## Repository map

- `Tether.xcodeproj`: macOS app target, shared `Tether` scheme, signing, and the server-binary copy phase.
- `Tether/TetherApp.swift`: app entry point, commands, settings scene, and the debug-only `TETHER_OPEN_THREAD` launch hook.
- `TetherKit/Sources/TetherKit`: transport and state layer.
  - `Bootstrap.swift`: selects a bundled binary, installs it locally or over SSH, and builds the `tether connect` command.
  - `Transport.swift`: process-backed JSONL byte transport.
  - `RPCClient.swift`: actor that correlates JSON-RPC calls, streams notifications, and answers server-to-client requests.
  - `HostConnection.swift`: one host connection, reconnect/replay behavior, catalogs, thread operations, and server-request routing.
  - `ThreadModel.swift`: `@MainActor @Observable` reducer for one thread.
  - `TranscriptRows.swift`: pure folding of transcript items, including compact tool-call groups.
  - `PreviewSupport.swift`: debug-only sample state used by Xcode previews.
- `TetherKit/Sources/TetherUI`: views and app-level state.
  - `AppModel.swift`: hosts, the window's host and chat (`hostID`, `threadID`), new-chat drafts, and persisted preferences.
  - `RootView.swift`: the shell only — split view, the one toolbar, the one inspector, View-menu commands.
  - `Sidebar/`: one host's chats, and `HostCommands` (the Host menu); `SidebarSections.swift` is the pure, tested grouping (date or directory).
  - `Toolbar/`: `SessionControls` (the model, effort and permissions menus over one `SessionSettings`, live chat or draft, and the Chat menu) and `ReservedWidthLabel`.
  - `Inspector/`: the tabbed shell, its toolbar toggle, and one view per pane (`TasksPane`, `SessionPane`, `MCPPane`).
  - `Thread/`: `ThreadView` (transcript over bottom bar), `TranscriptView`, `BottomBar`, `Composer` (`/` commands, `@` files, images).
  - `NewChat/`: the new-chat screen (folder pop-up above the composer) and the remote folder picker.
  - `Settings/`: General and Hosts panes, host detail, and the environment and log sheets.
  - `PromptViews.swift`: permission, question, plan, and elicitation requests.
  - `ItemViews.swift`, `ToolCallView.swift`, `Markdown.swift`: transcript rendering.
- `TetherKit/Tests/TetherKitTests`: transcript folding and opt-in live-server coverage.

## Runtime flow

1. `AppModel` creates a `HostConnection` for each configured host and initiates connections.
2. `HostBootstrapper` finds the matching `tether-<version>-<platform>` binary, installs it under `~/.tether/bin`, and launches `tether connect` locally or through system `ssh`.
3. `RPCClient` performs the initialize handshake and carries newline-delimited JSON-RPC.
4. `HostConnection` loads the host catalog, maps summaries to stable `ThreadModel` instances, subscribes with `afterSeq`, and batches streaming deltas to roughly one UI update per frame.
5. `ThreadModel` applies snapshots and notifications. SwiftUI renders its cached top-level items, rows, turns, tasks, pending requests, and status.

The daemon, not the app, owns live Claude queries. Closing or disconnecting the app must not end a turn. Reconnection must resume from the last sequence number and reload history only when replay reports a gap.

## State and concurrency invariants

- `RPCClient` is an actor. UI stores are `@MainActor @Observable`; keep network/process work off the main actor and UI mutations on it.
- Do not create or insert observable models from a SwiftUI `body`. Resolve selections when state changes, then render existing models.
- Keep one `ThreadModel` identity per `(host, threadId)`. Replacing it loses subscriptions, pending prompts, and scroll continuity.
- A thread opened before its host connects is deferred through `openRequested`; do not turn that normal race into a permanent “Not connected” error.
- Apply `historySeq`, `lastSeq`, and `afterSeq` consistently. A history snapshot and its live tail must neither overlap nor leave a gap.
- Server requests can be answered by more than one attached client. Preserve the once-only continuation guard and remove prompts on `serverRequest/resolved`.
- Streaming deltas are intentionally coalesced. Do not reintroduce one full transcript invalidation per token.
- Keep expensive derived work out of view bodies. Transcript rows, child lookup, Markdown parsing, and diffs have caches for a reason.
- `ThreadModel.title` and `taskEntries` are stored, not derived from `items`: anything the sidebar, toolbar or inspector chrome reads must not change per streamed delta. Only `TranscriptView` and its rows read `rows`/`items`.
- A view takes the narrowest model it needs, and each inspector pane is its own view, so a delta redraws at most the transcript and the open pane.
- Persisted preferences are plain stored properties on `AppModel` saved through `Stored`. No `@AppStorage` inside an `@Observable`.

## UI and HIG decisions

The product should feel like a standard current macOS app. Prefer native SwiftUI components and behavior over custom chrome. Check the relevant Apple Human Interface Guidelines and API documentation for every interaction or presentation change.

- Target the current project baseline (Xcode 27, Swift 6, macOS 27+). Do not add compatibility shims for older systems unless requested.
- Let system layout and intrinsic sizing work. Avoid hand-computed geometry, arbitrary fixed production sizes, and `.fixedSize()` as a general layout repair. Fixed frames in previews and small icon/status geometry are fine.
- Liquid Glass belongs to controls: toolbar controls, composer, and prompt cards. Transcript content uses ordinary fills. Never stack glass on glass; controls inside a glass card use standard bordered styles.
- The shell is `NavigationSplitView` + one `.toolbar(id:)` on the detail container + one `.inspector` on the split view. No `GeometryReader`, preference keys, `columnVisibility` bindings, or `.id()` on containers other than `ThreadView(...).id(thread.id)`.
- Every toolbar item is unconditional: never an `if`/`switch` around a `ToolbarItem`. Something unavailable is disabled, not removed, so nothing moves when the selection or a column changes. The toolbar is user-customizable (`ToolbarCommands`).
- Toolbar, leading to trailing: sidebar toggle, New Chat (always visible; `Command-N` too), title and subtitle, then model, effort and permissions (one `.primaryAction` item, trailing, so the title keeps the space and the three share one glass capsule), then the inspector toggle.
- The subtitle is the chat's folder name (the New Chat draft's on New Chat), prefixed by the host when more than one is configured. The full path is in the Session pane, or the folder pop-up on New Chat.
- Model, effort and permissions are three pull-down menus with inline pickers: the model by name (Fast Mode is a toggle in its menu), effort as a gauge that follows the level, permissions as the mode's symbol (red for bypass). Not pop-ups: an icon-only pop-up shows its rows as bare symbols. Each label reserves the width of its widest listed value (`ReservedWidthLabel`), so choosing among them never resizes a control. Settings uses the same symbols and labels; the mappings live in `Helpers.swift`.
- Every toolbar control is also in the menu bar, since the toolbar can be hidden or customized: File ▸ New Chat, the Chat menu (model, Fast Mode, effort, permissions), and View (sidebar, inspector panes).
- The inspector is full-height, attached to the split view, and present on every screen (`No Session` on New Chat). Its toggle is a plain button declared in the inspector's own toolbar, so it sits above the column and never tints. Inside, a `.pickerStyle(.tabs)` picker (`Tasks`, `Session`, `MCP`; `Tasks` first and default) sits in a top `safeAreaBar` over the pane. View ▸ Inspector repeats the panes (⌥⌘1–3 always show theirs); ⌥⌘I shows or hides it on the last pane.
- The sidebar shows one host, chosen from the Host menu in the menu bar (hosts, Connect/Reconnect, Manage Hosts…). It is not a toolbar control: it changes only when switching sessions, and the subtitle names it whenever more than one host is configured. Switching host opens New Chat on it. Chats are grouped by date or by directory (View menu and the list's context menu), most recent first, using Claude's generated session title when available. Connection states are an overlay, not rows.
- New Chat has no form: the folder pop-up sits above the composer, where a chat's status strip goes, so nothing scrolls under the toolbar and the detail column looks the same as a chat's. A host that isn't connected shows `NotConnectedView` over the detail area, as the sidebar does.
- The composer stays mounted under a pending prompt (Send disabled) so a draft survives it.
- Settings apply immediately; text fields commit on Return or focus loss. No Save/Revert.
- Settings uses a General/Hosts sidebar; the Hosts pane selects a host above its detail form.
- Copy is terse and title case. An empty state is a title; add a description only when it says something the title doesn't and the user can act on it. Never show raw enum or wire values.
- Prompt suggestions are buttons above the composer, not text inside its glass field.
- Transcript and composer share the selected reading width: Narrow (default), Medium, or Wide.
- Do not show reasoning/“Thought” content. A quiet “Thinking…” line may mark the interval before visible output; it disappears once a message or tool call is present.
- Completed adjacent tool calls fold into a compact group. Running, failed, and denied work remains individually visible. Subagents and workflows belong primarily in the Tasks inspector.
- Progress indicators are transient. Every failed, unavailable, disconnected, or not-loaded path needs an explanatory state and a useful recovery action.
- Previews are part of the product-development workflow. Add representative `#Preview` coverage when adding or materially changing a view; seed samples through the real reducers where practical.

## Task tracking

Work is tracked in GitHub Issues on `AFRUITPIE/tether-app` (private), not in a
checked-in task file. Several agents work on this repository independently and
cannot see each other's transcripts, so the issue list is the shared state.

Use the `gh` CLI:

```sh
gh issue list                      # what is open
gh issue view <n>                  # the full description and discussion
gh issue comment <n> --body "..."  # claim it, or record a finding
gh issue close <n> --comment "..." # say what landed and how it was verified
```

Before starting, claim the issue with a comment so another agent does not
duplicate the work. Record anything you learn that changes the shape of the
task — a wrong assumption, a protocol detail, a rejected approach — as a
comment rather than only in a commit message; the next agent reads the issue,
not your transcript.

Reference the issue in the commit that addresses it (`Fixes #12`) so the log
and the tracker stay tied together. Open a new issue rather than expanding an
existing one when you find something unrelated in passing.

Issues labelled `verify` are changes that are written but not yet confirmed in
the running app. They usually cover motion or system behaviour that previews
cannot show, so they need `RunProject`, not `RenderPreview`.

Server-side work belongs to `AFRUITPIE/tether-server`; use `gh --repo` to file
it there when a change crosses the boundary.

## Commit messages

Commits carry no agent attribution: no `Co-Authored-By` trailer, no "generated
with" footer, no mention of the tool that wrote them. The author is always the
repository owner. Mentions of Claude Code as a product are fine and expected —
this app is a client for it.

## Generated code boundary

`TetherProtocol` is generated in the server repository. Never hand-edit:

```text
../tether-server/Sources/TetherProtocol/Generated.swift
../tether-server/schema/tether.schema.json
```

Change the Zod protocol definitions and implementation in `tether-server`, run `mise run gen` there, then update app call sites. Protocol unions deliberately preserve unknown future variants; keep forward-compatible fallbacks.

## Build and verification

Prepare the bundled server artifacts when server code or packaging changes:

```sh
cd ../tether-server
mise run compile          # into dist/, picked up by the app's build phase
mise run release          # tag, publish the binaries, and record the Agent SDK version
```

`TETHER_VERSION` comes from `package.json`, and the daemon replaces a running one only when that string differs. It is deliberately not the Agent SDK version: a server fix has to be able to ship without waiting for an SDK release. `AGENT_SDK_VERSION` is exported and reported separately.

Use Xcode 27 MCP as the primary app workflow. Open `Tether.xcodeproj`, then use the Xcode tools rather than raw `xcodebuild` or a separately launched LLDB session:

- `BuildProject` for app builds and diagnostics.
- `RenderPreview` for deterministic view verification and visual variants.
- `RunProject` with `attachDebugger: true` for the real app.
- `InvokeDebuggerCommand` and `GetConsoleOutput` for crashes, exceptions, and runtime warnings.
- Keep `TETHER_OPEN_THREAD=<id>` in the shared scheme when a repeatable launch target is needed, and disable it again before finishing unless the change is intentional.

Always look at the rendered or running UI after a UI change. A clean compile is not visual verification. Confirm that the inspected window belongs to the run you started; multiple stale Tether instances have previously caused false conclusions.

Package tests:

```sh
swift test --package-path TetherKit
```

The shared Xcode scheme also contains `TetherAppUITests`. Its launch sets
`TETHER_UI_TEST_MODE=1`, which uses an in-process JSON-RPC fixture and fails closed before any
daemon or SSH launch. The PR workflow runs it on `xcode-27` and resolves the public
SwiftPM protocol package without a repository secret.

Live tests use a real Claude CLI session and can incur cost:

```sh
TETHER_E2E=1 swift test --package-path TetherKit
```

Do not run live/E2E tests unless their cost and external effects are warranted by the task. SSH end-to-end testing is currently deferred unless explicitly requested.

## Change discipline

- Read both repositories before changing a cross-boundary behavior.
- Preserve unrelated working-tree changes and Xcode user state.
- Keep changes small and coherent. Do not rewrite history, delete sessions, terminate user-owned app instances, or change host configuration without explicit direction.
- Update this guide when architecture or settled UI rules change.

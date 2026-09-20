# Tether app contributor guide

## What this repository is

Tether is a native macOS SwiftUI client for Claude Code. It is intentionally a thin client: it presents hosts, sessions, streamed transcript items, prompts, and settings while `../tether-server` owns Claude Agent SDK queries and long-lived session state.

The two repositories must remain siblings:

```text
~/Code/tether-app
~/Code/tether-server
```

`TetherKit/Package.swift` imports the generated `TetherProtocol` Swift package from `../../tether-server`. The Xcode app target also copies compiled server binaries from `../tether-server/dist` into the app bundle.

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
  - `AppModel.swift`: hosts, selection, defaults, and persisted preferences.
  - `RootView.swift`: split view, sidebar, stable toolbar, inspector attachment, and new-chat flow.
  - `ThreadView.swift`: transcript, bottom bar, session controls, and the tabbed inspector.
  - `Composer.swift`: text/image/file input plus `/` commands and `@` file completion.
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

## UI and HIG decisions

The product should feel like a standard current macOS app. Prefer native SwiftUI components and behavior over custom chrome. Check the relevant Apple Human Interface Guidelines and API documentation for every interaction or presentation change.

- Target the current project baseline (Xcode 27, Swift 6, macOS 26.6+). Do not add compatibility shims for older systems unless requested.
- Let system layout and intrinsic sizing work. Avoid hand-computed geometry, arbitrary fixed production sizes, and `.fixedSize()` as a general layout repair. Fixed frames in previews and small icon/status geometry are fine.
- Liquid Glass belongs to controls: toolbar controls, composer, and prompt cards. Transcript content uses ordinary fills. Never stack glass on glass; controls inside a glass card use standard bordered styles.
- The `NavigationSplitView` owns one stable window toolbar and the inspector. Toolbar items must not disappear, jump, or overflow while sidebars animate.
- Model, effort, permission mode, and optional fast mode are session controls in the window toolbar. They are real pop-up buttons (`Picker` with `.menu` style): a flat mutually exclusive list that displays the current value. They are not action menus.
- The inspector is full-height and attached to the split view. It uses a segmented control with `Tasks`, `Session`, and `MCP`; `Tasks` is first and default.
- New Chat is an icon-only circular toolbar action beside the left-sidebar toggle and disappears with that sidebar. The File-menu `Command-N` action remains available while the sidebar is hidden.
- The sidebar is flat per host, ordered most-recent-first, and uses Claude's generated session title when available rather than permanently showing the first prompt.
- Prompt suggestions are buttons above the composer, not text inside its glass field.
- Transcript and composer share the selected reading width: Narrow (default), Medium, or Wide.
- Do not show reasoning/“Thought” content. A quiet “Thinking…” line may mark the interval before visible output; it disappears once a message or tool call is present.
- Completed adjacent tool calls fold into a compact group. Running, failed, and denied work remains individually visible. Subagents and workflows belong primarily in the Tasks inspector.
- Progress indicators are transient. Every failed, unavailable, disconnected, or not-loaded path needs an explanatory state and a useful recovery action.
- Previews are part of the product-development workflow. Add representative `#Preview` coverage when adding or materially changing a view; seed samples through the real reducers where practical.

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
mise run compile
```

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

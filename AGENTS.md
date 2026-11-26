# Sundown contributor guide

## What this is

A native macOS SwiftUI client for Claude Code and its companion daemon (`server/`, published to npm as `tether-server`).
The app is a thin client: it shows hosts, chats, streamed transcript items, requests and settings, while the daemon runs
the Agent SDK queries against the host's own `claude` (`TETHER_CLAUDE_PATH`, else `PATH`, else the login shell's) and
owns every live session. Closing the app never ends a turn.

```text
tether connect         stdio <-> daemon socket; starts the daemon, or replaces one of another version (what the app runs)
tether daemon          the daemon, on <TETHER_HOME>/tether.sock (mode 0600; TETHER_HOME defaults to ~/.tether)
tether serve --stdio   one client, in-process (development, tests); keeps task state only under an explicit TETHER_HOME
```

Each host runs the server with the first `npx` on its login shell's PATH: `npx --yes tether-server@<version> connect`,
locally or over system `ssh`, at the version the app pins (`ServerRelease.version`, `Bootstrap.swift`). Nothing is
checked or installed first; a host without Node.js 18+ fails to connect with the shell's own error. The app speaks
protocol 2 and refuses an older server (`HostConnection.minServerProtocol`).

Built with Xcode 27 and Swift 6, running on macOS 26 and later (deployment target 26.0). Anything new in macOS 27 goes
behind `#available`. The server is TypeScript on Bun (pinned in `server/mise.toml`), bundled to a single Node 18+ file
for npm.

## Building and testing

### App (macOS)

- **Build:** open `Sundown.xcodeproj`, or `xcodebuild build -project Sundown.xcodeproj -scheme Sundown -destination 'platform=macOS'`.
  The project file is `project.xcproj`, Xcode 27's JSON project format: edit it directly, as text (JSON5, trailing commas).
- **Package tests:** `swift test --package-path SundownKit`. No server, no network: hosts are `FakeHost`, and
  `TetherProtocolTests` decodes recorded wire traffic.
- **UI tests** (`SundownAppUITests`, in the `Sundown` scheme): they drive the app with real key presses, which go to whatever
  window is in front, so run them only when nobody is using the Mac, or leave them to CI. The `Sundown Performance` scheme
  runs `SundownPerformanceUITests` in Release (hitches, CPU, memory, signposts); the main scheme and CI skip it.
- **Benchmarks:** `SUNDOWN_BENCH=1 swift test -c release -Xswiftc -DDEBUG -Xswiftc -enable-testing --package-path SundownKit --filter Benchmark`;
  compare against the parent commit on the same Mac. `benchmarks.yml` does that on a runner: started on a branch, it runs them
  on the branch and on where it left `main`, and reports each metric's change (`Scripts/bench-compare.py`).
- **Costs money or touches real hosts:** `SUNDOWN_E2E=1` (live tests against a real `claude`; set `TETHER_SERVER_BIN`),
  `SUNDOWN_NPX_E2E=1` (runs the published server with npx), `SUNDOWN_SSH_*` (SSH end to end). Run them only when asked.
- Always look at the running app after a UI change; a clean build isn't a visual check. Make sure the window you look at
  belongs to the build you just made.

### Server (`server/`, mise tasks with Bun pinned in `server/mise.toml`)

Run inside `server/`:

- `mise run install`, `typecheck`, `test`: `bun install`, `tsc --noEmit`, Bun unit tests (no `claude`, no network).
  `test/cli.test.ts` runs the CLI modes as processes (fresh `HOME`/`TETHER_HOME`, stand-in `claude`); `TETHER_TEST_BINARY=<path>`
  targets a compiled binary instead.
- `mise run gen`: regenerates `server/schema/tether.schema.json` and `SundownKit/Sources/TetherProtocol/Generated.swift`
  from `server/src/protocol` (`test/generated.test.ts` catches drift). Never hand-edit either file.
- `mise run swift-test`: runs `TetherProtocolTests` in `SundownKit`.
- `mise run dev`: `serve --stdio` from source. To run the working copy from the app, set This Mac's Server Command
  (Settings ▸ Hosts ▸ Advanced) to `<bun> run <repo>/server/src/cli.ts connect`, with full paths.
- `mise run compile`: standalone binaries in `server/dist/` (`TETHER_TARGETS` to choose). `mise run build-npm`: the npm
  package in `server/npm/`, a single bundled file for Node 18+.
- `mise run bench`: hot-path benchmarks over copies of real transcripts in `~/.claude/projects` (read-only, no `claude`).
- **Costs money:** `mise run e2e` (`scripts/e2e*.ts`) and `scripts/record-sdk.ts` run the real `claude` on the host's account,
  creating temp projects and real sessions. Run them only when asked, or when nothing else can check a change.

### Without a Mac

On Linux or in a cloud session there is no Xcode, so Swift doesn't build locally (server tests still run locally with Bun);
GitHub Actions is the Mac. Push the branch and run `tests.yml` on it (`workflow_dispatch`, any branch, no pull request needed;
a pull request runs it too). It builds the app and runs the package tests, UI tests (Xcode 27 runners), and server tests
(Ubuntu + macOS 26); read failures in the job logs, and each run uploads its `.xcresult`. A run takes a quarter of an hour
of macOS runner time, so get as far as reading the code and running server tests allows first.
For speed, run `benchmarks.yml` on the branch (`gh workflow run benchmarks.yml --ref <branch>`, optionally `-f base=<ref>`);
its numbers are in the run's summary, in the log between `BEGIN-BENCH-JSON` and `END-BENCH-JSON`, and in its `benchmarks`
artifact. The runner has no CPU counters and its times wander, so it compares CPU time, clock time and peak memory over
rounds in alternating order, and counts a change only with no overlap between the rounds and at 10% or more for times, 3%
for memory: it catches regressions, not small wins, which still need a Mac. It builds twice in Release, so use it when
working on speed, not on every change.
CI can't look at the app for you: a UI change still needs someone to look at the running app.

## Repository map

- `Sundown/`: the app target: `SundownApp.swift` (scenes, commands), `SundownIntents.swift` (Shortcuts), `Info.plist` (`sundown://`).
- `SundownKit/Sources/TetherProtocol`: generated `Generated.swift` plus hand-written `Support.swift`.
- `SundownKit/Sources/SundownKit`: transport and state, no UI.
  - `Bootstrap.swift`: the pinned server version and the connect command (PATH from the host's interactive shell, then `npx`).
  - `Transport.swift`: the server process and its JSONL pipes. `RPCClient.swift`: JSON-RPC (an actor), notifications batched per frame.
  - `HostConnection.swift`: one host: connecting, reconnecting and replay, the catalog, chats, older pages, letting idle chats go.
  - `ThreadModel.swift`: one chat's state (`@MainActor @Observable`). `TranscriptRows.swift`: folding items into rows.
  - `PendingStart.swift` (New Chat before the host answers), `Edits.swift`, `WorkingChanges.swift`, `Workflow.swift`,
    `Reconnect.swift` (backoff, network), `Hosts.swift`, `Signposts.swift`.
- `SundownKit/Sources/SundownUI`: views and app state. `AppModel` (hosts, preferences, drafts), `WindowModel` (one window: host,
  chat, tab; `WindowTarget` is its scene value), `RootView` (split view and toolbar), and folders `Sidebar/`, `Toolbar/`, `Panes/`
  (Tasks, Diff, popovers), `Thread/` (transcript, composer, bottom bar), `NewChat/`, `Settings/`. Messages are drawn by
  `MarkdownBuilder` (swift-markdown's tree to attributed text) and `MarkdownText` (one read-only TextKit 1 view per message).
- `SundownKit/Sources/SundownFixtures`: an in-memory daemon (`FakeHost`) and the chats it serves (`FixtureScenario`), compiled
  into every build and inert unless the app is launched with `SUNDOWN_UI_TEST_MODE=1`. Previews' samples are in `PreviewSupport.swift`.
- `SundownKit/Sources/SundownTestSupport`: `eventually`, observation checks, item builders.
- `SundownKit/Tests`: `TetherProtocolTests` (decoding `Fixtures/e2e-wire.jsonl`), `SundownKitTests` (state, folding, connections,
  real workflow captures) and `SundownUITests` (view logic, Markdown, the transcript's height index, request budgets, benchmarks).
- `server/`: the Tether daemon (`tether-server` on npm).
  - `src/cli.ts`: modes. `src/version.ts`: `version --json`. `src/claude.ts`: finds `claude` (`resolveClaude`).
  - `src/protocol/`: the Zod protocol, and the only schema source (`common.ts` holds `PROTOCOL_VERSION`, `methods.ts`,
    `notifications.ts`, `serverRequests.ts`, `items.ts`, `tasks.ts`).
  - `src/rpc/connection.ts`: JSONL framing, correlation, cancellation, error codes.
  - `src/server/`: `session.ts` (handshake, dispatch, subscriptions), `fsApi.ts` (`fs/*`, `git/*`, worktrees), `diff.ts`.
  - `src/daemon/daemon.ts`: socket daemon, detached start, `connect` bridge, version handoff.
  - `src/threads/`: `ThreadManager.ts` (loaded/followed threads, catalog, eviction, draining), `LiveThread.ts`,
    `FollowedThread.ts`, `events.ts` (`EventStream`, `seqOrigin`), `itemizer.ts`, `transcript.ts` (`readSessionHistory`,
    `TranscriptExtras`, `TranscriptTail`), `tasks.ts`, `scheduled.ts`, `workflows.ts` (`isSafeId`), `taskStore.ts`,
    `edits.ts`, `pushQueue.ts`. `src/client/TetherClient.ts`: E2E client.
  - `scripts/`: code generation, `compile`, `build-npm`, E2E, `record-sdk`. `bench/run.ts`. `test/`: unit and capture tests
    replaying recorded fixtures with no `claude`.

## Invariants

### Protocol & server

- **Wire:** JSON-RPC 2.0 as JSONL, one object per line, with no `"jsonrpc"` member.
- **Handshake first:** every method except `initialize` fails with `notInitialized` until it's done. Params are
  validated against the method's Zod schema before the handler runs.
- **Zod is the only schema source.** Edit `server/src/protocol`, run `mise run gen` in `server/`, then update Swift call sites.
  Never hand-edit `server/schema/tether.schema.json` or `SundownKit/Sources/TetherProtocol/Generated.swift`. Keep Swift
  forward-compatible: string enums as `RawRepresentable` structs, discriminated unions with `.unknown`. Fix mismatches in
  the schema or generator, not with hand-written decoding in the app.
- **Versions** (`server/src/protocol/common.ts`): bump `PROTOCOL_VERSION` only for breaking changes. Raise
  `MIN_CLIENT_PROTOCOL` only when older clients can't be served; they then get `incompatibleProtocol`, with both numbers.
  Additive changes bump neither, and new result fields must be optional. `connect`'s upgrade client (`tether-upgrade`) is
  served at any protocol, but only for `host/requestShutdown`, so any release can replace any other's daemon.
- **Sequencing:** thread-scoped notifications carry `threadId` and a per-thread `seq`; `thread/summaryChanged` is
  host-wide and has neither. Each new stream starts at `seqOrigin()`, above every earlier stream, so a stale `afterSeq`
  shows as a gap. `historySeq`, `lastSeq` and `afterSeq` are applied so snapshot and live tail never overlap or leave a gap;
  a replay gap reloads as far back as the chat already held, no further.
- **Disconnects never end work.** The daemon owns the queries. Eviction and upgrade drains skip any thread that is running,
  waiting on a person, starting, or has background work (`ThreadManager.busy`, `sweep`).
- **Server requests** stay pending until a subscriber answers or the SDK cancels. They're re-sent to each client that
  subscribes, the first answer wins, and the rest get `serverRequest/resolved` (keep the once-only answer in the app).
- **Live and history parity:** both paths must yield the same items, turns and tasks. Capture tests assert this.
- **Tasks are whole state:** `task/updated` carries a complete `TaskState`, never a patch.
- **Unmodeled SDK messages are ignored, never errors.** Shapes change between Claude Code versions, so read optional
  fields defensively.
- **Ids that name paths** (session, thread, workflow run, agent) must pass `isSafeId` first.
- **stdout carries protocol only.** Logs go to stderr; the daemon's stderr is `<TETHER_HOME>/daemon.log`, which nothing
  rotates. Claude Code's stderr goes there too, per thread and with long lines cut.
- **Host config stays the host's:** `settingSources: ['user','project','local']`, the `claude_code` preset prompt, and client
  env layered over the host's. Human input is sent with `origin: { kind: 'human' }`.
- **Session tools:** only the `tether` server's own tools (`SESSION_TOOL_NAMES`), on threads that requested them, skip the
  permission prompt.
- **Isolation:** tests must never touch the real `~/.tether`, daemon or Claude sessions. Use temp `TETHER_HOME`
  (and `HOME`/`CLAUDE_CONFIG_DIR` for transcripts) and a stand-in `claude`. `serve --stdio` uses `<TETHER_HOME>/tasks`
  only when `TETHER_HOME` is set; every E2E script sets a temp one.

### Server subsystems that surprise people

These depend on undocumented Claude Code behavior (background in `server/docs/notes.md`, not auto-loaded, may be stale):

- **History across compactions** (`transcript.ts` `readSessionHistory`): the SDK follows only the latest message chain,
  and every compaction starts a new one, so history is rebuilt chain by chain. `TranscriptExtras` reads back records the
  SDK drops. See `server/test/history.test.ts`.
- **Workflows** (`workflows.ts`, `itemizer.ts`): visible only through `workflow_progress` and the session folder's files.
  See `server/test/workflows.test.ts`, `workflowCapture.test.ts`, `slowCheckCapture.test.ts`.
- **Scheduled jobs and goals** (`scheduled.ts`): /loop, CronCreate, ScheduleWakeup and /goal read prompts from the
  transcript and pending wakeups from a Stop hook (`sessionCrons`). Tether runs no scheduler of its own. See
  `server/test/scheduled.test.ts`, `loopGoalCapture.test.ts`.
- **Skill instructions** become the Skill call's `skillInstructions`, never a message (live by position, history by
  `sourceToolUseID`). See `server/test/tasks.test.ts`.
- **Task state & store** (`tasks.ts`, `taskStore.ts`): recomputed from CLI facts after any message that could change it;
  live-only fields (usage, task types, workflow agents) are persisted and merged into reads. A running task whose process
  is gone is shown as stopped.

`TETHER_DEBUG_TASKS=1` (raw `task_*` messages) and `TETHER_DEBUG_MESSAGES=1` (all SDK messages except deltas) log to
the daemon log. Use them to capture fixtures.

### App

- **Threads:** network and process work stay off the main actor; UI state is `@MainActor @Observable`. Never create or insert
  an observable model from a `body`.
- **One `ThreadModel` per (host, thread id)**, for its whole life: replacing one loses subscriptions, pending requests and the
  reader's place. A chat opened before its host connects waits in `openRequested`.
- **Streaming is coalesced:** at most one transcript update per frame, a reply's text appended in place, and the last turn
  folded again while earlier turns are kept. What the sidebar, toolbar or tabs read (`title`, `tasks`, status) never changes per
  delta; only the transcript reads `rows` and `items`.
- **No work in bodies:** parsing, folding, diffs and Find run off the main actor or are cached.
- **Views take the narrowest model they need**, and no closure goes in the environment (use `WindowRef` and call the window).
- **A `ForEach` element is one view** (wrap a `switch` in a stack), so SwiftUI can count rows without building them.
- **Toolbar:** every item is unconditional and identical across windows that share a toolbar identifier, or AppKit throws
  (`_currentItems`). A window opened for one chat has no split view and its own identifier (`chatWindow`).
- **Persisted state:** preferences are plain properties on `AppModel` saved through `Stored`, written only when changed; host
  secrets are in the Keychain; drafts in `Drafts.json`, never observed.
- **Slash commands** are fetched only when someone looks for one: the daemon starts a Claude Code process to answer.
  `RPCBudgetTests` holds how many requests each flow sends; lower a budget when a change sends fewer.

## The transcript

Every settled row's height is known before the row is built, so nothing about scrolling is a guess:

- `HeightIndex` (`Thread/TranscriptHeights.swift`) holds the heights and where each row starts. `RowMeasurer`
  (`RowHeights.swift`) gets a message's height from its text, laid out off the main thread with the same code the text view
  measures itself with (`MarkdownNSTextView.height`), and any other row's by measuring it once.
- History is a plain stack of the rows near the view between two spacers of exact height; the running turn is a plain stack
  of its own (`TranscriptSplit`), so a streamed delta never touches history. **No lazy stack**: one guesses the height of rows
  it hasn't built, which left chats blank.
- `TranscriptModel` keeps the reader's place as the row at the top of the view and how far down it, put back in the same
  update as any change above it (an older page, a corrected height, a new width). At the end, the position is the bottom edge.
- A built row reports its height; one that differs from the index corrects it, and Debug builds log it (category
  `TranscriptHeights`). A logged mismatch is a measuring bug.
- `ScrollKeeper` is the one AppKit hook, because a `ScrollPosition` set while the wheel is turning isn't applied (macOS 27.2).

## UI rules

Prefer native SwiftUI and the HIG; use AppKit only where SwiftUI has no API, and say why in a comment. AppKit is used today
for the Clipboard and Finder, the Dock, opening a file in a chosen editor, help tags over glass, wake and quit, a message's text (`MarkdownView`), the message
field (`ComposerTextView`) and `ScrollKeeper`. Fix things with SwiftUI's own modifiers, never by reaching into the views SwiftUI builds.

- Liquid Glass is for controls (toolbar, composer, request cards); transcript content uses ordinary fills. Never glass on glass.
- Let layout size itself: no `GeometryReader` for layout, no fixed production sizes, `fixedSize` only on the axis that must hold.
- Errors are quiet: gray text and a plain glyph, never red. Red is for danger (Bypass Permissions) and diffs.
- Every toolbar control is also in the menu bar, and a context menu is never the only way to a command.
- Copy is terse and title case; a status line that reads as a sentence is sentence case. Say "directory", not "folder".
  Numbers, dates and counts go through `FormatStyle`; never show raw enum or wire values.
- Few settings: add one only when people genuinely differ. What Claude Code's own settings manage (model, effort, permission
  mode) stays unset here, so each host's Claude Code decides.
- Reasoning ("Thought") is never shown. Background tasks live in the Tasks tab, not as transcript lines.
- Add `#Preview`s when adding or materially changing a view, seeded through the real reducers where practical.
- A pull request that changes the UI includes before and after screenshots.

## Fixtures and the stress driver

UI tests and performance work launch the app with `SUNDOWN_UI_TEST_MODE=1`, which connects every host to `FakeHost` and never
starts a daemon or SSH. `SUNDOWN_UI_TEST_SCENARIO` picks the chats: none (one short chat), `performance`, `connect-failure`,
`tasks`, `prompts`, `showcase` (the README's screenshots; the `Sundown Showcase` scheme). Knobs: `SUNDOWN_PERF_TURNS`,
`SUNDOWN_PERF_VARIED=1` (realistic reply heights), `SUNDOWN_PERF_LONG_REPLY=n`, `SUNDOWN_PERF_LONG_TURN=1`,
`SUNDOWN_PERF_REPLY_SECTIONS`, `SUNDOWN_UI_TEST_FAIL=method,…`, `SUNDOWN_UI_TEST_GAP=1`, `SUNDOWN_UI_TEST_DEFAULTS=<suite>`.

In Debug builds, commands appended to the file named by `SUNDOWN_STRESS_FILE` drive the window (`StressDriver.swift`: scroll,
wheel, resize, snap, send, chat, tab, fold, find, prompt, probe). Launching the binary directly still writes the real
`com.haydenhong.Sundown` window frames and sidebar width, so back those defaults up first.

Signposts and logs use subsystem `com.haydenhong.Sundown`: `/usr/bin/log stream --level debug --signpost --predicate 'subsystem == "com.haydenhong.Sundown"'`.

## Releases

Server and app versions move independently (`server/package.json` vs `MARKETING_VERSION` in `project.xcproj`):

- **Server (`server-release.yml`):** merging a `server/package.json` version bump tests, bundles `server/npm`, smoke-runs
  `node npm/cli.js version --json`, stages `tether-server` on npm via trusted publishing (OIDC, provenance), and pushes a
  `server-v<version>` git tag (not a GitHub Release, keeping Releases strictly for the app). Approve the staged package on
  npmjs.com with 2FA to publish it.
- **App (`release.yml`, running `Scripts/release.sh`):** merging a `MARKETING_VERSION` bump releases the app (Developer ID,
  notarized, approved in the `release` environment, verified that `ServerRelease.version` is live on npm), publishes the
  `v<version>` GitHub Release, and updates the Homebrew tap. `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are set only
  on the app target. Main stays at the released version, so bumping it is deciding to release: a pull request that does is
  held by Release Check's Approval until the owner approves it in the `release-approval` environment.
  `Scripts/release.sh --beta [<PR> | <branch>]` makes a beta on this Mac.
- **Agent SDK (`sdk-update.yml`):** keeps one `agent-sdk` PR open that moves `server/` to the newest Agent SDK, bumps
  `server/package.json`, pins `ServerRelease.version`, and bumps Sundown's patch version. On merge, approve the staged npm
  release first, then approve the `release` environment.

CI (`tests.yml`, on pull requests) runs Package Tests, UI Tests (Xcode 27 runners), and Server Tests (Ubuntu + macOS 26);
branch protection requires Package Tests, UI Tests, and Approval (`release-check.yml`).

## Working here

- Work is tracked in GitHub Issues (`gh issue list`). Comment on an issue before starting it, and record anything that changes
  the task there. Reference it from the commit (`Fixes #12`).
- Commits and PRs carry no agent attribution: no `Co-Authored-By`, no "generated with". The author is the repository owner.
- Don't run paid tests, delete sessions, stop the user's app or daemon, or change host configuration unless asked.
- Keep this guide short and true. Behavior, history and measurements belong in code comments and tests.

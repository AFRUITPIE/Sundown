# Sundown contributor guide

## What this is

A native macOS SwiftUI client for Claude Code. It's a thin client: it shows hosts, chats, streamed transcript items,
requests and settings, while [tether-server](https://github.com/AFRUITPIE/tether-server) (`../tether-server`) runs the
Agent SDK queries and owns every live session. Closing the app never ends a turn.

Each host runs the server with the first `npx` on its login shell's PATH: `npx --yes tether-server@<version> connect`,
locally or over system `ssh`, at the version the app pins (`ServerRelease.version`, `Bootstrap.swift`). Nothing is
checked or installed first; a host without Node.js 18+ fails to connect with the shell's own error. The app speaks
protocol 2 and refuses an older server (`HostConnection.minServerProtocol`).

Built with Xcode 27 and Swift 6, running on macOS 26 and later (deployment target 26.0). Anything new in macOS 27 goes
behind `#available`.

## Building and testing

- **Build:** open `Sundown.xcodeproj`, or `xcodebuild build -project Sundown.xcodeproj -scheme Sundown -destination 'platform=macOS'`.
  The project file is `project.xcproj`, Xcode 27's JSON project format: edit it directly, as text (JSON5, trailing commas).
- **Package tests:** `swift test --package-path SundownKit`. No server, no network: hosts are `FakeHost`.
- **UI tests** (`SundownAppUITests`, in the `Sundown` scheme): they drive the app with real key presses, which go to whatever
  window is in front, so run them only when nobody is using the Mac, or leave them to CI. The `Sundown Performance` scheme
  runs `SundownPerformanceUITests` in Release (hitches, CPU, memory, signposts); the main scheme and CI skip it.
- **Benchmarks:** `SUNDOWN_BENCH=1 swift test -c release -Xswiftc -DDEBUG -Xswiftc -enable-testing --package-path SundownKit --filter Benchmark`;
  compare against the parent commit on the same Mac.
- **Costs money or touches real hosts:** `SUNDOWN_E2E=1` (live tests against a real `claude`; set `TETHER_SERVER_BIN`),
  `SUNDOWN_NPX_E2E=1` (runs the published server with npx), `SUNDOWN_SSH_*` (SSH end to end). Run them only when asked.
- Always look at the running app after a UI change; a clean build isn't a visual check. Make sure the window you look at
  belongs to the build you just made.

### Without a Mac

On Linux or in a cloud session there is no Xcode, so nothing here builds locally; GitHub Actions is the Mac. Push the branch
and run `ui-tests.yml` on it (`workflow_dispatch`, any branch, no pull request needed; a pull request runs it too). It builds
the app and runs the package tests and the UI tests on Xcode 27 runners; read failures in the job logs, and each run uploads
its `.xcresult`. A run takes a quarter of an hour of macOS runner time, so get as far as reading the code allows first.
The repository is cloned alone there, so a change that needs an unreleased tether-server waits for its release.
CI can't look at the app for you: a UI change still needs someone to look at the running app.

### Both repositories side by side

With `../tether-server` checked out, `SundownKit/Package.swift` takes `TetherProtocol` from it by path, so a protocol change
shows on the next build with no release. That empties both `Package.resolved` files: put them back
(`git checkout -- '*Package.resolved'`) before committing. `SUNDOWN_USE_RELEASE=1` uses the published package at its pin,
as CI and a fresh clone do. To run that checkout's server, set This Mac's Server Command (Settings ▸ Hosts ▸ Advanced) to
`<bun> run <path>/tether-server/src/cli.ts connect`, with full paths.

The protocol is generated in tether-server: change its Zod, run `mise run gen` there, then update the call sites here.
Never hand-edit `Generated.swift`. Protocol enums and unions keep unknown future values; keep the fallbacks.

## Repository map

- `Sundown/`: the app target: `SundownApp.swift` (scenes, commands), `SundownIntents.swift` (Shortcuts), `Info.plist` (`sundown://`).
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
- `SundownKit/Tests`: `SundownKitTests` (state, folding, connections, real workflow captures) and `SundownUITests` (view logic,
  Markdown, the transcript's height index, request budgets, benchmarks).

## Invariants

- **Threads:** network and process work stay off the main actor; UI state is `@MainActor @Observable`. Never create or insert
  an observable model from a `body`.
- **One `ThreadModel` per (host, thread id)**, for its whole life: replacing one loses subscriptions, pending requests and the
  reader's place. A chat opened before its host connects waits in `openRequested`.
- **Sequencing:** `historySeq`, `lastSeq` and `afterSeq` are applied so a snapshot and its live tail never overlap or leave a gap.
  A replay gap reloads as far back as the chat already held, no further.
- **Server requests** may be answered by another client: keep the once-only answer, and drop the card on `serverRequest/resolved`.
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

Releases happen on merge, down a chain. A new Agent SDK becomes a tether-server PR; merging a server version bump publishes it
to npm (approved by hand). A newly published server becomes a PR here (`server-update.yml`: `ServerRelease.version`, both
`Package.resolved` pins and the app's next patch version). Merging an app version bump releases the app (`release.yml`,
running `Scripts/release.sh`: Developer ID, notarized, approved in the `release` environment), then updates the Homebrew tap.
`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are set only on the app target. Main stays at the released version, so
bumping it is deciding to release. `Scripts/release.sh --beta [<PR> | <branch>]` makes a beta on this Mac.

CI (`ui-tests.yml`, on pull requests) runs the package tests and the UI tests side by side on Xcode 27 runners.

## Working here

- Work is tracked in GitHub Issues (`gh issue list`). Comment on an issue before starting it, and record anything that changes
  the task there. Reference it from the commit (`Fixes #12`).
- Commits and PRs carry no agent attribution: no `Co-Authored-By`, no "generated with". The author is the repository owner.
- Don't run paid tests, delete sessions, stop the user's app or daemon, or change host configuration unless asked.
- Keep this guide short and true. Behavior, history and measurements belong in code comments and tests.

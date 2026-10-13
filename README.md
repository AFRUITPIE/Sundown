# Sundown

A native Mac app for [Claude Code](https://www.anthropic.com/claude-code). Chat with Claude on this
Mac or on any machine you can reach over SSH, watch its agents and background work, and review what
it changed, in an app that looks and feels like it came with macOS.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/chat-dark.webp">
  <img alt="A Sundown window: a sidebar of chats, a conversation in which Claude added offline caching, and the Context popover showing how full the context window is." src="docs/screenshots/chat-light.webp">
</picture>

Sessions run in [tether-server](https://github.com/AFRUITPIE/tether-server), a small daemon on each
host, so a turn keeps going when you close the app, put the Mac to sleep or lose the connection.
Open Sundown again and the chat picks up where it was.

## What it does

- **Chats on any host.** This Mac, or anything you can `ssh` to. Each host keeps its own chats,
  grouped by date or by directory, pinned, archived and searchable.
- **Tasks.** Every agent, workflow, background command and monitor a chat starts, browsed in
  columns: what each one is doing, what it started, and what it returned.
- **Diff.** The working tree against the last commit, refreshed after each turn. Click a line to
  leave a comment, and send the comments to Claude as one message.
- **The session, one click away.** Model and effort, permission mode, how full the context window
  is, and which MCP servers are connected.
- **Answer from anywhere.** Permission requests, questions and plans show as cards in the chat,
  and as notifications with Allow and Deny when you're looking at something else.
- **A Mac app.** SwiftUI and Liquid Glass, several windows and tabs, Shortcuts, `sundown://`
  links, VoiceOver, and the keyboard shortcuts you'd expect.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/tasks-dark.webp">
  <img alt="The Tasks tab: a chat's agents, monitors, commands and a workflow in the first column, the workflow's agents grouped by phase in the second, and the workflow's result in the third." src="docs/screenshots/tasks-light.webp">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/diff-dark.webp">
  <img alt="The Diff tab: changed files with added and removed lines, and a comment being written on one line." src="docs/screenshots/diff-light.webp">
</picture>

## Install

```sh
brew install --cask afruitpie/tap/sundown
```

Or download the latest release from GitHub. Sundown needs macOS 27 or later.

Each host needs [Claude Code](https://docs.anthropic.com/en/docs/claude-code) signed in, and
Node.js 18 or later with `npx` on its login shell's `PATH`. There is nothing else to install: the
app runs the tether-server version it was built for with `npx`, and the host's daemon moves to it
once its running chats finish.

## Develop

```
Sundown.xcodeproj     macOS app target (signing, bundle)
Sundown/              app entry point + assets
SundownKit/           Swift package
  SundownKit          transport (local shell / ssh), JSON-RPC client, host bootstrap, stores
  SundownUI           SwiftUI views (macOS 27 APIs, standard components, Liquid Glass on controls only)
```

Protocol types come from `TetherProtocol`, which is generated in
[tether-server](https://github.com/AFRUITPIE/tether-server). With a `tether-server` checkout beside
this one, the app builds against it; otherwise SwiftPM uses the published package at its pin.

1. Open `Sundown.xcodeproj` and run the **Sundown** scheme.
2. To run a `../tether-server` working copy instead of the published server, set This Mac's Server
   Command in Settings ▸ Hosts to `<bun> run <path>/tether-server/src/cli.ts connect`.
3. Debug builds accept `SUNDOWN_OPEN_THREAD=<id>`, set in the scheme's environment variables, to
   open a chat on launch.
4. The **Sundown Showcase** scheme launches the app on staged, in-process data, with no host and no
   Claude: the chats, tasks and diffs in the screenshots above.

[AGENTS.md](AGENTS.md) is the full contributor guide: architecture, invariants and the design
decisions behind the UI.

## Tests

`swift test --package-path SundownKit` runs the package tests without a live Claude session. The
`SundownAppUITests` target in the shared **Sundown** scheme launches the real app with
`SUNDOWN_UI_TEST_MODE=1`. That mode supplies an in-process JSON-RPC server and refuses to launch
the local daemon or SSH for any host without a fixture transport. It exercises Settings, host
management, chat streaming, and reconnection without inference calls. Run it locally with Xcode's
**Test** action. `SUNDOWN_E2E=1 swift test --package-path SundownKit` is the separate, opt-in live
suite against the real `claude`, and can incur cost.

The PR workflow runs both suites on the `xcode-27` GitHub runner and uploads the `.xcresult`
bundle. SwiftPM resolves the pinned `TetherProtocol` package from the public
`AFRUITPIE/tether-server` repository. No Claude credentials are supplied to CI.

## License

MIT, in [LICENSE](LICENSE).

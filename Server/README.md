# Sundown server

The server behind [Sundown](https://github.com/AFRUITPIE/Sundown), published to npm as `tether-server`: a JSON-RPC app server for Claude Code, built on the Claude Agent SDK. Modelled on the Codex app-server. It wraps whichever `claude` binary comes first on the host's `PATH`, so any provider setup that works in a terminal on that host (Bedrock through `AWS_PROFILE`, Vertex, API key, claude.ai login) also works through the server.

```
sundown-server connect         # what clients run: stdio ⇄ per-host daemon (starts it if needed)
sundown-server daemon          # the daemon: owns live Claude sessions; turns survive client disconnects
sundown-server serve --stdio   # single-client, in-process mode (tests)
```

A host runs it from npm, with Node 18 or later. The Sundown app runs this, pinned to its version:

```
npx --yes tether-server@<version> connect
```

`npm install -g tether-server` installs it instead. The package is one bundled file with no dependencies and no install scripts, published with npm provenance from [Sundown's repository](https://github.com/AFRUITPIE/Sundown), where it lives in `Server/`.

- **Wire format:** JSON-RPC 2.0 without the `"jsonrpc"` field, one JSON object per line (JSONL). The protocol is defined in `src/protocol` using zod.
- **Schema:** `mise run gen` writes `schema/server.schema.json` and the app's Swift types (`SundownKit/Sources/ServerProtocol/Generated.swift`).

## Protocol

Version 2 (`PROTOCOL_VERSION`; clients must send `protocolVersion: 2` in `initialize`). `schema/server.schema.json` has every method, notification and type; the Zod files in `src/protocol` document what each means. In short:

- Every thread-scoped notification carries `threadId` and a per-thread `seq`; a read's `historySeq` says which events its snapshot includes, and `thread/subscribe` with `afterSeq` replays the rest (`gap` when it can't).
- Edit calls carry their `edit` (hunks, lines added and removed, bounded), and a finished turn its `edits` totals.
- `git/changes` is the working tree against the last commit, untracked files included, parsed and bounded on the host.
- `thread/summaryChanged` tells every client when a chat's title, tag, status or background count changes (host-wide: no `seq`).
- `thread/start` with a prompt returns its item's `messageId` (and `turnId`); that item is on the chat's stream before the result.
- **Tasks** are typed state: `TaskState` (agents, commands, monitors, MCP tools, workflows and their agents, schedules, goals; each with its `parentId`, `status`, usage and kind-specific fields). `thread/read`, `thread/resume` (with history) and `thread/subscribe` return all of a chat's `tasks`, finished ones included, kept by the daemon across reloads and restarts; `task/updated` sends a task's whole state each time it changes.

## Development (Bun via mise)

```
mise install
mise run install
mise run test          # unit tests (itemizer against recorded SDK fixtures)
mise run typecheck
mise run e2e           # real `claude`, haiku model (spends tokens)
mise run gen           # regenerate JSON Schema + Swift
mise run swift-test    # the app's Swift decoding tests against recorded wire traffic (macOS)
mise run compile       # standalone binaries for darwin/linux × arm64/x64 → dist/
```

## License

MIT, in [LICENSE](LICENSE).

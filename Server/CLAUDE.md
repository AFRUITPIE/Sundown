# Claude Code instructions

@AGENTS.md

`AGENTS.md` is the server's guide (the app's is `../AGENTS.md`). In short: the Zod files in `src/protocol` are the schema source (regenerate, never hand-edit, the schema and Swift output); a client disconnect never ends a turn; `mise run e2e` and `scripts/record-sdk.ts` spend real tokens, so run them only when asked.

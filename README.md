# Sundown (macOS app)

A native SwiftUI client for [tether-server](../tether-server): Claude Code on this Mac, or on any host you can reach over SSH, with sessions that keep running while the app is closed.

```
Sundown.xcodeproj     macOS app target (signing, bundle)
Sundown/              app entry point + assets
SundownKit/           Swift package
  SundownKit          transport (local shell / ssh), JSON-RPC client, host bootstrap, stores
  SundownUI           SwiftUI views (macOS 27 APIs, standard components, Liquid Glass on controls only)
```

Protocol types come from `TetherProtocol`, which is generated in `../tether-server`. Both repos sit side by side in `~/Code`.

## Develop

1. Open `Sundown.xcodeproj` and run the **Sundown** scheme. The app carries no server: each host runs tether-server's npm package with its own `npx` (Node.js 18 or later), at the version the app pins.
2. To run a `../tether-server` working copy instead, set This Mac's Server Command in Settings ▸ Hosts to `<bun> run <path>/tether-server/src/cli.ts connect`.
3. Live Swift tests against the real `claude` (Haiku): `SUNDOWN_E2E=1 swift test --package-path SundownKit`.
4. Debug builds accept `SUNDOWN_OPEN_THREAD=<id>`, set in the scheme's environment variables, to open a chat on launch.

## Tests

`swift test --package-path SundownKit` runs the package tests without a live Claude session. The
`SundownAppUITests` target in the shared **Sundown** scheme launches the real app with
`SUNDOWN_UI_TEST_MODE=1`. That mode supplies an in-process JSON-RPC server and refuses to launch
the local daemon or SSH for any host without a fixture transport. It exercises Settings, host
management, chat streaming, and reconnection without inference calls. Run it locally with Xcode's
**Test** action. `SUNDOWN_E2E=1` is the separate, opt-in live suite and can incur cost.

The PR workflow runs both suites on the `xcode-27` GitHub runner and uploads the `.xcresult`
bundle. SwiftPM resolves the pinned `TetherProtocol` package from the public
`AFRUITPIE/tether-server` repository. No Claude credentials are supplied to CI.

## License

MIT, in [LICENSE](LICENSE).

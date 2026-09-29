# Tether (macOS app)

A native SwiftUI client for [tether-server](../tether-server): Claude Code on this Mac, or on any host you can reach over SSH, with sessions that keep running while the app is closed.

```
Tether.xcodeproj     macOS app target (signing, bundle)
Tether/              app entry point + assets
TetherKit/           Swift package
  TetherKit          transport (local shell / ssh), JSON-RPC client, host bootstrap, stores
  TetherUI           SwiftUI views (macOS 27 APIs, standard components, Liquid Glass on controls only)
```

Protocol types come from `TetherProtocol`, which is generated in `../tether-server`. Both repos sit side by side in `~/Code`.

## Install

```sh
brew install --cask afruitpie/tap/tether
```

Tether needs macOS 27, and on each host Node.js 18 or later and Claude Code.

## Develop

1. Open `Tether.xcodeproj` and run the **Tether** scheme. The app carries no server: each host runs tether-server's npm package with its own `npx` (Node.js 18 or later), at the version the app pins.
2. To run a `../tether-server` working copy instead, set This Mac's Server Command in Settings ▸ Hosts to `<bun> run <path>/tether-server/src/cli.ts connect`.
3. Live Swift tests against the real `claude` (Haiku): `TETHER_E2E=1 swift test --package-path TetherKit`.
4. Debug builds accept `TETHER_OPEN_THREAD=<id>`, set in the scheme's environment variables, to open a chat on launch.

## Tests

`swift test --package-path TetherKit` runs the package tests without a live Claude session. The
`TetherAppUITests` target in the shared **Tether** scheme launches the real app with
`TETHER_UI_TEST_MODE=1`. That mode supplies an in-process JSON-RPC server and refuses to launch
the local daemon or SSH for any host without a fixture transport. It exercises Settings, host
management, chat streaming, and reconnection without inference calls. Run it locally with Xcode's
**Test** action. `TETHER_E2E=1` is the separate, opt-in live suite and can incur cost.

Xcode Cloud runs both suites on each pull request (its workflow lives in App Store Connect;
`Tether.xcodeproj/xcshareddata/xcodecloud` ties the project to it). SwiftPM resolves the pinned `TetherProtocol` package from the public
`AFRUITPIE/tether-server` repository. No Claude credentials are supplied to CI.

## License

MIT, in [LICENSE](LICENSE).

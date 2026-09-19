# Tether (macOS app)

A native SwiftUI client for [tether-server](../tether-server): Claude Code on this Mac, or on any host you can reach over SSH, with sessions that keep running while the app is closed.

```
Tether.xcodeproj     macOS app target (signing, bundle, server-binary build phase)
Tether/              app entry point + assets
TetherKit/           Swift package
  TetherKit          transport (local shell / ssh), JSON-RPC client, host bootstrap, stores
  TetherUI           SwiftUI views (macOS 26 APIs, standard components, Liquid Glass on controls only)
```

Protocol types come from `TetherProtocol`, which is generated in `../tether-server`. Both repos sit side by side in `~/Code`.

## Develop

1. Build the server binaries: `cd ../tether-server && mise run compile`.
2. Open `Tether.xcodeproj` and run the **Tether** scheme. A build phase copies `../tether-server/dist/tether-*` into `Tether.app/Contents/Resources/servers/`.
3. Live Swift tests against the real `claude` (Haiku): `TETHER_E2E=1 swift test --package-path TetherKit`.
4. Debug builds accept `TETHER_OPEN_THREAD=<id>`, set in the scheme's environment variables, to open a chat on launch.

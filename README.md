# Tether (macOS app)

A native SwiftUI client for [tether-server](../tether-server): Claude Code on this Mac, or on any host you can reach over SSH, with sessions that keep running while the app is closed.

- `TetherKit/`: a Swift package.
  - `TetherKit`: transport (local shell / `ssh`), the JSON-RPC client, host bootstrap (installs the server into `~/.tether/bin`) and the observable stores.
  - `TetherUI`: SwiftUI views built on macOS 26 APIs with standard components. Liquid Glass is used only on the controls layer.
  - `TetherDevApp`: a development runner.
- Protocol types come from `TetherProtocol`, which is generated in tether-server.

## Develop

```
cd ../tether-server && mise run compile     # build server binaries (dist/)
cd ../tether-app && ./scripts/make-dev-app.sh && open TetherKit/.build/TetherDev.app
TETHER_E2E=1 swift test --package-path TetherKit   # live test against real claude (haiku)
```

## Xcode app target

Create a macOS App project named **Tether** (SwiftUI, Swift) in this folder, then:

1. **Package dependency:** File ▸ Add Package Dependencies ▸ Add Local… ▸ `TetherKit`, then link `TetherUI`.
2. **App file:** replace the generated `TetherApp.swift` with the body of `TetherKit/Sources/TetherDevApp/main.swift`, and drop the `setActivationPolicy` line.
3. **Signing & Capabilities:** remove **App Sandbox**. The app launches `ssh` and reads `~/.ssh`.
4. **Build phase:** add a Run Script phase that copies the server binaries into `Contents/Resources/servers/`:
   `mkdir -p "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/servers" && cp "$SRCROOT/../tether-server/dist/tether-"*-{darwin,linux}-* "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/servers/"`

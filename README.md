# juli-os iOS — the remote for your agent OS

The native iOS surface of the [juli-os](https://github.com/juli-os) ladder: a pocket remote for a self-hosted agent platform. Your Mac runs the engine; your phone runs this app.

## What you get

- **Chat intake** — conversational work orders: describe a task, confirm, and it becomes a tracked job (the phone speaks, the engine builds)
- **Voice control** — speech-to-text with local VAD (only streams while you're actually talking); bring your own Azure Speech key in Settings
- **Gate workbench** — human-approval queues with content-hash binding: approve or reject what the engine wants to send
- **Routing map & agents** — live multi-agent topology, session states, recent dispatch decisions
- **Terminals & artifacts** — read-only agent terminal snapshots, artifact previews (HTML/report/body roles)

## Requirements

- Xcode 16+, [xcodegen](https://github.com/yonaskolb/XcodeGen), CocoaPods
- A running juli-os engine (see `@juli-os/ledger` / `@juli-os/artifacts` / `@juli-os/routing` — or the full stack)

## Build

```bash
cd Makro
xcodegen generate
pod install
open Makro.xcworkspace
# pick the Makro scheme, a simulator, run — no signing needed for the simulator
```

The app stores your engine address and credentials in the Keychain; set the
server URL in Settings on first launch.

## Architecture notes

- SwiftUI app, no third-party app-level dependencies (only the Azure Speech
  Pod for voice)
- Talks to the engine over its HTTP/SSE/WebSocket API (`APIClient*`)
- The project file is generated from `project.yml` — regenerate after edits,
  never hand-edit `project.pbxproj`

## License

Apache-2.0

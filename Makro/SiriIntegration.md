# Makro iOS — Siri Voice-Call Invocation Integration Plan

> Status: **implemented** (`xcodebuild` BUILD SUCCEEDED, zero errors; on-device Siri verification left to the user). Prerequisite already done: VAD + submit-phrase commit (`0add94e`, live on origin/main).
> Scope: pure iOS client, **zero backend changes**.

## Goal

"Hey Siri, start a Makro call" → app opens on the Chat tab → presents `CallView` → the existing Azure STT/TTS + VAD stack takes over.

## Current state (verified)

- No Siri / App Intents integration at all (build logs: `No AppIntents.framework dependency found` / `No AppShortcuts found`).
- Root navigation: `MakroApp` (`@main`) → `TabView` with 3 tabs: Chat(0) / Sessions(1) / Kanban(2).
- `CallView` is presented by `ChatView` via `.fullScreenCover(isPresented: $showCall)` (`ChatView.swift:90-92`); the phone button is in the toolbar (`:74`). `CallView.onAppear { vm.startCall() }` (`CallView.swift:31`).
- A cross-component routing pattern already exists: `NotificationCenter` (`.makroOpenSession` → `MakroApp` sets `selectedTab = 1`, `MakroApp.swift:25-36`). **Mirror this pattern**.
- `Info.plist` already declares the background modes `remote-notification` and `audio` (sufficient, no change needed). No URL scheme.

## What to add

### 1. New file `StartCallIntent.swift` (`ios/Makro/Makro/`)

```swift
import AppIntents
import Foundation

struct StartCallIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Call"
    static var description = IntentDescription("Start a voice call with Makro.")
    static var openAppWhenRun: Bool { true }   // bring the app to the foreground (a call needs mic + TTS + UI)

    @MainActor
    func perform() async throws -> some IntentResult {
        CallRouter.shared.requestStart()        // set the shared flag (see below)
        return .result()
    }
}

struct MakroShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartCallIntent(),
            phrases: [
                "Start a \(.applicationName) call",
                "Start \(.applicationName) call",
                "\(.applicationName) call"
            ],
            shortTitle: "Start Call",
            systemImageName: "phone.fill"
        )
    }
}
```

`\(.applicationName)` resolves to the app display name "Makro". AppIntents is an iOS 16+ system framework — no Pod needed.

### 2. Shared routing (cold-start-race resistant) — a small new singleton in `MakroApp.swift` or its own file

On a cold launch `NotificationCenter` may post before `ChatView` is instantiated, losing the message. An `ObservableObject` singleton is more robust:

```swift
final class CallRouter: ObservableObject {
    static let shared = CallRouter()
    @Published var pendingStart = false
    func requestStart() { pendingStart = true }
}
```

`StartCallIntent.perform` calls `CallRouter.shared.requestStart()`.

### 3. `MakroApp.swift` — switch to the Chat tab

```swift
.onReceive(CallRouter.shared.$pendingStart) { req in
    if req { selectedTab = 0 }     // make sure the Chat tab is active (ChatView instantiated)
}
```

### 4. `ChatView.swift` — react and present CallView

Add inside the `NavigationStack`:
```swift
.onReceive(CallRouter.shared.$pendingStart) { req in
    guard req else { return }
    CallRouter.shared.pendingStart = false
    showCall = true                // triggers .fullScreenCover → CallView → vm.startCall()
}
```

### 5. `project.pbxproj` — add `StartCallIntent.swift` to the target

Follow how `VoiceActivityDetector.swift` was added (4 places): `PBXBuildFile` / `PBXFileReference` / `PBXGroup` / `PBXSourcesBuildPhase`, using two new 24-hex-digit UUIDs.

## Alternatives (optional, skipped for now)

- URL scheme `makro://call` + `CFBundleURLSchemes` in `Info.plist` + `onOpenURL`: a non-Siri "shortcut open" fallback entry. AppShortcut is the primary path; not adding it yet.

## Notes

- `openAppWhenRun = true` → foregrounds the app. Invoking Siri from the lock screen usually requires unlocking first (depends on the user's Siri lock-screen settings); once invoked, the call survives via the `.audio` background mode + lock-screen Now Playing controls.
- Siri auto-discovers the AppShortcut after installing a new build (iOS 16+ needs no explicit donation).
- Siri may mishear the word "Makro" → the user can change the phrase in Settings → Siri as a fallback.
- `perform` is marked `@MainActor` to avoid cross-actor warnings.

## Verification (on device)

1. `xcodebuild` passes (AppIntents compiles and registers without errors).
2. After installing, Settings → Siri & Search shows Makro's "Start Call" shortcut.
3. Say "Hey Siri, start a Makro call" → app opens → Chat tab → `CallView` full screen → the call starts (VAD listening, phase "listening… say 'please send' to finish").
4. Also visible and manually runnable in the Shortcuts app.

## Implementation order

1. `StartCallIntent.swift` (intent + provider).
2. The `CallRouter` singleton.
3. One `onReceive` each in `MakroApp` / `ChatView`.
4. Add the file in `project.pbxproj`.
5. Build + verify on device.

## Implementation record (2026-06-21)

Implemented; `xcodebuild -workspace Makro.xcworkspace -scheme Makro -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` → **BUILD SUCCEEDED** (zero errors). Differences from the plan above:

- **`AppShortcut` takes `shortTitle:`, not `shortCutTitle:`** (renamed in the iOS 26 SDK; the line in the code block above is already corrected — writing `shortCutTitle` fails to compile with "Incorrect argument label").
- **New files enter the target via `xcodegen generate` + `pod install`, not hand-editing pbxproj**. `xcodegen generate` deletes the shared scheme — restore it from backup (see the build-was-grey trap in CLAUDE.md). **`pod install` must run after `xcodegen generate`**, otherwise the `MicrosoftCognitiveServicesSpeech` module cannot resolve (the regenerated project loses the build settings the Pods injection added).
- **`ChatView` additionally checks the current value of `CallRouter.shared.pendingStart` in `.task`**: `.onReceive` only reacts to changes after subscribing, so a cold start (Siri set the flag before `ChatView` was instantiated) would be missed.

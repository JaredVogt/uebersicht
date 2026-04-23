# Übersicht Modernization Plan

Branch: `modern`. Target: macOS 14+ (Sonoma, Sequoia, 26). Swift 6, structured concurrency, SwiftPM, no CocoaPods, no Node.js sidecar, no private WebKit headers, no CoffeeScript.

This document is the working brief. When resuming in a new context, read this first, then `git status` and `git log modern --oneline` to see current progress.

---

## One-line thesis

Full Swift 6 rewrite using structured concurrency, kill the Node.js sidecar, replace private WebKit headers with public APIs, drop CocoaPods for SwiftPM, and collapse the three-process architecture (app ↔ Node server ↔ WebViews) into a single in-process actor graph.

---

## What we're demolishing

| Kill | Replace with |
|---|---|
| Node.js + CoffeeScript `server/` (~50MB runtime, separate process, WS on port 41416) | In-process Swift server: `Network.framework` NWListener + FSEvents + esbuild binary (~10MB, single static) |
| SocketRocket pod | `URLSessionWebSocketTask` (client) + `NWProtocolWebSocket` (server) |
| CocoaPods entirely | SwiftPM |
| Private WebKit headers (`WKView.h`, `WKPage.h`, `WKInspector.h`, `WKBase.h`, `WKWebViewInternal.h`) | `WKWebView.isInspectable`, `underPageBackgroundColor`, public config |
| KVC hack `setValue:@YES forKey:@"drawsTransparentBackground"` | Public transparent background (macOS 14+) |
| `UBListener`/`UBDispatcher` string-key pub/sub with `NSMutableDictionary` state | Typed `AsyncStream`s + `actor WidgetStore` |
| All `performSelector:withObject:afterDelay:` calls | `Task { try? await Task.sleep(...); ... }` with cancellation |
| `dispatch_once` singletons | Swift `static let` + actors |
| `stringWithFormat:` JSON construction in `UBLocation.m` | `JSONEncoder` + `Codable` |
| IOKit `IODisplayConnect` fallback (~90 lines in `UBScreensController.m`) | Delete — `NSScreen.localizedName` covers it |
| `NSBorderlessWindowMask` and other deprecated constants | Modern `NSWindow.StyleMask` |
| `.xib`-based preferences | SwiftUI `Settings` scene |
| NIB-based menu bar | SwiftUI `MenuBarExtra` |
| CoreLocation delegate dance | `CLLocationUpdate.liveUpdates()` (macOS 14+) |
| `addressDictionary` (deprecated 10.13) | `CNPostalAddress` |
| CoffeeScript widget support | Drop. JSX only. |

---

## Target architecture

```
Uebersicht/
├── App/
│   ├── UebersichtApp.swift         // @main, SwiftUI App, MenuBarExtra
│   └── MenuBarView.swift
├── Host/
│   ├── WidgetWindow.swift
│   ├── WidgetWindowController.swift
│   ├── WidgetWebView.swift
│   └── JSBridge.swift
├── Server/                          // replaces entire Node sidecar
│   ├── WidgetServer.swift           // NWListener HTTP + WebSocket
│   ├── WidgetWatcher.swift          // FSEvents → AsyncStream<WidgetChange>
│   ├── JSXTransformer.swift         // wraps bundled esbuild
│   └── CommandRunner.swift          // widget `command:` execution
├── State/
│   ├── WidgetStore.swift            // actor
│   ├── ScreenStore.swift            // actor
│   └── Settings.swift               // @Observable, UserDefaults-backed
├── Platform/
│   ├── Geolocation.swift            // CLLocationUpdate.liveUpdates
│   └── Scripting.swift              // NSScriptCommand bridge (.sdef stays)
└── UI/
    └── PreferencesScene.swift
```

Line-count target: ~2,800 Obj-C + ~5k Node → ~2,000 Swift total.

---

## Phase plan (5 PRs, each independently shippable)

### PR 1 — Toolchain prep (no behavior change)
- Raise deployment target to macOS 14.
- Migrate Sparkle to SwiftPM, drop SocketRocket dep.
- Remove `Podfile`, `Pods/`, `.xcworkspace`; everything in `.xcodeproj`.
- Add Swift compilation unit + bridging header so Obj-C and Swift coexist.
- Swift Testing setup.
- **Gate:** app builds and runs identical to today.

### PR 2 — WKWebView modernization (kill private headers)
- Delete `WKView.h`, `WKPage.h`, `WKInspector.h`, `WKBase.h`, `WKWebViewInternal.h`.
- `WidgetWebView.swift` + `JSBridge.swift` with public transparency + `isInspectable`.
- `Geolocation.swift` with `Codable`.
- **Gate:** widgets render transparently, devtools work, geolocation widgets function.

### PR 3 — Concurrency + state migration
- Actor versions of `UBWidgetsStore`, `UBWidgetsController`, `UBScreensController`, `UBListener`, `UBDispatcher`.
- `URLSessionWebSocketTask` replaces SocketRocket client.
- Delete `performSelector:afterDelay:` everywhere.
- Delete IOKit `IODisplayConnect` fallback.
- **Gate:** widgets receive events, screen changes trigger rerender, websocket reconnects after forced kill.

### PR 4 — Kill the Node sidecar (the big one)
- `WidgetServer.swift` using `NWListener` for HTTP static + WebSocket.
- `WidgetWatcher.swift` via FSEvents.
- `JSXTransformer.swift` shells out to bundled esbuild (Resources/bin/esbuild, universal, ~12MB).
- `CommandRunner.swift` via `Process` with `DispatchIO` streaming.
- Drop CoffeeScript support.
- Delete `server/`, `node_modules`, all CoffeeScript toolchain.
- **Gate:** community JSX widgets work unchanged. Test corpus of 10–20 popular widgets.

### PR 5 — SwiftUI menu bar + prefs
- `MainMenu.xib` → `MenuBarExtra`.
- `UBPreferencesController.xib` → SwiftUI `Settings`.
- Modernize entry point with `@main` SwiftUI App.
- Keyboard shortcuts + accessibility.
- **Gate:** feature parity with current menu.

---

## Test strategy

Use Swift Testing (Xcode 16+, `import Testing`). One test target, unit tests per module.

- **State/WidgetStoreTests.swift** — actor semantics, add/remove/settings-patch, concurrent writes, notification stream.
- **State/ScreenStoreTests.swift** — deduped screen-name generation, change detection.
- **Server/WidgetWatcherTests.swift** — FSEvents emits on create/modify/delete.
- **Server/JSXTransformerTests.swift** — sample JSX → valid ESM output, error surfaces.
- **Server/CommandRunnerTests.swift** — stdout streaming, timeout, cancellation.
- **Server/WidgetServerTests.swift** — HTTP serves static, WS echoes, reconnect.
- **Host/JSBridgeTests.swift** — message roundtrip, decode failures.
- **Platform/GeolocationTests.swift** — JSON encode shape matches old format exactly (compat).
- **Integration/WidgetLifecycleTests.swift** — load a sample JSX widget end-to-end, render, change file, reload.

---

## Outcomes user will feel

- Launch: ~1.5s → ~300ms.
- Idle memory: ~80MB → ~25MB.
- Bundle: ~70MB → ~25MB.
- "Server died, widgets frozen" state goes away (no separate server).
- No more per-macOS patches like `Fix Screen Handling on Sonoma`.

---

## Risks

1. **Esbuild dependency.** Shipping bundled static binary is the pragmatic call. MIT, universal, ~12MB.
2. **CoffeeScript drop.** Breaks old widgets. User confirmed — dump it.
3. **AppleScript / `.sdef` bridge.** Swift→ScriptingBridge is uglier. `UBWidgetForScripting.m`, `UBRefreshCommand.m`, `UBReloadCommand.m` may stay as thin Obj-C wrappers calling Swift (~100 lines of glue). Acceptable.
4. **PR 4 is genuinely big** — do not combine with PR 5.

---

## Session handoff protocol

If a session ends mid-work (≥70% context), append a `## Session YYYY-MM-DD handoff` section below with:
- Which PR is in progress
- What's done
- What's partially done (with file paths + line numbers)
- What's the next concrete step
- Any gotchas discovered

On resume: read this doc, then `git status` + `git log modern --oneline`, then continue from the handoff note.

---

## Current progress

Branch `modern` created off master `607ab55`.

### Session 2026-04-23

Work begins on PR 1.

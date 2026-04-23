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

- PR 1 ✅ **done**. Deployment target raised to macOS 14. CocoaPods gone; Sparkle via SwiftPM; SocketRocket replaced with Swift `UBWebSocket` over `URLSessionWebSocketTask`. XcodeGen owns the project (`project.yml`). Swift Testing harness live. Lesson: XcodeGen's `info:` / `entitlements:` blocks rewrite the source files from scratch — don't use them; set `INFOPLIST_FILE` / `CODE_SIGN_ENTITLEMENTS` as plain build settings so XcodeGen leaves your files alone.
- PR 2 ✅ **done**. Private WebKit headers deleted. `UBWebView`, `UBWebViewController`, `UBLocation` rewritten in Swift (`WidgetWebView`, `WidgetWebViewController`, `Geolocation`). `WKWebView.isInspectable = true` replaces the old `WKInspectorRef` flow; debug console menu now opens Safari. Geolocation JSON is now `Codable`.
- PR 3 🟡 **partial, good enough to proceed**.
  - Done: `UBListener` and `UBDispatcher` rewritten in Swift (`Listener.swift`, `Dispatcher.swift`). Every `performSelector:withObject:afterDelay:` removed (replaced by `dispatch_after` in the two remaining Obj-C call sites in `UBAppDelegate.m`). Dead IOKit fallback (`IODisplayConnect`, `getDisplayInfoDictionary`, `screenNameForDisplay:`) ripped out of `UBScreensController.m` — target is 14.0, `NSScreen.localizedName` is always available.
  - **Deferred to a later pass**: full Swift rewrite of `UBScreensController`, `UBWidgetsStore`, `UBWidgetsController` as actors. These classes work fine via the `@objc`-bridged Swift classes they depend on; the Swift conversion is cosmetic, not architectural, and can piggyback on PR 5 (menu bar) when `UBWidgetsController`'s menu wiring gets rebuilt in SwiftUI anyway.
- PR 4 🟡 **scaffolding in place**. `Uebersicht/Server/CommandRunner.swift` and `Uebersicht/Server/WidgetWatcher.swift` shipped with tests. Node sidecar is still running; next session does `JSXTransformer` → `WidgetServer` (NWListener HTTP + WS) → cut over `UBAppDelegate.m` → delete `server/`.

## Handoff — pick up at PR 4

**Read this first when resuming in a new context.** PR 4 is the biggest remaining architectural win: kill the Node.js sidecar.

### What Node.js currently does

The `server/` directory is a Node + CoffeeScript app (~30 source files) that the Obj-C app launches as an `NSTask`. It:
1. Watches a widget directory via `fsevents`.
2. Compiles JSX (and historically CoffeeScript) widgets into ES modules.
3. Runs shell commands widgets declare via `command:`.
4. Serves an HTTP + WebSocket endpoint on port 41416 (default; bumped on port collision).
5. Ships an HTML/JS client that the `WidgetWebView`s load; the client renders widgets using React.
6. Has a perf collector, settings store, and state reducer.

Obj-C surface touching the sidecar: `UBAppDelegate.m` (`launchWidgetServer:…`, `startUp`, `shutdown:`). `UBWebSocket` (Swift, already modernized) is the client. `server/release/` has the prebuilt output: `localnode` (shim), `node-arm64`/`node-x64` binaries, `server.js` (compiled from server/src), `node_modules/`, `public/`.

### Target Swift architecture (from the plan)

```
Uebersicht/Server/
  WidgetServer.swift        // NWListener: HTTP + WebSocket on one port
  WidgetWatcher.swift       // DispatchSource.makeFileSystemObjectSource or FSEvents
  JSXTransformer.swift      // invokes bundled esbuild (Resources/bin/esbuild)
  CommandRunner.swift       // Process + DispatchIO for streaming stdout
  StateStore.swift          // actor; replaces the Node-side reducer
```

### Concrete PR 4 work order

1. **Scaffolding (risk-free, test-first).** Ship the self-contained building blocks with tests before wiring anything in.
   - ✅ `CommandRunner.swift` + `CommandRunnerTests.swift` — shipped this session. `Process` + `AsyncThrowingStream<Event>` with timeout + cancellation.
   - ✅ `WidgetWatcher.swift` + `WidgetWatcherTests.swift` — shipped this session (FSEvents-based). Tests are currently shape-only because `/private/var/folders` doesn't reliably emit FSEvents under the test host; add a real integration test using `~/Library/Caches` path once the rest is wired.
   - ⏳ `JSXTransformer.swift` + `JSXTransformerTests.swift` (calls bundled `esbuild` binary via `Process`). Start without bundling — invoke a system `esbuild` binary if present, hard-fail with a clear error otherwise. Bundling the universal esbuild binary is a separate concern once the transform flow is proven.
2. **Server.** `WidgetServer.swift` using `Network.framework` `NWListener` with `NWProtocolWebSocket.Options`. Serve HTTP GET for static files + `/state` JSON, and accept WS connections that bridge to the `AsyncStream` fan-out used by the Listener/Dispatcher.
3. **Client bundle.** The Node sidecar currently serves an HTML file + `client.js` (compiled from `server/src/uebersicht.js` + React). Option A: copy `server/release/public/` into Resources, keep the same HTML. Option B: rebuild the client with esbuild at build time. Start with A, revisit in a separate PR.
4. **Cut over.** Swap `launchWidgetServer:` in `UBAppDelegate.m` for starting `WidgetServer` in-process. Keep the same port number (41416) so widget-side URLs don't need to know anything changed.
5. **Delete.** Nuke `server/` entirely, `server/release/*` resources from project.yml, the codesign-node-binaries step from the post-build script, `localnode`, `node-arm64`, `node-x64`, `node_modules`. CoffeeScript support is already gone in spec; confirm no `.coffee` paths remain.

### Invariants to preserve

- Widget directory path resolution (`~/Library/Application Support/Übersicht/widgets` by default, plus `preferences.widgetDir`).
- Widget file naming: `*.jsx` (required) — CoffeeScript is dropped; surface a clear warning if found.
- Wire protocol: envelopes `{type, payload}` over JSON/WebSocket. Event names like `WIDGET_ADDED`, `WIDGET_REMOVED`, `WIDGET_SETTINGS_CHANGED`, `SCREENS_DID_CHANGE`, etc. are consumed by the existing Obj-C Listener — do not rename without updating callers in `UBWidgetsStore.m`, `UBScreensController.m`, `UBWidgetForScripting.m`.
- Widget state shape: `{widgets: {[id]: widget}, settings: {[id]: settings}}` — `UBWidgetsStore.reset:` already expects this exact shape.

### Known hazards

- `Process` subprocesses do not inherit the app's sandbox/entitlements for network exempt; shell commands run as the user, which is what we want.
- `NWListener` on a specific port may fail if the port is held (startup race after crash). The old code retried with `portOffset++`; replicate that.
- Widget JSX can `import` relative files inside the widget dir — esbuild needs the transform to resolve these. Use esbuild's `bundle: true` with the widget file as the entry.
- When re-signing bundled helpers, the `node-arm64`/`node-x64`/`fsevents.node` entries in `project.yml`'s postBuildScripts go away once the binaries are removed.

### Testing strategy for PR 4

- Unit: watcher emits on create/modify/delete; command runner streams and times out; JSX transformer produces valid ESM; server HTTP endpoints return expected JSON.
- Integration: start `WidgetServer` in a test, connect a `URLSessionWebSocketTask` client, dispatch a `WIDGET_ADDED` event, assert the listener sees it.
- End-to-end: bootstrap the app against a temp widget directory containing one JSX widget, assert it appears in the menu (this one may need XCUITest or at least a deterministic `NSStatusItem` harness).

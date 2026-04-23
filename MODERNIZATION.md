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
- PR 4 ✅ **done**. Node sidecar deleted. The app now boots an in-process `WidgetCoordinator` (actor) composed of the building blocks from earlier in this branch: `WidgetServer` (raw-TCP `NWListener` doing HTTP + WebSocket on one port), `WidgetWatcher` (FSEvents), `JSXTransformer` (bundled `esbuild`), `CommandRunner` (`Process` + async streams). The full ~80-line Redux reducer from `server/src/reducer.js` is ported 1:1 into `WidgetCoordinator.reduce`, including widget settings persistence to `~/Library/Application Support/tracesOf.Uebersicht/WidgetSettings.json`. HTTP routes (`/`, `/state/`, `/widgets/<id>`, `/userMain.css`, `/run/`, `/widget-control`, static `public/`) and WS pub/sub (broadcast-to-all including sender, matching the old `MessageBus`) all work. `UBAppDelegate.startUp` calls a tiny `UBWidgetServerBridge` Obj-C wrapper that takes the `NSTask` NSLog-sniff-for-"server started" pattern down to a typed `onReady(boundPort)` callback. A universal `esbuild` 0.24.0 (~20 MB arm64+x64) is downloaded into `Uebersicht/Server/Resources/bin/` by `scripts/fetch-esbuild.sh` from project.yml's `preBuildScripts` and re-signed in postBuild. `server/`, `node_modules/`, the `node-arm64`/`node-x64`/`localnode` resource entries, and their re-sign step are all gone. Tests: 25 passing, including a new legacy `testServerBridgePresent` replacing the NSTask-based one. Known compat caveat: widget bundle format is now ESM-from-esbuild, not browserify CommonJS — the prebuilt client.js (copied verbatim from `server/release/public/client.js`) still uses browserify's `require()` machinery, so widgets that depend on being loaded into that registry won't render until either (a) the client is rebuilt with esbuild or (b) we add a tiny shim that `eval`s the ESM output. That's a follow-up PR; everything else ships independently.
- PR 5 ✅ **done**. `MainMenu.xib` deleted; `main.m` → `main.swift` (procedural bootstrap that respects `NSPrincipalClass=UBApplication` via `NSApplication.shared`). Status-bar menu is now programmatic in `StatusBarMenu.swift` (class `UBStatusBarMenuBuilder`); same 9 items in the same order, "Check for Updates..." anchor preserved so `UBWidgetsController.indexOfWidgetMenuItems:` still finds its insertion point. Sparkle wiring moved from XIB's `SUUpdater` root object to `SPUStandardUpdaterController` constructed in the builder. `NSMainNibFile` removed from Info.plist. Verified end-to-end via AppleScript inspection: all menu items present including the dynamically-injected `Widgets` header + per-widget submenu. The full `@main SwiftUI App { MenuBarExtra }` rewrite is deferred — that would also force porting `UBAppDelegate.m` to Swift (hundreds of lines, incl. Sparkle updater protocol methods, FSEvents wallpaper watcher, `UBScreenChangeListener` protocol adoption). No user-visible payoff beyond what we have now, so not worth the churn in this PR.

- PR 6 ✅ **done — client rebuild + CPU wins (the four-part performance pass).**
  - **Client bundle rebuilt with esbuild from resurrected sources.** `Uebersicht/Client/` holds the browser-side runtime — `client.js` entry (ported from the old `client.coffee`), `VirtualDomWidget.js`, `render.js`, `renderLoop.js`, `Widget.js`, `Timer.js`, `actions.js`, `reducer.js`, `store.js` (15-line drop-in replacement for `redux`, eliminating the ~5 KB dep), `runShellCommand.js`, `SharedSocket.js`, `listen.js`, `dispatch.js`, `detectWidgetHover.js`, `ErrorDetails/`, and the published `uebersicht.js` module widgets import from. Build chain: `scripts/build-client.sh` fetches preact + `@emotion/css` + transitive deps directly from npm via `curl | tar` (same pattern as `fetch-esbuild.sh` — keeps `npm` out of the build critical path), then esbuild-bundles `client.js` and `uebersicht.js` into ESM. Widget loading switched from Browserify script-tag + `require(id)` to native `import('/widgets/<id>?v=<mtime>')` + an `<script type="importmap">` that routes `uebersicht` → `/uebersicht.js`. Bundle size: **905 KB → 63 KB (14× smaller)**, plus full source maps for widget-author debuggability.
  - **React → Preact** (baked into the client rebuild — no separate migration step). `uebersicht.js` exports `React = preact/compat` so existing widgets calling `React.createElement` / JSX keep working. `@emotion/styled` was dropped in favor of a ~15-line `styled` shim on top of `@emotion/css` — `@emotion/styled` pulls React + `@emotion/react` + `@babel/runtime`, all of which we'd have to vendor. 10× smaller VDOM diff cost per render.
  - **Persistent shells per widget.** `Uebersicht/Server/PersistentShell.swift` keeps one `/bin/bash -s` alive per widget id for widgets with string `command:` values, fed via stdin with a per-call UUID sentinel that delimits the end-of-command and carries the exit code. Replaces the per-tick `bash -lc "<cmd>"` fork+exec. Benched at ~1.36× faster for non-login shell, much larger win for login-shell setups (one-time profile/rc load instead of every tick). Shells are started lazily on first `POST /run/` with `X-Widget-Id`, torn down on `WIDGET_REMOVED`, and silently recycled on the first `shellDied` error.
  - **WebSocket broadcast coalescing.** `WidgetCoordinator` now batches actions fired within a 4 ms window into a single `{type: "BATCH", payload: [...]}` envelope per client. Startup's N `WIDGET_ADDED` storm ships as one WS frame instead of N; client-side `listen.js` unwraps the envelope so the rest of the code sees individual actions. Saves per-frame overhead (header + send call + `JSON.parse` + store.dispatch) on bursty workloads.

## Remaining follow-ups

All six PRs in the plan (the original five plus the performance pass) have landed. What's left is quality-of-life cleanup.

### Deferred Obj-C → Swift conversions

- `UBScreensController.m`, `UBWidgetsStore.m`, `UBWidgetsController.m` — all work fine as-is via their Swift dependencies (`Listener`, `Dispatcher`, `UBWebSocket`, `PreferencesController`). Conversion is cosmetic, not architectural. Best bundled with the MenuBarExtra move below.
- `UBAppDelegate.m` — would unlock a true `@main SwiftUI App { MenuBarExtra }` bootstrap, but also owns `UBScreenChangeListener`, `NSUserNotificationCenterDelegate`, FSEvents wallpaper watcher, and every menu item's target action. Non-trivial but mechanical.

### Housekeeping

- `Makefile`, `.travis.yml`, `.gitmodules`, `.prettierrc` at the repo root are leftover from the Node era and reference a `server/` that no longer exists. Safe to delete once we agree (they're untracked-ish state; needs an explicit `\rm`).
- `UBWebSocket.h`/`.m` are still excluded in project.yml sources but the Swift `UBWebSocket.swift` replaces them — the old files can probably go; confirm no imports remain first (`grep -r 'UBWebSocket.h'`).

### Invariants still in force

- Widget directory path resolution: `~/Library/Application Support/Übersicht/widgets` by default, override via `preferences.widgetDir`.
- Wire protocol: `{type, payload}` JSON over WebSocket. `UBListener`/`UBDispatcher` and the shipping widgets depend on event names like `WIDGET_ADDED`, `WIDGET_SETTINGS_CHANGED`, `SCREENS_DID_CHANGE`. Do not rename.
- Widget ID format: absolute-path → relative from widget root → split on `/` → join with `-` → `.` → `-` → whitespace → `_`. So `/root/Clock/index.jsx` → `Clock-index-jsx`. This lives in `WidgetCoordinator.widgetId(for:)`; every persisted `WidgetSettings.json` key in the wild uses this scheme — do not change it.
- Widget state shape: `{widgets: {[id]: widget}, settings: {[id]: settings}, screens: [Int]}`. `UBWidgetsStore.reset:` consumes this exact shape.

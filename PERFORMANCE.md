# Performance pass — plan

Post-PR6 audit. Starts from a working baseline: in-process Swift server, 63 KB Preact client, persistent shells, WS broadcast coalescing, `CADisplayLink` keeping rAF alive under occlusion. That modernization is done; this doc is the next pass.

**On resume**: read this first, then `git status` and `git log modern --oneline`. Work the priority list top-down; each item is self-contained and can ship as its own commit.

---

## Audit origin

Codex produced a review; I cross-checked the claims and amended where it was overstated or where it missed things. The synthesis below is what survived review. Full list of findings follows the priority list — keep both because (a) the priority is my call to execute and (b) the findings list documents why each item made or didn't make the cut.

---

## Priority list (execute in order)

### 1. Remove redundant `/state/` fetch in `loadWidget`  **[client.js:84-98]**

Self-inflicted cost I shipped. Every dynamic import of a widget does a full `fetch('/state/')` just to pull `mtime`, which is already on the widget object the caller is iterating.

With N widgets × 2 layers × screens, that's `2Nscreens` redundant state fetches per page load.

**Fix**: pass the widget object (or just mtime) into `loadWidget`. Signature becomes `loadWidget(id, mtime)`; callers already hold it:

- Line 40 context: `Object.keys(initialState.widgets).forEach((id) => { loadWidget(id, initialState.widgets[id].mtime)... })`
- Line 62 context: WIDGET_ADDED handler has `action.payload.mtime` directly.

Drop the fetch, keep the `widgetImports` map keyed by `${id}@${mtime}`.

**Risk**: none. Pure 1-line refactor.

---

### 2. Lazy layer windows  **[UBWindowGroup.m:18-35]**

Biggest real-world CPU/memory win. `UBWindowGroup.initWithInteractionEnabled:` unconditionally creates a `background` window and, when interaction is on, also a `foreground` window. Each is a full `WKWebView` with its own web-content process context, even if zero widgets will ever be visible on that layer.

**Fix**: defer window creation until a widget settings state would place a widget on that layer:

- Background layer needed ↔ any widget with `inBackground: true` AND (visible on this screen).
- Foreground layer needed ↔ any widget with `inBackground: !== true` AND (visible on this screen) AND `interactionEnabled` (otherwise it collapses to the agnostic-layer case).

Implementation shape:
- `UBWindowGroup` keeps pointers nil until needed.
- A new `ensureLayer:UBWindowType` method allocates + loads on first demand.
- On `WIDGET_SETTINGS_CHANGED` / `WIDGET_ADDED`, `UBWindowsController` (`UBWindowsController.m`) recomputes per-screen layer demand and either `ensureLayer:` or closes an idle one.

**Verification**: Activity Monitor → `WidgetWebView` process count should drop from `2 × screens` to `(layers-in-use) × screens`.

**Risk**: moderate. Layer transitions (widget moves from foreground to background) must hot-create the target layer or the widget disappears. Add a focused test that flips `inBackground` and asserts the widget appears on the other layer without a reload.

---

### 3. Startup jitter in `Timer.js`  **[Timer.js:22-28]**

On mount, `start()` calls `loop()` synchronously, so N widgets mounted in the same render pass all fire their first `command:` at t=0. This is a subprocess-spawn burst — ~10 widgets × 1 bash each = a thundering herd for the first tick.

**Fix**: add randomized startup delay on `start()`:

```js
api.start = function start() {
  if (!started) {
    started = true;
    // Spread initial ticks across a ~500 ms window so N widgets don't all
    // spawn subprocesses at t=0. After the first tick, widgets resume
    // their own refreshFrequency cadence, which already desyncs naturally.
    timer = setTimeout(loop, Math.random() * 500);
  }
  return api;
};
```

3 lines. No behavior change except first-tick timing.

**Risk**: ~zero. Existing widgets tolerate any delay.

---

### 4. Gate debug hooks on `#if DEBUG`  **[WidgetWebView.swift, WidgetWebViewController.swift]**

Release builds currently ship with:
- `isInspectable = true` (`WidgetWebView.swift:26`) — WebKit keeps debug attach hooks live.
- `developerExtrasEnabled = true` (`WidgetWebViewController.swift:89`) — same.
- `ubConsole` message handler forwarding every `console.log` to NSLog (`WidgetWebViewController.swift:114-141`) — string allocation + IPC per log call, even if nothing reads NSLog.

**Fix**: wrap each in `#if DEBUG`. The console bridge should also skip installation entirely in release (don't inject the user script).

**Risk**: zero. Debug users lose nothing; release users lose a few percent of idle overhead and stop shipping a pre-wired debugger attach surface.

---

### 5. Fix `detectWidgetHover`  **[detectWidgetHover.js:1-27]**

Currently polls mousemove at 30 Hz per page via a one-shot listener + `setTimeout(32ms)` re-registration loop. Runs in every page (2 layers × N screens). Also has up to 32 ms of lag detecting hover changes.

**Fix**: event-driven `pointerover`/`pointerout` on the container. Zero polling, zero lag, drops the whole recursive setTimeout chain.

```js
export default function detectWidgetHover(containerEl) {
  let insideWidget = false;

  window.addEventListener('pointerover', (e) => {
    if (insideWidget || e.target === containerEl) return;
    insideWidget = true;
    window.webkit?.messageHandlers?.uebersicht?.postMessage('widgetEnter');
  }, { passive: true });

  window.addEventListener('pointerout', (e) => {
    if (!insideWidget) return;
    if (e.relatedTarget === null || e.relatedTarget === containerEl) {
      insideWidget = false;
      window.webkit?.messageHandlers?.uebersicht?.postMessage('widgetLeave');
    }
  }, { passive: true });
}
```

**Risk**: low. Edge case to verify: widgets with nested DOM (the ants widget has SVG children) — confirm `pointerover` bubbles correctly from SVG nodes to window. If not, attach to `document.documentElement` instead.

---

### 6. Debounce `persistSettings()`  **[WidgetCoordinator.swift:~405-420]**

Currently called synchronously inside the reducer path for every `WIDGET_SETTINGS_CHANGED` / `WIDGET_SET_TO_*` / `SCREEN_*_FOR_WIDGET` action. Toggling three widgets via the menu = three disk writes. JSON-serialize + atomic write each time.

**Fix**: debounce. Replace the synchronous `persistSettings()` call in `updateSettings` + the other write sites with:

```swift
private var persistTask: Task<Void, Never>?
private static let persistDebounce: Duration = .milliseconds(500)

private func schedulePersist() {
    persistTask?.cancel()
    persistTask = Task { [weak self] in
        try? await Task.sleep(for: Self.persistDebounce)
        guard !Task.isCancelled else { return }
        await self?.writeSettingsToDisk()
    }
}
```

Also: flush on `stop()` so we don't lose the last change when the app quits. `applicationWillTerminate:` already calls into the shutdown path — add a synchronous flush there.

**Risk**: low. Only risk is losing the last ~500 ms of changes on a hard crash, which matches what most apps do for settings persistence anyway.

---

### 7. PersistentShell → async I/O  **[PersistentShell.swift:97-115]**

Current `readUntil(marker:)` polls `stdoutHandle.availableData` with `Task.sleep(8ms)` between checks. Works, but wastes wall-clock time and ties up the actor while polling.

**Fix**: install a `readabilityHandler` on the `FileHandle` that pushes chunks into an `AsyncStream<Data>` continuation. `readUntil` becomes a normal async loop over the stream that exits when the marker appears.

Sketch:
```swift
private let stdoutStream: AsyncStream<Data>
private let stdoutContinuation: AsyncStream<Data>.Continuation

init(...) throws {
    var cont: AsyncStream<Data>.Continuation!
    self.stdoutStream = AsyncStream { c in cont = c }
    self.stdoutContinuation = cont
    // ...
    stdoutHandle.readabilityHandler = { [cont] h in
        let data = h.availableData
        if !data.isEmpty { cont.yield(data) }
    }
}

private func readUntil(marker: String) async throws -> Result {
    for await chunk in stdoutStream {
        readBuffer.append(chunk)
        if let result = splitOnMarker(marker: marker) { return result }
        if !process.isRunning { throw Failure.shellDied }
    }
    throw Failure.shellDied
}
```

**Risk**: medium. AsyncStream/continuation plumbing across actor boundaries requires care around Sendable. Test against the existing "shell dies mid-command" path.

---

## Explicitly not doing

### Move all command scheduling to the host

Codex suggested centralizing the command loop in the Swift coordinator. Rejected because:

1. Widgets with function-style `command:` (ants.jsx, Perf.jsx) execute JS in the page. Can't move to the host.
2. For string-command widgets, the host already runs the subprocess. The win from also owning the *timer* is ~nothing — it's just moving setTimeout from JS to Swift.
3. Worthwhile derivative: dedupe identical string commands across widgets (share one subprocess per unique command string, fan out results). Keep this in mind if a real workload shows a hotspot, but don't build it speculatively.

### Native AppKit/SwiftUI widgets

Out of scope. Real direction if we ever want the CPU floor below what WebKit costs, but it's a new product, not an optimization pass.

---

## Appendix: findings that fed the priority list

### Codex claims I verified and accepted
- Dual-layer creation per screen regardless of content (`UBWindowGroup.m:18-33`) → item 2.
- Redundant `/state/` fetch (`client.js:85`) → item 1.
- No startup jitter (`Timer.js:22-28`) → item 3.
- PersistentShell polling (`PersistentShell.swift:97`) → item 7.
- Console bridge + `isInspectable` always on → item 4.

### Codex claims I pushed back on
- **"Every page eagerly imports every widget, multiplies bundle eval for widgets that never mount"** — partially wrong. Module top-level evaluation does run, but the command loop only starts when `renderWidget()` mounts a visible widget (`render.js:24-34`). Invisible widgets don't spawn Timers. Real cost is module parse + that `/state/` fetch (item 1). Not a thundering herd of subprocesses.
- **"Move command scheduling into the host"** — see "Explicitly not doing" above.
- **Geolocation power waste** — only an issue if any widget actually uses the `geolocation` bridge. None of our shipping widgets do. Keep an eye on it if a user installs a weather/location widget.

### Codex missed, I added
- **`detectWidgetHover` 30 Hz polling** → item 5.
- **`persistSettings()` writes on every reducer tick** → item 6.
- **`seedExistingWidgets()` does synchronous `FileManager.enumerator`** on the actor. Deep widget dir → startup latency stalls the first action batch. Not prioritized because widget dirs are usually shallow, but worth fixing if a user reports slow first paint. Fix: move the enumerate into a `Task.detached` and dispatch `WIDGET_ADDED`s back in.
- **esbuild spawns a fresh subprocess per widget change.** `esbuild --service` daemon would drop hot-reload transform from ~100 ms to ~5 ms. Purely an editing-UX win, not runtime. Defer.
- **BATCH coalesce window is 4 ms** (`WidgetCoordinator.swift` `enqueueBroadcast`). Aggressive. 16 ms (one animation frame) batches more with no perceived latency. 2-line tweak.
- **WKWebView process pool sharing** — unverified. All widgets load from `127.0.0.1:41416` (one origin) and use a single `sharedConfig`, so they *should* share a web-content process. Check Activity Monitor when item 2 lands; if process count per screen is still high despite lazy layers, investigate `WKProcessPool` explicit configuration.

### Already shipped in the same context as this audit
- `CADisplayLink` pinning rAF to display refresh rate under occlusion (`WidgetWebViewController.swift:48-75`). Prevents macOS from throttling animated widgets when the desktop is covered.
- `window.__ubFPS()` probe + Perf widget row. Ground truth for "is the display link actually helping" instead of guessing.

---

## How to execute

Each item is independently shippable. Order matters because items 1-4 are quick wins that clear the decks; 5-7 are next. Suggested commit cadence: one per item, titled `perf: <item>`. Don't bundle — each one's diff is small and the blame history is more useful separated.

Verify with `xcodebuild test` after each item. The 25 existing tests don't cover most of these paths, so the test suite is a smoke check only; real verification is a manual app run + Activity Monitor glance + the `window.__ubFPS()` readout.

import Foundation

/// In-process replacement for the Node sidecar. Composes the pieces
/// (`WidgetServer`, `WidgetWatcher`, `JSXTransformer`, `CommandRunner`) into
/// a single object the app delegate owns in place of the old `widgetServer`
/// NSTask.
///
/// Wire contract — stays 1:1 with the Node server so existing client-side JS
/// keeps working unchanged.
///
/// **HTTP routes**
/// - `GET /` — index.html (from bundled `public/`).
/// - `GET /state/` — JSON dump of `{widgets, settings, screens}`.
/// - `GET /widgets/<id>` — bundled widget ES module (JSXTransformer output).
/// - `GET /userMain.css` — widget dir's optional `main.css`.
/// - `GET /<static>` — any file under `public/` (css, client.js, etc).
/// - `POST /run/` — run the request body as a shell command in the widget
///   dir; streams stdout/stderr back.
/// - `POST /widget-control` — `{id, action: 'hide'|'show'}` envelope used by
///   external scripting.
///
/// **WebSocket envelopes** `{type, payload}` JSON — pure pub/sub: any frame
/// received is broadcast to every connected client. The coordinator also
/// subscribes itself, running each action through the reducer to keep
/// server-side state in sync with what clients see.
public actor WidgetCoordinator {

    public struct Config: Sendable {
        public var widgetDirectory: URL
        public var publicDirectory: URL
        public var settingsDirectory: URL
        public var port: UInt16
        public var maxPortAttempts: Int
        public var loginShell: Bool

        public init(
            widgetDirectory: URL,
            publicDirectory: URL,
            settingsDirectory: URL,
            port: UInt16 = 41416,
            maxPortAttempts: Int = 20,
            loginShell: Bool = false
        ) {
            self.widgetDirectory = widgetDirectory
            self.publicDirectory = publicDirectory
            self.settingsDirectory = settingsDirectory
            self.port = port
            self.maxPortAttempts = maxPortAttempts
            self.loginShell = loginShell
        }
    }

    public let config: Config
    public private(set) var boundPort: UInt16 = 0

    private var server: WidgetServer?
    private var watcher: WidgetWatcher?
    private var watcherTask: Task<Void, Never>?
    private let transformer = JSXTransformer()

    // Widget state — shape mirrors the Node reducer output that
    // `UBWidgetsStore.reset:` already knows how to consume.
    private var widgets: [String: [String: Any]] = [:]
    private var settings: [String: [String: Any]] = [:]
    private var screens: [Int] = []
    private var widgetSources: [String: String] = [:]   // id → bundled JS
    private var connectedSockets: [WebSocketConnection] = []
    // One persistent `/bin/bash -s` per widget id. Saves a fork+exec per
    // refresh tick for widgets with string `command:` values, which is the
    // dominant CPU cost on a setup with many polling widgets.
    private var persistentShells: [String: PersistentShell] = [:]
    private let perf = PerfCollector()

    private static func defaultSettings() -> [String: Any] {
        [
            "showOnAllScreens": true,
            "showOnMainScreen": false,
            "showOnSelectedScreens": false,
            "hidden": false,
            "screens": [] as [Int],
        ]
    }

    public init(config: Config) {
        self.config = config
    }

    // MARK: - Lifecycle

    public func start() async throws {
        loadPersistedSettings()
        try startServer()
        startWatcher()
        await seedExistingWidgets()
    }

    public func stop() {
        watcherTask?.cancel()
        watcherTask = nil
        watcher?.stop()
        watcher = nil
        server?.stop()
        server = nil
        connectedSockets.forEach { $0.close() }
        connectedSockets.removeAll()
        for shell in persistentShells.values {
            Task { await shell.stop() }
        }
        persistentShells.removeAll()
    }

    /// Snapshot the state in the exact shape `UBWidgetsStore.reset:` expects:
    /// `{widgets: {id: widget}, settings: {id: settings}, screens: [..]}`.
    /// Returns JSON bytes (Sendable) so actor-isolated state can safely cross
    /// back to the main actor without triggering Sendable warnings.
    public func stateSnapshotData() -> Data {
        let snap: [String: Any] = [
            "widgets": widgets,
            "settings": settings,
            "screens": screens,
        ]
        return (try? JSONSerialization.data(withJSONObject: snap)) ?? Data("{}".utf8)
    }

    private func stateSnapshot() -> [String: Any] {
        [
            "widgets": widgets,
            "settings": settings,
            "screens": screens,
        ]
    }

    // MARK: - Server

    private func startServer() throws {
        let coordinator = self
        let serverConfig = WidgetServer.Config(
            port: config.port,
            maxPortAttempts: config.maxPortAttempts,
            router: { request in
                await coordinator.route(request)
            },
            onWebSocket: { socket in
                await coordinator.attach(socket: socket)
            }
        )
        let server = WidgetServer(config: serverConfig)
        try server.start()
        self.server = server
        self.boundPort = server.boundPort
    }

    // MARK: - Watcher

    private func startWatcher() {
        let watcher = WidgetWatcher(directory: config.widgetDirectory)
        self.watcher = watcher
        let events = watcher.events()
        watcherTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event: event)
            }
        }
    }

    /// FSEvents with `EventIdSinceNow` doesn't replay history, so walk the
    /// directory once at boot and emit the initial widget set.
    private func seedExistingWidgets() async {
        let root = config.widgetDirectory
        let urls = Self.findWidgetFiles(under: root)
        for url in urls where shouldBundle(url) {
            await bundleAndPublish(url, initial: true)
        }
    }

    private static func findWidgetFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsx" {
            result.append(url)
        }
        return result
    }

    private func handle(event: WidgetWatcher.Event) async {
        switch event {
        case .created(let url), .modified(let url):
            guard shouldBundle(url) else { return }
            await bundleAndPublish(url, initial: false)
        case .removed(let url):
            guard shouldBundle(url) else { return }
            let id = widgetId(for: url)
            if widgets[id] != nil {
                dispatch(action: ["type": "WIDGET_REMOVED", "payload": id])
            }
        }
    }

    private func shouldBundle(_ url: URL) -> Bool {
        let parts = url.pathComponents
        if parts.contains("node_modules") || parts.contains("lib") || parts.contains("src") {
            return false
        }
        return true
    }

    private func bundleAndPublish(_ url: URL, initial: Bool) async {
        let id = widgetId(for: url)
        do {
            let source = try await transformer.transform(url)
            widgetSources[id] = source
            let mtime = (try? FileManager.default
                .attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? 0
            let widget: [String: Any] = [
                "id": id,
                "filePath": url.path,
                "mtime": mtime,
            ]
            dispatch(action: ["type": "WIDGET_ADDED", "payload": widget])
        } catch {
            // Wire protocol: surface bundler errors as a widget with an error
            // field attached so the client can render the ErrorDetails view.
            let errorInfo: [String: Any] = [
                "message": String(describing: error),
                "path": url.path,
            ]
            let widget: [String: Any] = [
                "id": id,
                "filePath": url.path,
                "error": errorInfo,
                "mtime": Date().timeIntervalSince1970,
            ]
            widgetSources[id] = nil
            dispatch(action: ["type": "WIDGET_ADDED", "payload": widget])
        }
    }

    /// Matches the Node `resolveWidget.widgetId`:
    ///   absolute path → relative → split on `/` (drop empties) → join with `-`
    ///   → replace `.` with `-` → replace whitespace with `_`.
    /// So `/root/Clock/index.jsx` → `Clock-index-jsx`.
    private func widgetId(for url: URL) -> String {
        let root = config.widgetDirectory.path
        var rel = url.path
        if rel.hasPrefix(root) {
            rel = String(rel.dropFirst(root.count))
        }
        let parts = rel.split(separator: "/").filter { !$0.isEmpty }
        let joined = parts.joined(separator: "-")
        return joined
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: " ", with: "_")
    }

    // MARK: - WebSocket

    private func attach(socket: WebSocketConnection) {
        connectedSockets.append(socket)
        socket.onMessage { [weak self] message in
            Task { await self?.handleSocketMessage(message, from: socket) }
        }
    }

    private func handleSocketMessage(_ message: WebSocketConnection.Message, from socket: WebSocketConnection) {
        switch message {
        case .text(let text):
            guard let data = text.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            dispatch(action: parsed)
        case .binary:
            break
        case .closed:
            connectedSockets.removeAll { $0 === socket }
        }
    }

    /// Single entry point for state mutation. Runs the action through the
    /// reducer then enqueues a broadcast. Broadcasts are coalesced within a
    /// short window so a burst of actions (e.g. N `WIDGET_ADDED` events at
    /// startup) ships as one WebSocket frame per client instead of N.
    private func dispatch(action: [String: Any]) {
        reduce(action: action)
        enqueueBroadcast(action)
    }

    // Broadcast coalescing: collects actions fired in the same event-loop
    // window and flushes them in one WS frame (as a `BATCH` envelope when
    // there are multiple). Saves a frame per action on bursty workloads:
    // the per-frame fixed cost (header + send call + client-side JSON.parse
    // + Redux dispatch) dominates for small payloads.
    private var pendingBroadcasts: [[String: Any]] = []
    private var flushScheduled = false
    private static let coalesceWindow: Duration = .milliseconds(4)

    private func enqueueBroadcast(_ action: [String: Any]) {
        pendingBroadcasts.append(action)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: Self.coalesceWindow)
            await self?.flushBroadcasts()
        }
    }

    private func flushBroadcasts() {
        flushScheduled = false
        let actions = pendingBroadcasts
        pendingBroadcasts.removeAll()
        guard !actions.isEmpty else { return }

        let envelope: [String: Any]
        if actions.count == 1 {
            envelope = actions[0]
        } else {
            // `BATCH` is a transport-only envelope — the client's listener
            // unwraps it before handing individual actions to the reducer.
            envelope = ["type": "BATCH", "payload": actions]
        }

        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope),
              let json = String(data: data, encoding: .utf8)
        else { return }

        for socket in connectedSockets {
            socket.send(text: json)
        }
        let bytes = data.count * connectedSockets.count
        Task { [perf] in await perf.recordWsMessage(bytes: bytes) }
    }

    // MARK: - Reducer (1:1 port of server/src/reducer.js)

    private func reduce(action: [String: Any]) {
        guard let type = action["type"] as? String else { return }
        let payload = action["payload"]

        switch type {
        case "WIDGET_ADDED":
            guard let widget = payload as? [String: Any],
                  let id = widget["id"] as? String else { return }
            widgets[id] = widget
            if settings[id] == nil {
                settings[id] = Self.defaultSettings()
                persistSettings()
            }

        case "WIDGET_LOADED":
            guard let id = action["id"] as? String,
                  var widget = widgets[id] else { return }
            widget["implementation"] = payload
            widgets[id] = widget

        case "WIDGET_REMOVED":
            guard let id = payload as? String else { return }
            widgets[id] = nil
            widgetSources[id] = nil
            if let shell = persistentShells.removeValue(forKey: id) {
                Task { await shell.stop() }
            }

        case "WIDGET_SETTINGS_CHANGED":
            guard let p = payload as? [String: Any],
                  let id = p["id"] as? String,
                  let newSettings = p["settings"] as? [String: Any] else { return }
            settings[id] = newSettings
            persistSettings()

        case "WIDGET_SET_TO_ALL_SCREENS":
            guard let id = payload as? String else { return }
            updateSettings(id: id, patch: [
                "showOnAllScreens": true,
                "showOnSelectedScreens": false,
                "showOnMainScreen": false,
                "hidden": false,
                "screens": [] as [Int],
            ])

        case "WIDGET_SET_TO_SELECTED_SCREENS":
            guard let id = payload as? String else { return }
            updateSettings(id: id, patch: [
                "showOnSelectedScreens": true,
                "showOnAllScreens": false,
                "showOnMainScreen": false,
                "hidden": false,
            ])

        case "WIDGET_SET_TO_MAIN_SCREEN":
            guard let id = payload as? String else { return }
            updateSettings(id: id, patch: [
                "showOnSelectedScreens": false,
                "showOnAllScreens": false,
                "showOnMainScreen": true,
                "hidden": false,
                "screens": [] as [Int],
            ])

        case "WIDGET_SET_TO_HIDE":
            guard let id = payload as? String else { return }
            updateSettings(id: id, patch: ["hidden": true])

        case "WIDGET_SET_TO_SHOW":
            guard let id = payload as? String else { return }
            updateSettings(id: id, patch: ["hidden": false])

        case "WIDGET_SET_TO_BACKGROUND":
            guard let id = payload as? String else { return }
            updateSettings(id: id, patch: ["inBackground": true])

        case "WIDGET_SET_TO_FOREGROUND":
            guard let id = payload as? String else { return }
            updateSettings(id: id, patch: ["inBackground": false])

        case "SCREEN_SELECTED_FOR_WIDGET":
            guard let p = payload as? [String: Any],
                  let id = p["id"] as? String,
                  let screenId = p["screenId"] as? NSNumber else { return }
            var current = (settings[id]?["screens"] as? [NSNumber]) ?? []
            if !current.contains(screenId) {
                current.append(screenId)
            }
            updateSettings(id: id, patch: ["screens": current])

        case "SCREEN_DESELECTED_FOR_WIDGET":
            guard let p = payload as? [String: Any],
                  let id = p["id"] as? String,
                  let screenId = p["screenId"] as? NSNumber else { return }
            let filtered = ((settings[id]?["screens"] as? [NSNumber]) ?? [])
                .filter { $0 != screenId }
            updateSettings(id: id, patch: ["screens": filtered])

        case "SCREENS_DID_CHANGE":
            screens = (payload as? [Int]) ?? []

        default:
            break
        }
    }

    private func updateSettings(id: String, patch: [String: Any]) {
        var current = settings[id] ?? Self.defaultSettings()
        for (key, value) in patch {
            current[key] = value
        }
        settings[id] = current
        persistSettings()
    }

    // MARK: - Settings persistence

    private var settingsFileURL: URL {
        config.settingsDirectory.appendingPathComponent("WidgetSettings.json")
    }

    private func loadPersistedSettings() {
        guard
            let data = try? Data(contentsOf: settingsFileURL),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return }
        settings = parsed
    }

    private func persistSettings() {
        try? FileManager.default.createDirectory(
            at: config.settingsDirectory,
            withIntermediateDirectories: true
        )
        guard
            JSONSerialization.isValidJSONObject(settings),
            let data = try? JSONSerialization.data(withJSONObject: settings)
        else { return }
        try? data.write(to: settingsFileURL, options: .atomic)
    }

    // MARK: - HTTP router

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path

        // POST endpoints
        if request.method == "POST" {
            switch path {
            case "/run/":
                return await runShellCommand(request: request)
            case "/widget-control":
                return widgetControl(body: request.body)
            default:
                return .notFound
            }
        }

        // GET
        if path == "/" || path == "/index.html" {
            return .file(at: config.publicDirectory.appendingPathComponent("index.html"))
        }
        if path == "/state/" || path == "/state" {
            return .json(stateSnapshot())
        }
        if path == "/perf" || path == "/perf/" {
            let data = await perf.snapshotData()
            return HTTPResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: data
            )
        }
        if path == "/userMain.css" {
            let css = config.widgetDirectory.appendingPathComponent("main.css")
            if FileManager.default.fileExists(atPath: css.path) {
                return .file(at: css)
            }
            return .text("", contentType: "text/css; charset=utf-8")
        }
        if path.hasPrefix("/widgets/") {
            let id = String(path.dropFirst("/widgets/".count))
            if let source = widgetSources[id] {
                return .text(source, contentType: "application/javascript; charset=utf-8")
            }
            return .notFound
        }

        // Static from public/, then widget dir (so widgets can serve assets).
        let cleaned = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let publicCandidate = config.publicDirectory.appendingPathComponent(cleaned)
        if FileManager.default.fileExists(atPath: publicCandidate.path) {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: publicCandidate.path, isDirectory: &isDir)
            if !isDir.boolValue {
                return .file(at: publicCandidate)
            }
        }
        let widgetCandidate = config.widgetDirectory.appendingPathComponent(cleaned)
        if FileManager.default.fileExists(atPath: widgetCandidate.path) {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: widgetCandidate.path, isDirectory: &isDir)
            if !isDir.boolValue {
                return .file(at: widgetCandidate)
            }
        }
        // Webviews load URLs like `/1/foreground/` (screen/layer routing in
        // `UBWindowGroup`). The old Node server's `serveClient` middleware
        // served `index.html` for any path that didn't match a static file
        // or API route. Mirror that: any GET that falls all the way through
        // gets the SPA entry so the client JS can inspect `location.pathname`.
        return .file(at: config.publicDirectory.appendingPathComponent("index.html"))
    }

    private func runShellCommand(request: HTTPRequest) async -> HTTPResponse {
        let command = String(data: request.body, encoding: .utf8) ?? ""
        // VirtualDomWidget sets `X-Widget-Id` so we can route to a per-widget
        // persistent shell. Requests without an id (e.g. ad-hoc tooling) get
        // a one-shot CommandRunner like before.
        if let widgetId = request.header("X-Widget-Id"), !widgetId.isEmpty {
            return await runInPersistentShell(command: command, widgetId: widgetId)
        }
        return await runOneShot(command: command)
    }

    private func runInPersistentShell(command: String, widgetId: String) async -> HTTPResponse {
        let shell = shellFor(widgetId: widgetId)
        if shell == nil {
            // Falling back silently means a widget that can never spawn its
            // shell silently becomes a CPU hot-spot as every tick falls
            // back to fork+exec. Surface the failure instead.
            return .text("failed to start persistent shell", status: 500)
        }
        let start = Date().timeIntervalSince1970
        do {
            let result = try await shell!.run(command)
            let durationMs = (Date().timeIntervalSince1970 - start) * 1000
            await perf.recordCommand(
                command: command.trimmingCharacters(in: .whitespacesAndNewlines),
                durationMs: durationMs,
                bytesOut: result.stdout.utf8.count,
                widgetId: widgetId
            )
            if result.exitCode != 0 {
                return HTTPResponse(
                    status: 500,
                    headers: ["Content-Type": "text/plain; charset=utf-8"],
                    body: Data(result.stdout.utf8)
                )
            }
            return .text(result.stdout, contentType: "text/plain; charset=utf-8")
        } catch PersistentShell.Failure.shellDied {
            persistentShells[widgetId] = nil
            // One retry on a fresh shell — avoids a persistent failure
            // state if the shell died for a transient reason.
            if let revived = shellFor(widgetId: widgetId),
               let result = try? await revived.run(command) {
                return result.exitCode == 0
                    ? .text(result.stdout, contentType: "text/plain; charset=utf-8")
                    : HTTPResponse(status: 500, headers: ["Content-Type": "text/plain"], body: Data(result.stdout.utf8))
            }
            return .text("shell died", status: 500)
        } catch {
            return .text(String(describing: error), status: 500)
        }
    }

    private func shellFor(widgetId: String) -> PersistentShell? {
        if let existing = persistentShells[widgetId] { return existing }
        do {
            let shell = try PersistentShell(
                workingDirectory: config.widgetDirectory,
                loginShell: config.loginShell
            )
            persistentShells[widgetId] = shell
            return shell
        } catch {
            NSLog("PersistentShell launch failed: %@", String(describing: error))
            return nil
        }
    }

    private func runOneShot(command: String) async -> HTTPResponse {
        let start = Date().timeIntervalSince1970
        let runner = CommandRunner(
            command: command,
            options: CommandRunner.Options(workingDirectory: config.widgetDirectory)
        )
        var stdout = ""
        var stderr = ""
        var exit: Int32 = 0
        do {
            for try await event in runner.stream() {
                switch event {
                case .stdout(let s): stdout += s
                case .stderr(let s): stderr += s
                case .exit(let code): exit = code
                }
            }
        } catch {
            return .text(String(describing: error), status: 500)
        }
        let durationMs = (Date().timeIntervalSince1970 - start) * 1000
        await perf.recordCommand(
            command: command.trimmingCharacters(in: .whitespacesAndNewlines),
            durationMs: durationMs,
            bytesOut: stdout.utf8.count,
            widgetId: nil
        )
        if exit != 0 || !stderr.isEmpty {
            return HTTPResponse(
                status: stderr.isEmpty ? 200 : 500,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: Data((stdout + stderr).utf8)
            )
        }
        return .text(stdout, contentType: "text/plain; charset=utf-8")
    }

    private func widgetControl(body: Data) -> HTTPResponse {
        guard let parsed = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = parsed["id"] as? String,
              let action = parsed["action"] as? String
        else {
            return .text("invalid body", status: 400)
        }
        let type: String
        switch action {
        case "hide": type = "WIDGET_SET_TO_HIDE"
        case "show": type = "WIDGET_SET_TO_SHOW"
        default: return .text("unknown action", status: 400)
        }
        dispatch(action: ["type": type, "payload": id])
        return .json(["ok": true])
    }
}

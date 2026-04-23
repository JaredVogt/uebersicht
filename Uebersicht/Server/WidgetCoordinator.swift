import Foundation

/// In-process replacement for the Node sidecar. Composes the pieces
/// (`WidgetServer`, `WidgetWatcher`, `JSXTransformer`, `CommandRunner`)
/// into a single object the app delegate owns in place of the old
/// `widgetServer` NSTask.
///
/// Wire contract — must stay 1:1 with the Node server so the existing
/// client-side JS keeps working unchanged:
///
/// **HTTP routes**
/// - `GET /` — index.html (from bundled `public/`).
/// - `GET /<static>` — any file under `public/`.
/// - `GET /state/` — JSON dump of the widget state.
/// - `GET /widgets/<id>.js` — bundled widget ES module (JSXTransformer output).
/// - `GET /notifications.json` — errors + warnings log.
///
/// **WebSocket envelopes** `{type, payload}` JSON:
/// - Server → client: `WIDGET_ADDED`, `WIDGET_CHANGED`, `WIDGET_REMOVED`,
///   `WIDGET_OUTPUT`, `MASTER_STYLE_CHANGED`.
/// - Client → server: `RUN_COMMAND { id, command }`, dispatched action
///   objects routed to the state store.
///
/// Status — this session lands the coordinator shell + widget/state
/// scaffolding. The actual route handlers are TODO; they're the focus of
/// the next integration pass.
public actor WidgetCoordinator {

    public struct Config: Sendable {
        public var widgetDirectory: URL
        public var publicDirectory: URL
        public var port: UInt16
        public var maxPortAttempts: Int

        public init(
            widgetDirectory: URL,
            publicDirectory: URL,
            port: UInt16 = 41416,
            maxPortAttempts: Int = 20
        ) {
            self.widgetDirectory = widgetDirectory
            self.publicDirectory = publicDirectory
            self.port = port
            self.maxPortAttempts = maxPortAttempts
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
    private var widgetSources: [String: String] = [:]   // id → bundled JS
    private var connectedSockets: [WebSocketConnection] = []

    public init(config: Config) {
        self.config = config
    }

    // MARK: - Lifecycle

    public func start() async throws {
        try startServer()
        startWatcher()
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
    }

    // MARK: - Wire to existing Obj-C plumbing

    /// Returns the state snapshot in the exact shape `UBWidgetsStore.reset:`
    /// expects: `{ widgets: {id: widget}, settings: {id: settings} }`.
    public func stateSnapshot() -> [String: Any] {
        [
            "widgets": widgets,
            "settings": settings,
        ]
    }

    // MARK: - Internals

    private func startServer() throws {
        let coordinator = self
        let config = WidgetServer.Config(
            port: config.port,
            maxPortAttempts: config.maxPortAttempts,
            router: { request in
                await coordinator.route(request)
            },
            onWebSocket: { socket in
                await coordinator.attach(socket: socket)
            }
        )
        let server = WidgetServer(config: config)
        try server.start()
        self.server = server
        self.boundPort = server.boundPort
    }

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

    // MARK: - Router

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        let path = request.path

        if path == "/" || path == "/index.html" {
            return .file(at: config.publicDirectory.appendingPathComponent("index.html"))
        }
        if path == "/state/" || path == "/state" {
            return .json(stateSnapshot())
        }
        if path.hasPrefix("/widgets/") {
            let id = String(path.dropFirst("/widgets/".count)).replacingOccurrences(of: ".js", with: "")
            if let source = widgetSources[id] {
                return .text(source, contentType: "application/javascript; charset=utf-8")
            }
            return .notFound
        }
        // Fall through to static /public.
        let cleaned = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let candidate = config.publicDirectory.appendingPathComponent(cleaned)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return .file(at: candidate)
        }
        return .notFound
    }

    // MARK: - WebSocket

    private func attach(socket: WebSocketConnection) {
        connectedSockets.append(socket)
        // Push the current state on connect so new clients bootstrap.
        if let data = try? JSONSerialization.data(withJSONObject: [
            "type": "STATE_SNAPSHOT",
            "payload": stateSnapshot(),
        ]), let json = String(data: data, encoding: .utf8) {
            socket.send(text: json)
        }
        socket.onMessage { [weak self] message in
            Task { await self?.handleSocketMessage(message, from: socket) }
        }
    }

    private func handleSocketMessage(_ message: WebSocketConnection.Message, from socket: WebSocketConnection) {
        switch message {
        case .text(let text):
            guard let data = text.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = parsed["type"] as? String
            else { return }
            handleAction(type: type, payload: parsed["payload"], from: socket)
        case .binary:
            // Not currently used by the protocol.
            break
        case .closed:
            connectedSockets.removeAll { $0 === socket }
        }
    }

    private func handleAction(type: String, payload: Any?, from socket: WebSocketConnection) {
        // Placeholder: the Node reducer has ~80 lines of logic for actions
        // like WIDGET_SETTINGS_CHANGED, SCREEN_SELECTED_FOR_WIDGET, etc.
        // Port that here in the integration pass. For now we just re-broadcast
        // so the Obj-C `UBListener` path still sees everything.
        broadcast(type: type, payload: payload)
    }

    private func broadcast(type: String, payload: Any?) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: [
                "type": type,
                "payload": payload as Any,
            ]),
            let json = String(data: data, encoding: .utf8)
        else { return }
        for socket in connectedSockets {
            socket.send(text: json)
        }
    }

    // MARK: - Watcher → bundle → broadcast

    private func handle(event: WidgetWatcher.Event) async {
        switch event {
        case .created(let url), .modified(let url):
            await bundleAndPublish(url)
        case .removed(let url):
            let id = widgetId(for: url)
            widgets[id] = nil
            widgetSources[id] = nil
            broadcast(type: "WIDGET_REMOVED", payload: id)
        }
    }

    private func bundleAndPublish(_ url: URL) async {
        let id = widgetId(for: url)
        do {
            let source = try await transformer.transform(url)
            widgetSources[id] = source
            let widget: [String: Any] = [
                "id": id,
                "filePath": url.path,
                "mtime": (try? FileManager.default
                    .attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?
                    .timeIntervalSince1970 ?? 0,
            ]
            let action: String = widgets[id] == nil ? "WIDGET_ADDED" : "WIDGET_CHANGED"
            widgets[id] = widget
            broadcast(type: action, payload: widget)
        } catch {
            broadcast(type: "WIDGET_ERROR", payload: [
                "id": id,
                "error": String(describing: error),
            ])
        }
    }

    private func widgetId(for url: URL) -> String {
        let rel = url.path.replacingOccurrences(
            of: config.widgetDirectory.path + "/",
            with: ""
        )
        return rel.replacingOccurrences(of: ".jsx", with: "")
    }
}

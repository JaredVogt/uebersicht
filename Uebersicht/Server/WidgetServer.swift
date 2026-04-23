import Foundation
import Network

/// Native Swift replacement for the Node `server.coffee` HTTP + WebSocket
/// listener. Single process, single port (41416 by default, bumped on
/// collision), powered by Network.framework.
///
/// Scope right now is the framing: the listener accepts connections,
/// dispatches HTTP requests through a `Router`, and upgrades WebSocket
/// connections via `NWProtocolWebSocket`. The routes themselves — widget
/// bundling, state serving, shell command execution — are layered on top
/// by the final PR 4 integration step (coordinator not landed yet).
public final class WidgetServer: @unchecked Sendable {

    public struct Config: Sendable {
        public var port: UInt16
        public var maxPortAttempts: Int
        public var router: @Sendable (HTTPRequest) async -> HTTPResponse
        public var onWebSocket: @Sendable (WebSocketConnection) async -> Void

        public init(
            port: UInt16 = 41416,
            maxPortAttempts: Int = 20,
            router: @escaping @Sendable (HTTPRequest) async -> HTTPResponse = { _ in .notFound },
            onWebSocket: @escaping @Sendable (WebSocketConnection) async -> Void = { _ in }
        ) {
            self.port = port
            self.maxPortAttempts = maxPortAttempts
            self.router = router
            self.onWebSocket = onWebSocket
        }
    }

    public private(set) var boundPort: UInt16 = 0

    private var listener: NWListener?
    private let config: Config
    private let queue = DispatchQueue(label: "uebersicht.widget-server")

    public init(config: Config) {
        self.config = config
    }

    public func start() throws {
        var lastError: (any Error)?
        for offset in 0..<config.maxPortAttempts {
            let candidate = config.port + UInt16(offset)
            do {
                try startOn(port: candidate)
                boundPort = candidate
                return
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? ServerError.noAvailablePort
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Internals

    private func startOn(port: UInt16) throws {
        let params = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                NSLog("WidgetServer: listener failed: %@", String(describing: err))
            }
        }
        listener.start(queue: queue)
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        let conn = ConnectionContext(
            connection: connection,
            config: config,
            queue: queue
        )
        conn.begin()
    }

    public enum ServerError: Error { case noAvailablePort }
}

// MARK: - HTTP value types

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static let notFound = HTTPResponse(status: 404, body: Data("not found".utf8))

    public static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return HTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: data
        )
    }

    public static func text(_ s: String, status: Int = 200, contentType: String = "text/plain") -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: ["Content-Type": contentType],
            body: Data(s.utf8)
        )
    }
}

// MARK: - WebSocket connection

public final class WebSocketConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var handler: (@Sendable (Message) -> Void)?

    public enum Message: Sendable {
        case text(String)
        case binary(Data)
        case closed
    }

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    public func onMessage(_ handler: @escaping @Sendable (Message) -> Void) {
        self.handler = handler
        receive()
    }

    public func send(text: String) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(
            content: Data(text.utf8),
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }

    public func close() {
        connection.cancel()
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error {
                NSLog("WS recv error: %@", String(describing: error))
                self.handler?(.closed)
                return
            }
            if let data,
               let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch metadata.opcode {
                case .text:
                    self.handler?(.text(String(decoding: data, as: UTF8.self)))
                case .binary:
                    self.handler?(.binary(data))
                case .close:
                    self.handler?(.closed)
                    return
                default:
                    break
                }
            }
            self.receive()
        }
    }
}

// MARK: - Per-connection context

/// Parses the initial HTTP request, routes it, and either writes back an
/// HTTP response or (on a WebSocket upgrade) hands off to the config's
/// `onWebSocket` callback.
private final class ConnectionContext: @unchecked Sendable {
    let connection: NWConnection
    let config: WidgetServer.Config
    let queue: DispatchQueue
    var accumulator = Data()

    init(connection: NWConnection, config: WidgetServer.Config, queue: DispatchQueue) {
        self.connection = connection
        self.config = config
        self.queue = queue
    }

    func begin() {
        // NWProtocolWebSocket transparently handles the upgrade handshake
        // when the client negotiates WebSocket. In that case
        // `receiveMessage` yields websocket frames; otherwise we receive
        // the raw HTTP bytes via `receive(minimumIncompleteLength:)`.
        //
        // We use the message-based path first to detect the upgrade: on a
        // websocket connection, the first receive gives metadata with
        // opcode=text/binary. On plain HTTP, receiveMessage still works
        // because `NWConnection` will surface the accumulated bytes.
        //
        // Implementation choice: peek via raw receive; if it's a WS
        // upgrade, Network.framework has already completed the handshake
        // and we'll see a websocket opcode on receiveMessage instead.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            guard let self else { return }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                // It's a WebSocket upgrade — start streaming through the WS API.
                _ = metadata
                self.handleWebSocket()
                return
            }
            if let data { self.accumulator.append(data) }
            if let request = Self.parseRequest(self.accumulator) {
                Task { [config = self.config, accumulator = self.accumulator, connection = self.connection] in
                    let response = await config.router(request)
                    let bytes = Self.serialize(response)
                    connection.send(content: bytes, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    _ = accumulator
                }
            } else if error != nil || isComplete {
                self.connection.cancel()
            } else {
                self.begin()
            }
        }
    }

    private func handleWebSocket() {
        let ws = WebSocketConnection(connection: connection, queue: queue)
        Task { [config = self.config] in
            await config.onWebSocket(ws)
        }
    }

    // MARK: - HTTP parsing / serialization

    static func parseRequest(_ data: Data) -> HTTPRequest? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        guard let headerEnd = raw.range(of: "\r\n\r\n") else { return nil }

        let headerPart = raw[raw.startIndex..<headerEnd.lowerBound]
        let bodyPart = raw[headerEnd.upperBound..<raw.endIndex]
        let lines = headerPart.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let sep = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<sep].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: sep)..<line.endIndex].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        if let contentLengthStr = headers["Content-Length"],
           let contentLength = Int(contentLengthStr),
           bodyPart.count < contentLength {
            return nil // wait for more bytes
        }

        return HTTPRequest(
            method: String(parts[0]),
            path: String(parts[1]),
            headers: headers,
            body: Data(bodyPart.utf8)
        )
    }

    static func serialize(_ response: HTTPResponse) -> Data {
        var out = "HTTP/1.1 \(response.status) \(statusText(response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        if headers["Connection"] == nil { headers["Connection"] = "close" }
        for (k, v) in headers { out += "\(k): \(v)\r\n" }
        out += "\r\n"
        var data = Data(out.utf8)
        data.append(response.body)
        return data
    }

    static func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default:  return "OK"
        }
    }
}

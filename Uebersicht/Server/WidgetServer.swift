import Foundation
import Network

/// Native Swift replacement for the Node `server.coffee` HTTP + WebSocket
/// listener. Runs on a single TCP port (41416 by default, bumped on port
/// collision). Does HTTP routing for static files / widget bundles / state,
/// and handles the WebSocket handshake + framing manually — on-connection
/// first bytes are HTTP; if they include `Upgrade: websocket`, we reply
/// with the 101 handshake (see `WebSocketFrame.handshakeResponse`) and
/// switch that connection's reader to frame-decode mode.
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

    public enum ServerError: Error { case noAvailablePort }

    // MARK: - Internals

    private func startOn(port: UInt16) throws {
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener

        listener.newConnectionHandler = { [config, queue] connection in
            let handler = ConnectionHandler(connection: connection, config: config, queue: queue)
            handler.begin()
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                NSLog("WidgetServer: listener failed: %@", String(describing: err))
            }
        }
        listener.start(queue: queue)
    }
}

// MARK: - HTTP value types

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    /// Case-insensitive header lookup.
    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }
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
        HTTPResponse(status: status, headers: ["Content-Type": contentType], body: Data(s.utf8))
    }

    public static func file(at url: URL) -> HTTPResponse {
        guard let data = try? Data(contentsOf: url) else { return .notFound }
        return HTTPResponse(
            status: 200,
            headers: ["Content-Type": contentType(for: url)],
            body: data
        )
    }

    static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - WebSocket connection

public final class WebSocketConnection: @unchecked Sendable {

    public enum Message: Sendable {
        case text(String)
        case binary(Data)
        case closed
    }

    private let connection: NWConnection
    private var handler: (@Sendable (Message) -> Void)?
    private var buffer = Data()

    init(connection: NWConnection) {
        self.connection = connection
    }

    public func onMessage(_ handler: @escaping @Sendable (Message) -> Void) {
        self.handler = handler
        receive()
    }

    public func send(text: String) {
        connection.send(
            content: WebSocketFrame.encode(text: text),
            completion: .contentProcessed { _ in }
        )
    }

    public func close() {
        connection.send(
            content: WebSocketFrame.encode(opcode: .close, payload: Data()),
            completion: .contentProcessed { [weak self] _ in self?.connection.cancel() }
        )
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let error {
                NSLog("WS read error: %@", String(describing: error))
                self.handler?(.closed)
                return
            }
            if let data { self.buffer.append(data) }
            self.drainFrames()
            if complete {
                self.handler?(.closed)
                return
            }
            self.receive()
        }
    }

    private func drainFrames() {
        while true {
            switch WebSocketFrame.decode(from: buffer) {
            case .needsMoreData:
                return
            case .frame(let decoded):
                buffer.removeFirst(decoded.bytesConsumed)
                switch decoded.opcode {
                case .text:
                    let s = String(data: decoded.payload, encoding: .utf8) ?? ""
                    handler?(.text(s))
                case .binary:
                    handler?(.binary(decoded.payload))
                case .close:
                    handler?(.closed)
                    connection.cancel()
                    return
                case .ping:
                    connection.send(
                        content: WebSocketFrame.encode(opcode: .pong, payload: decoded.payload),
                        completion: .contentProcessed { _ in }
                    )
                default:
                    break
                }
            }
        }
    }
}

// MARK: - Per-connection handler

/// Accumulates bytes on a new NWConnection, parses the first HTTP request,
/// and either serves it as HTTP or upgrades it to WebSocket.
private final class ConnectionHandler: @unchecked Sendable {
    let connection: NWConnection
    let config: WidgetServer.Config
    let queue: DispatchQueue
    var buffer = Data()

    init(connection: NWConnection, config: WidgetServer.Config, queue: DispatchQueue) {
        self.connection = connection
        self.config = config
        self.queue = queue
    }

    func begin() {
        connection.start(queue: queue)
        readMore()
    }

    private func readMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                NSLog("HTTP read error: %@", String(describing: error))
                self.connection.cancel()
                return
            }
            if let data { self.buffer.append(data) }
            if let request = HTTPParser.parse(self.buffer) {
                self.handle(request: request)
            } else if isComplete {
                self.connection.cancel()
            } else {
                self.readMore()
            }
        }
    }

    private func handle(request: HTTPRequest) {
        if let upgrade = request.header("Upgrade"), upgrade.lowercased() == "websocket" {
            upgradeToWebSocket(request)
        } else {
            Task { [config = self.config, connection = self.connection] in
                let response = await config.router(request)
                connection.send(
                    content: HTTPParser.serialize(response),
                    completion: .contentProcessed { _ in connection.cancel() }
                )
            }
        }
    }

    private func upgradeToWebSocket(_ request: HTTPRequest) {
        guard let key = request.header("Sec-WebSocket-Key") else {
            let response = HTTPResponse(status: 400, body: Data("bad WS upgrade".utf8))
            connection.send(
                content: HTTPParser.serialize(response),
                completion: .contentProcessed { [weak self] _ in self?.connection.cancel() }
            )
            return
        }
        let handshake = WebSocketFrame.handshakeResponse(forKey: key)
        connection.send(content: handshake, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            let ws = WebSocketConnection(connection: self.connection)
            Task { [config = self.config] in
                await config.onWebSocket(ws)
            }
        })
    }
}

// MARK: - HTTP parser

enum HTTPParser {
    /// Parses an HTTP request out of the provided bytes, or returns nil
    /// if the bytes don't yet contain a complete request (headers +
    /// declared Content-Length bytes of body).
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let raw = String(data: data, encoding: .utf8),
              let headerEnd = raw.range(of: "\r\n\r\n")
        else { return nil }

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

        if let contentLengthStr = headers["Content-Length"] ?? headers["content-length"],
           let contentLength = Int(contentLengthStr),
           bodyPart.utf8.count < contentLength {
            return nil
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
        case 101: return "Switching Protocols"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default:  return "OK"
        }
    }
}

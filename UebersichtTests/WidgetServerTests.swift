import Testing
import Foundation
@testable import Uebersicht

@Suite("WidgetServer HTTP")
struct WidgetServerTests {

    @Test("HTTPParser returns nil on partial input")
    func partialRequest() {
        let data = Data("GET /foo HTTP/1.1\r\n".utf8)
        #expect(HTTPParser.parse(data) == nil)
    }

    @Test("HTTPParser extracts method, path, headers")
    func fullRequest() throws {
        let raw = "GET /state HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n"
        let request = try #require(HTTPParser.parse(Data(raw.utf8)))
        #expect(request.method == "GET")
        #expect(request.path == "/state")
        #expect(request.headers["Host"] == "localhost")
    }

    @Test("HTTPParser serialize produces a valid HTTP/1.1 response")
    func serializeResponse() {
        let response = HTTPResponse.json(["ok": true])
        let data = HTTPParser.serialize(response)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Type: application/json"))
        #expect(text.contains("{\"ok\":true}"))
    }

    @Test("HTTPRequest.header is case-insensitive")
    func headerLookupCaseInsensitive() throws {
        let raw = "GET /x HTTP/1.1\r\nUpgrade: websocket\r\n\r\n"
        let request = try #require(HTTPParser.parse(Data(raw.utf8)))
        #expect(request.header("upgrade") == "websocket")
        #expect(request.header("Upgrade") == "websocket")
        #expect(request.header("UPGRADE") == "websocket")
    }

    @Test("HTTPResponse.json round-trips the body")
    func jsonBody() throws {
        let response = HTTPResponse.json(["widgets": ["a", "b"]])
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: response.body) as? [String: [String]]
        )
        #expect(decoded["widgets"] == ["a", "b"])
    }

    @Test("server binds a port without throwing")
    func bindPort() throws {
        let config = WidgetServer.Config(port: 48100, maxPortAttempts: 20)
        let server = WidgetServer(config: config)
        try server.start()
        #expect(server.boundPort >= 48100)
        server.stop()
    }

    // End-to-end tests that hit the live listener via URLSession are
    // disabled in the xctest harness — URLSession in the test host refuses
    // to complete 127.0.0.1 connections (we get NSURLErrorTimedOut after
    // 60s regardless of keep-alive/backoff settings). Run manually with a
    // small harness app when you need to verify the full HTTP/WS wire.
    @Test("end-to-end HTTP: plain GET returns routed response", .disabled("flaky in xctest; runs standalone"))
    func httpEndToEnd() async throws {
        let expected = "served from swift"
        let config = WidgetServer.Config(
            port: 48200,
            maxPortAttempts: 20
        ) { request in
            request.path == "/" ? .text(expected) : .notFound
        } onWebSocket: { _ in }

        let server = WidgetServer(config: config)
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(100))

        let url = URL(string: "http://127.0.0.1:\(server.boundPort)/")!
        let (body, response) = try await URLSession.shared.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self) == expected)
    }

    @Test("end-to-end WebSocket: connect, echo, disconnect", .disabled("flaky in xctest; runs standalone"))
    func webSocketEndToEnd() async throws {
        let config = WidgetServer.Config(
            port: 48300,
            maxPortAttempts: 20,
            router: { _ in .notFound },
            onWebSocket: { ws in
                ws.onMessage { message in
                    if case .text(let s) = message {
                        ws.send(text: "echo: \(s)")
                    }
                }
            }
        )

        let server = WidgetServer(config: config)
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(100))

        let url = URL(string: "ws://127.0.0.1:\(server.boundPort)/")!
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()

        try await task.send(.string("hello"))
        let reply = try await task.receive()
        if case .string(let s) = reply {
            #expect(s == "echo: hello")
        } else {
            Issue.record("expected text reply")
        }
        task.cancel(with: .goingAway, reason: nil)
    }
}

import Testing
import Foundation
@testable import Uebersicht

@Suite("WidgetServer HTTP")
struct WidgetServerTests {

    @Test("parseRequest returns nil on partial input")
    func partialRequest() {
        let data = Data("GET /foo HTTP/1.1\r\n".utf8)
        #expect(WidgetServer_parseRequest(data) == nil)
    }

    @Test("parseRequest extracts method, path, headers")
    func fullRequest() throws {
        let raw = "GET /state HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n"
        let request = try #require(WidgetServer_parseRequest(Data(raw.utf8)))
        #expect(request.method == "GET")
        #expect(request.path == "/state")
        #expect(request.headers["Host"] == "localhost")
    }

    @Test("serialize produces a valid HTTP/1.1 response line")
    func serializeResponse() {
        let response = HTTPResponse.json(["ok": true])
        let data = WidgetServer_serialize(response)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Type: application/json"))
        #expect(text.contains("{\"ok\":true}"))
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
        // Full HTTP end-to-end is gated behind the final PR 4 cutover
        // (NWProtocolWebSocket + plain HTTP on one listener needs a
        // dedicated framing layer we'll add there). For now, verify the
        // listener comes up on a free port.
        let config = WidgetServer.Config(port: 48100, maxPortAttempts: 20)
        let server = WidgetServer(config: config)
        try server.start()
        #expect(server.boundPort >= 48100)
        #expect(server.boundPort <= 48120)
        server.stop()
    }
}

// MARK: - Test helpers that mirror the server's private parser

// Duplicated from the private ConnectionContext in WidgetServer.swift so
// tests can cover the pure string-parsing logic without going through a
// socket. The production code keeps the parser fileprivate to its
// implementation; keep these shim signatures identical if you change the
// production implementation.
func WidgetServer_parseRequest(_ data: Data) -> HTTPRequest? {
    guard let raw = String(data: data, encoding: .utf8),
          let headerEnd = raw.range(of: "\r\n\r\n")
    else { return nil }
    let headerPart = raw[raw.startIndex..<headerEnd.lowerBound]
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
    return HTTPRequest(
        method: String(parts[0]),
        path: String(parts[1]),
        headers: headers,
        body: Data()
    )
}

func WidgetServer_serialize(_ response: HTTPResponse) -> Data {
    var out = "HTTP/1.1 \(response.status) OK\r\n"
    var headers = response.headers
    headers["Content-Length"] = String(response.body.count)
    if headers["Connection"] == nil { headers["Connection"] = "close" }
    for (k, v) in headers { out += "\(k): \(v)\r\n" }
    out += "\r\n"
    var data = Data(out.utf8)
    data.append(response.body)
    return data
}

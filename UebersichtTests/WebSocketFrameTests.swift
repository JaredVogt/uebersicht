import Testing
import Foundation
@testable import Uebersicht

@Suite("WebSocketFrame codec")
struct WebSocketFrameTests {

    @Test("encode then decode a small text frame round-trips")
    func encodeDecodeText() {
        // Our encoder produces unmasked frames (server-to-client). The
        // decoder accepts both, so we should be able to round-trip without
        // needing to fake a mask.
        let encoded = WebSocketFrame.encode(text: "hello")
        if case .frame(let decoded) = WebSocketFrame.decode(from: encoded) {
            #expect(decoded.opcode == .text)
            #expect(String(data: decoded.payload, encoding: .utf8) == "hello")
            #expect(decoded.bytesConsumed == encoded.count)
        } else {
            Issue.record("decode should return a frame")
        }
    }

    @Test("decode a client-style masked frame unmasks the payload")
    func maskedDecode() {
        // Build a masked frame by hand: FIN+text, masked, length=3, mask
        // key = 0x01 0x02 0x03 0x04, payload "abc" XOR'd with the mask.
        var frame = Data([0x81, 0x83, 0x01, 0x02, 0x03, 0x04])
        let payload = "abc".utf8.enumerated().map { i, byte in
            byte ^ [UInt8(0x01), 0x02, 0x03, 0x04][i % 4]
        }
        frame.append(contentsOf: payload)

        if case .frame(let decoded) = WebSocketFrame.decode(from: frame) {
            #expect(decoded.opcode == .text)
            #expect(String(data: decoded.payload, encoding: .utf8) == "abc")
        } else {
            Issue.record("decode should succeed")
        }
    }

    @Test("decode returns needsMoreData on truncated input")
    func partialDecode() {
        let encoded = WebSocketFrame.encode(text: "hello world")
        let truncated = encoded.prefix(3)
        if case .needsMoreData = WebSocketFrame.decode(from: Data(truncated)) {
            // expected
        } else {
            Issue.record("decode should request more data")
        }
    }

    @Test("handshake response contains the RFC 6455 magic accept hash")
    func handshake() {
        // RFC 6455 example: key "dGhlIHNhbXBsZSBub25jZQ==" must produce
        // accept "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=".
        let response = WebSocketFrame.handshakeResponse(forKey: "dGhlIHNhbXBsZSBub25jZQ==")
        let text = String(decoding: response, as: UTF8.self)
        #expect(text.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
        #expect(text.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
    }

    @Test("larger payload (over 125 bytes) uses the 16-bit length path")
    func extendedLength() {
        let big = String(repeating: "x", count: 500)
        let encoded = WebSocketFrame.encode(text: big)
        // Second byte is 126 signaling 16-bit length
        #expect(encoded[1] & 0x7F == 126)
        if case .frame(let decoded) = WebSocketFrame.decode(from: encoded) {
            #expect(decoded.payload.count == 500)
        } else {
            Issue.record("should decode extended-length frame")
        }
    }
}

import Foundation
import CryptoKit

/// Minimal RFC 6455 WebSocket encoder/decoder + handshake helper.
///
/// Enough to replace the Node sidecar's SocketIO/ws server for Übersicht's
/// needs: text frames, close frames, ping/pong, server-side framing
/// (unmasked) and client-side frame decoding (mask-required).
///
/// Scope limits (fine for our usage):
/// - No continuation/fragmented frames.
/// - 63-bit payload length supported but server never emits anything that
///   large; widget messages are tiny JSON envelopes.
/// - Compression extensions are not negotiated (`Sec-WebSocket-Extensions`
///   is ignored).
enum WebSocketFrame {

    enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    struct Decoded {
        let opcode: Opcode
        let payload: Data
        let bytesConsumed: Int
    }

    enum DecodeResult {
        case needsMoreData
        case frame(Decoded)
    }

    // MARK: - Handshake

    /// Produces the 101 upgrade response that the browser expects, given
    /// the client's `Sec-WebSocket-Key`.
    static func handshakeResponse(forKey key: String) -> Data {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let hash = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        let accept = Data(hash).base64EncodedString()
        let response =
            "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        return Data(response.utf8)
    }

    // MARK: - Decode

    /// Decodes a single frame from `buffer`. Returns `.needsMoreData` when
    /// the buffer is incomplete so callers can accumulate and retry.
    static func decode(from buffer: Data) -> DecodeResult {
        guard buffer.count >= 2 else { return .needsMoreData }
        let b0 = buffer[buffer.startIndex]
        let b1 = buffer[buffer.startIndex + 1]

        let opcodeRaw = b0 & 0x0F
        guard let opcode = Opcode(rawValue: opcodeRaw) else { return .needsMoreData }
        let masked = (b1 & 0x80) != 0
        let lengthField = Int(b1 & 0x7F)

        var cursor = buffer.startIndex + 2
        var payloadLength = lengthField

        if lengthField == 126 {
            guard buffer.count >= cursor - buffer.startIndex + 2 else { return .needsMoreData }
            payloadLength = Int(UInt16(buffer[cursor]) << 8 | UInt16(buffer[cursor + 1]))
            cursor += 2
        } else if lengthField == 127 {
            guard buffer.count >= cursor - buffer.startIndex + 8 else { return .needsMoreData }
            var length: UInt64 = 0
            for i in 0..<8 {
                length = (length << 8) | UInt64(buffer[cursor + i])
            }
            payloadLength = Int(length)
            cursor += 8
        }

        var maskKey: [UInt8] = []
        if masked {
            guard buffer.count >= cursor - buffer.startIndex + 4 else { return .needsMoreData }
            maskKey = Array(buffer[cursor..<cursor + 4])
            cursor += 4
        }

        guard buffer.count >= cursor - buffer.startIndex + payloadLength else {
            return .needsMoreData
        }

        var payload = Data(buffer[cursor..<cursor + payloadLength])
        if masked {
            for i in 0..<payload.count {
                payload[payload.startIndex + i] ^= maskKey[i % 4]
            }
        }
        cursor += payloadLength

        return .frame(Decoded(
            opcode: opcode,
            payload: payload,
            bytesConsumed: cursor - buffer.startIndex
        ))
    }

    // MARK: - Encode

    /// Encodes a server-to-client frame (unmasked, FIN set). Text frames
    /// take a String; binary frames take Data; control frames pass an empty
    /// payload unless you need close codes or ping payloads.
    static func encode(opcode: Opcode, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode.rawValue) // FIN=1 + opcode
        let length = payload.count
        if length < 126 {
            frame.append(UInt8(length))
        } else if length <= UInt16.max {
            frame.append(126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(127)
            var l = UInt64(length).bigEndian
            withUnsafeBytes(of: &l) { frame.append(contentsOf: $0) }
        }
        frame.append(payload)
        return frame
    }

    static func encode(text: String) -> Data {
        encode(opcode: .text, payload: Data(text.utf8))
    }
}

import Foundation

/// Sends typed events up to the widget server over the shared WebSocket.
///
/// Drop-in replacement for the Obj-C `UBDispatcher`. Every event becomes a
/// JSON envelope `{type, payload}` and goes out through the singleton
/// socket — same wire protocol as before, so the Node server (or its Swift
/// successor in PR 4) keeps working unchanged.
@objc(UBDispatcher)
@MainActor
public final class Dispatcher: NSObject {

    @objc(dispatch:withPayload:)
    public func dispatch(_ type: String, withPayload payload: Any) {
        let envelope: [String: Any] = ["type": type, "payload": payload]
        guard
            JSONSerialization.isValidJSONObject(envelope),
            let data = try? JSONSerialization.data(withJSONObject: envelope),
            let json = String(data: data, encoding: .utf8)
        else {
            NSLog("UBDispatcher: could not serialize event %@", type)
            return
        }
        UBWebSocket.shared.send(json)
    }
}

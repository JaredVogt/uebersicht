import Foundation

/// Subscribes to typed events coming from the widget server.
///
/// Drop-in replacement for the Obj-C `UBListener`. Registers exactly one
/// WebSocket listener at init time, routes incoming JSON events to per-type
/// callback arrays.
///
/// The payload is passed to callbacks as the parsed JSON value (usually a
/// `Dictionary<String, Any>`), matching the old behavior so Obj-C callers
/// like `UBWidgetsStore` keep working without casts.
@objc(UBListener)
@MainActor
public final class Listener: NSObject {

    private var listeners: [String: [(Any) -> Void]] = [:]

    public override init() {
        super.init()
        UBWebSocket.shared.listen { [weak self] message in
            self?.handle(message)
        }
    }

    @objc(on:do:)
    public func on(_ type: String, do callback: @escaping (Any) -> Void) {
        listeners[type, default: []].append(callback)
    }

    private func handle(_ message: Any) {
        let text: String
        switch message {
        case let s as String: text = s
        case let d as Data: text = String(data: d, encoding: .utf8) ?? ""
        default: return
        }
        guard
            let data = text.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = parsed["type"] as? String
        else { return }
        let payload = parsed["payload"] as Any? ?? NSNull()
        listeners[type]?.forEach { $0(payload) }
    }
}

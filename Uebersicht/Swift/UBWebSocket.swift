import Foundation

/// Drop-in replacement for the SocketRocket-backed `UBWebSocket`.
///
/// Same Obj-C surface the old implementation had (`sharedSocket`, `open:`,
/// `close`, `send:`, `listen:`). Internally uses `URLSessionWebSocketTask`,
/// which ships with the OS — no pod required.
///
/// Reconnect strategy mirrors the old behavior: on any failure or remote
/// close we wait 100ms and reopen. Cancellable via `close`.
@objc(UBWebSocket)
@MainActor
public final class UBWebSocket: NSObject {

    @objc(sharedSocket)
    public static let shared = UBWebSocket()

    private var task: URLSessionWebSocketTask?
    private var url: URL?
    private var listeners: [(Any) -> Void] = []
    private var queuedMessages: [Any] = []
    private var reconnectTask: Task<Void, Never>?
    private var receiveLoop: Task<Void, Never>?
    private var isOpen = false

    private let session = URLSession(configuration: .default)

    // MARK: - Obj-C API

    @objc(open:)
    public func open(_ aUrl: URL) {
        guard task == nil else { return }
        url = aUrl
        startTask(with: aUrl)
    }

    @objc public func close() {
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        url = nil
        isOpen = false
    }

    @objc(send:)
    public func send(_ message: Any) {
        if isOpen, let task {
            task.send(Self.wsMessage(from: message)) { [weak self] error in
                if error != nil {
                    Task { @MainActor [weak self] in self?.scheduleReopen() }
                }
            }
        } else {
            queuedMessages.append(message)
        }
    }

    @objc(listen:)
    public func listen(_ listener: @escaping (Any) -> Void) {
        listeners.append(listener)
    }

    // MARK: - Internals

    private func startTask(with aUrl: URL) {
        var request = URLRequest(url: aUrl)
        request.setValue("Uebersicht", forHTTPHeaderField: "Origin")
        let t = session.webSocketTask(with: request)
        task = t
        isOpen = true
        t.resume()
        flushQueue()
        startReceiveLoop(on: t)
    }

    private func flushQueue() {
        guard let task else { return }
        let pending = queuedMessages
        queuedMessages.removeAll()
        for message in pending {
            task.send(Self.wsMessage(from: message)) { _ in }
        }
    }

    private func startReceiveLoop(on task: URLSessionWebSocketTask) {
        receiveLoop?.cancel()
        receiveLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    let msg = try await task.receive()
                    guard let self else { return }
                    let decoded: Any
                    switch msg {
                    case .string(let s): decoded = s
                    case .data(let d): decoded = d
                    @unknown default: decoded = NSNull()
                    }
                    for listener in self.listeners { listener(decoded) }
                } catch {
                    self?.scheduleReopen()
                    return
                }
            }
        }
    }

    private func scheduleReopen() {
        guard let url else { return }
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        isOpen = false
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            self.startTask(with: url)
        }
    }

    private static func wsMessage(from any: Any) -> URLSessionWebSocketTask.Message {
        if let s = any as? String { return .string(s) }
        if let d = any as? Data { return .data(d) }
        if let obj = any as? NSString { return .string(obj as String) }
        if JSONSerialization.isValidJSONObject(any),
           let data = try? JSONSerialization.data(withJSONObject: any) {
            return .data(data)
        }
        return .string(String(describing: any))
    }
}

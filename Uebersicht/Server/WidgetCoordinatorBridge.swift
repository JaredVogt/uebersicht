import Foundation

/// Thin Obj-C wrapper around `WidgetCoordinator` so `UBAppDelegate.m` can
/// drive the in-process server without dragging `async/await` across the
/// bridge. Mirrors the surface the old `launchWidgetServer:` NSTask exposed
/// (start, stop, running-port lookup) plus the two callbacks the app delegate
/// needs: "server is up" and "server exited".
@objc(UBWidgetServerBridge)
@MainActor
public final class WidgetCoordinatorBridge: NSObject {

    @objc public private(set) var boundPort: UInt16 = 0

    private var coordinator: WidgetCoordinator?
    private let widgetDirectory: URL
    private let publicDirectory: URL
    private let settingsDirectory: URL
    private let loginShell: Bool

    @objc
    public init(
        widgetDirectory: URL,
        settingsDirectory: URL,
        loginShell: Bool
    ) {
        self.widgetDirectory = widgetDirectory
        self.settingsDirectory = settingsDirectory
        self.loginShell = loginShell
        // `public/` ships inside the app bundle as a folder reference, so it
        // lands at `.../Resources/public/`.
        self.publicDirectory = Bundle.main
            .resourceURL?
            .appendingPathComponent("public", isDirectory: true)
            ?? URL(fileURLWithPath: "/tmp/uebersicht-public-missing")
        super.init()
    }

    /// Starts the coordinator and invokes `onReady(boundPort)` once the HTTP
    /// listener is accepting connections, or `onExit(errorDescription)` if
    /// startup failed. Completion blocks dispatch on the main queue.
    @objc
    public func start(
        onReady: @escaping @Sendable (UInt16) -> Void,
        onExit: @escaping @Sendable (String?) -> Void
    ) {
        let coord = WidgetCoordinator(config: .init(
            widgetDirectory: widgetDirectory,
            publicDirectory: publicDirectory,
            settingsDirectory: settingsDirectory,
            loginShell: loginShell
        ))
        self.coordinator = coord

        Task { @MainActor in
            do {
                try await coord.start()
                let port = await coord.boundPort
                self.boundPort = port
                onReady(port)
            } catch {
                self.coordinator = nil
                onExit(String(describing: error))
            }
        }
    }

    @objc
    public func stop() {
        let coord = self.coordinator
        self.coordinator = nil
        Task { await coord?.stop() }
    }

    /// Fetches the state snapshot (`{widgets, settings, screens}`) for the
    /// initial `UBWidgetsStore.reset:` call. Completion on the main queue.
    @objc
    public func fetchState(completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let coord = self.coordinator else {
            completion([:])
            return
        }
        Task { @MainActor in
            let data = await coord.stateSnapshotData()
            let parsed = (try? JSONSerialization.jsonObject(
                with: data,
                options: [.mutableContainers]
            )) as? [String: Any] ?? [:]
            completion(parsed)
        }
    }
}

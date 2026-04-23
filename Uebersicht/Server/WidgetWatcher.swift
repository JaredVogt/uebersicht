import Foundation

/// Watches a widget directory for `*.jsx` changes and emits events as an
/// `AsyncStream`. Replaces the Node-side `directory_watcher.coffee` +
/// `fsevents` native module.
///
/// Uses the FSEvents C API (`FSEventStreamCreate`) because `DispatchSource`
/// file-descriptor watchers don't fire for subdirectory mutations on APFS
/// and don't reliably distinguish between create/rename/delete. FSEvents is
/// what the Node sidecar used before, so semantics line up.
///
/// Scope: only surfaces `.jsx` files. CoffeeScript is explicitly dropped as
/// part of the modernization. Non-widget files (`node_modules`, `lib`,
/// `src` subdirectories) are filtered here because the client bundler
/// already refuses to treat them as widgets.
public final class WidgetWatcher: @unchecked Sendable {

    public enum Event: Sendable, Equatable {
        case created(URL)
        case modified(URL)
        case removed(URL)
    }

    public let directory: URL

    private var stream: FSEventStreamRef?
    private var continuation: AsyncStream<Event>.Continuation?
    private let queue = DispatchQueue(label: "uebersicht.widget-watcher")

    public init(directory: URL) {
        self.directory = directory
    }

    deinit { stop() }

    /// Starts watching; returns an AsyncStream that terminates on `stop()`.
    public func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            self.continuation = continuation
            start()
            continuation.onTermination = { [weak self] _ in self?.stop() }
        }
    }

    private func start() {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let paths = [directory.path] as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
        )

        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(newStream, queue)
        FSEventStreamStart(newStream)
        stream = newStream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        continuation?.finish()
        continuation = nil
    }

    fileprivate func handle(path: String, flags: FSEventStreamEventFlags) {
        let url = URL(fileURLWithPath: path)
        guard shouldEmit(url: url) else { return }

        // FSEvents coalesces multiple kinds of events on the same path —
        // inspect flags and classify into create / modify / remove.
        let raw = Int(flags)
        if raw & kFSEventStreamEventFlagItemRemoved != 0 {
            continuation?.yield(.removed(url))
        } else if raw & kFSEventStreamEventFlagItemCreated != 0 {
            continuation?.yield(.created(url))
        } else if raw & (kFSEventStreamEventFlagItemModified
                         | kFSEventStreamEventFlagItemInodeMetaMod
                         | kFSEventStreamEventFlagItemRenamed) != 0 {
            continuation?.yield(.modified(url))
        }
    }

    private func shouldEmit(url: URL) -> Bool {
        guard url.pathExtension == "jsx" else { return false }
        let parts = url.pathComponents
        // Skip module-like directories; these are imports, not widgets.
        if parts.contains("node_modules") || parts.contains("lib") || parts.contains("src") {
            return false
        }
        return true
    }
}

// MARK: - FSEvents callback bridge

private func fsEventsCallback(
    streamRef: ConstFSEventStreamRef,
    info: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let watcher = Unmanaged<WidgetWatcher>.fromOpaque(info).takeUnretainedValue()
    let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
    for i in 0..<numEvents {
        watcher.handle(path: paths[i], flags: eventFlags[i])
    }
}

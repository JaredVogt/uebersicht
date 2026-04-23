import Testing
import Foundation
@testable import Uebersicht

/// Shape-level tests for WidgetWatcher. FSEvents integration tests are
/// pushed to the full PR 4 wiring pass — they need a watchable path
/// outside of `/private/var/folders` (FSEvents is unreliable there under
/// the test host's sandboxing on macOS 14+).
@Suite("WidgetWatcher")
struct WidgetWatcherTests {

    @Test("events() returns an AsyncStream that terminates on stop()")
    func streamTerminates() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uebersicht-watcher-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = WidgetWatcher(directory: dir)
        let stream = watcher.events()

        watcher.stop()

        var produced: [WidgetWatcher.Event] = []
        for await event in stream { produced.append(event) }
        // stop() finishes the continuation; the iterator returns without
        // yielding anything.
        #expect(produced.isEmpty)
    }
}

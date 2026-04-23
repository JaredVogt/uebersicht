import Foundation
import Darwin

/// Tracks rolling counters so the bundled Perf.jsx widget has real data to
/// render. The old Node sidecar had a similar collector; this is its Swift
/// analogue measuring the same things the widget knows how to display.
///
/// Rolling windows are computed lazily at query time from a ring-buffer of
/// (timestamp, value) samples. We only keep ~60s of history per metric —
/// enough for the 10s window Perf.jsx requests with room to spare.
public actor PerfCollector {

    // MARK: - Public API

    public func recordCommand(command: String, durationMs: Double, bytesOut: Int, widgetId: String?) {
        let now = Date().timeIntervalSince1970
        commandSamples.append(Sample(ts: now, value: 1))
        durationSamples.append(Sample(ts: now, value: durationMs))
        bytesOutSamples.append(Sample(ts: now, value: Double(bytesOut)))
        commandTotal += 1

        let key = String(command.prefix(200))
        var entry = commandStats[key] ?? CommandStats()
        entry.count += 1
        entry.totalDurationMs += durationMs
        entry.widgetId = widgetId ?? entry.widgetId
        commandStats[key] = entry

        trimOldSamples()
    }

    public func recordWsMessage(bytes: Int) {
        let now = Date().timeIntervalSince1970
        wsMessageSamples.append(Sample(ts: now, value: 1))
        wsBytesSamples.append(Sample(ts: now, value: Double(bytes)))
        wsMessageTotal += 1
        wsByteTotal += bytes
        trimOldSamples()
    }

    /// JSON-encoded snapshot — returning Data keeps `[String: Any]` from
    /// leaking across the actor boundary (Swift concurrency can't prove
    /// heterogeneous dictionaries are Sendable).
    public func snapshotData() -> Data {
        (try? JSONSerialization.data(withJSONObject: snapshot())) ?? Data("{}".utf8)
    }

    private func snapshot() -> [String: Any] {
        let now = Date().timeIntervalSince1970

        let cmd1s = countInLastSeconds(commandSamples, window: 1, now: now)
        let cmd10s = countInLastSeconds(commandSamples, window: 10, now: now)
        let bytes10s = sumInLastSeconds(bytesOutSamples, window: 10, now: now)
        let avgDur10s = averageInLastSeconds(durationSamples, window: 10, now: now)

        let wsMsg10s = countInLastSeconds(wsMessageSamples, window: 10, now: now)
        let wsBytes10s = sumInLastSeconds(wsBytesSamples, window: 10, now: now)

        let uptime = Int(now - startedAt)
        let rssMB = Self.residentSetSizeMB()

        let topCommands = commandStats
            .sorted { $0.value.count > $1.value.count }
            .prefix(8)
            .map { entry -> [String: Any] in
                let avgMs = entry.value.count > 0
                    ? Int(entry.value.totalDurationMs / Double(entry.value.count))
                    : 0
                return [
                    "command": entry.key,
                    "count": entry.value.count,
                    "avgMs": avgMs,
                    "widgetId": entry.value.widgetId as Any,
                ]
            }

        return [
            "uptimeSec": uptime,
            "commands": [
                "last1s": cmd1s,
                "last10s": cmd10s,
                "bytesPerSec10s": Int(bytes10s / 10),
                "avgDurationMs10s": Int(avgDur10s),
                "total": commandTotal,
                "topCommands": topCommands,
            ] as [String: Any],
            "websocket": [
                "msgPerSec10s": wsMsg10s / 10,
                "bytesPerSec10s": Int(wsBytes10s / 10),
                "total": wsMessageTotal,
            ] as [String: Any],
            // `node` is named for the widget's existing table layout; with
            // the Node sidecar gone, the numbers refer to our in-process
            // app. Heap fields are zero because Swift doesn't expose
            // per-heap stats the same way V8 did.
            "node": [
                "rssMB": rssMB,
                "heapUsedMB": 0,
                "heapTotalMB": 0,
            ] as [String: Any],
        ]
    }

    // MARK: - Internals

    private struct Sample: Sendable { let ts: Double; let value: Double }
    private struct CommandStats: Sendable { var count = 0; var totalDurationMs = 0.0; var widgetId: String? = nil }

    private let startedAt: Double = Date().timeIntervalSince1970
    private var commandSamples: [Sample] = []
    private var durationSamples: [Sample] = []
    private var bytesOutSamples: [Sample] = []
    private var wsMessageSamples: [Sample] = []
    private var wsBytesSamples: [Sample] = []
    private var commandStats: [String: CommandStats] = [:]
    private var commandTotal = 0
    private var wsMessageTotal = 0
    private var wsByteTotal = 0

    // Drop samples older than 60 s. Called inline on every record; cheap
    // because the buffers are bounded by traffic rate × 60 and we only pop
    // from the front.
    private func trimOldSamples() {
        let cutoff = Date().timeIntervalSince1970 - 60
        trimFront(&commandSamples, cutoff: cutoff)
        trimFront(&durationSamples, cutoff: cutoff)
        trimFront(&bytesOutSamples, cutoff: cutoff)
        trimFront(&wsMessageSamples, cutoff: cutoff)
        trimFront(&wsBytesSamples, cutoff: cutoff)
    }

    private func trimFront(_ samples: inout [Sample], cutoff: Double) {
        var drop = 0
        while drop < samples.count && samples[drop].ts < cutoff { drop += 1 }
        if drop > 0 { samples.removeFirst(drop) }
    }

    private func countInLastSeconds(_ samples: [Sample], window: Double, now: Double) -> Int {
        let since = now - window
        var count = 0
        for s in samples.reversed() {
            if s.ts < since { break }
            count += Int(s.value)
        }
        return count
    }

    private func sumInLastSeconds(_ samples: [Sample], window: Double, now: Double) -> Double {
        let since = now - window
        var sum: Double = 0
        for s in samples.reversed() {
            if s.ts < since { break }
            sum += s.value
        }
        return sum
    }

    private func averageInLastSeconds(_ samples: [Sample], window: Double, now: Double) -> Double {
        let since = now - window
        var sum: Double = 0
        var count = 0
        for s in samples.reversed() {
            if s.ts < since { break }
            sum += s.value
            count += 1
        }
        return count == 0 ? 0 : sum / Double(count)
    }

    /// Process resident-set-size in MB. Uses `task_info` with the basic
    /// info flavor — same numbers Activity Monitor shows.
    private static func residentSetSizeMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ptr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), ptr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size / (1024 * 1024))
    }
}

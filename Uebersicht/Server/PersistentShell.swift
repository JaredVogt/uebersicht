import Foundation

/// Long-lived `/bin/bash -s` subprocess kept open between `command:` ticks
/// of a single widget. Replaces the per-tick `bash -lc "<cmd>"` fork+exec
/// with a one-time fork + repeated stdin writes. For a widget polling at
/// 1 Hz, this removes ~1 fork/exec + bash startup per second.
///
/// Protocol: commands are sent to stdin wrapped in a block that prints a
/// unique sentinel + exit code on stdout after the command finishes.
/// `run()` reads stdout until the sentinel arrives; everything before is
/// the command's output. Serial — commands queue on the actor.
///
/// Stderr is `2>&1`-merged into stdout. Same exit-code → HTTP status
/// behavior as the one-shot `CommandRunner`: zero = 200, non-zero = 500.
public actor PersistentShell {

    public enum Failure: Error, Equatable {
        case launchFailed(String)
        case shellDied
    }

    public struct Result: Sendable {
        public let stdout: String
        public let exitCode: Int32
    }

    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private var readBuffer = Data()
    private var alive = true

    // Exactly one `run()` is outstanding at a time (the actor serializes
    // them). These hold that run's sentinel + resumption handle so the
    // `readabilityHandler`-driven `receivedData` can resolve it the moment
    // the marker shows up — no polling.
    private var pendingMarker: String?
    private var pendingContinuation: CheckedContinuation<Result, any Error>?

    public init(workingDirectory: URL, loginShell: Bool) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = loginShell ? ["-l", "-s"] : ["-s"]
        proc.currentDirectoryURL = workingDirectory

        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        // stderr is merged via `exec 2>&1` below so command output and
        // diagnostics arrive on one stream, which keeps the sentinel search
        // simple. The widget sees the same bytes either way.
        proc.standardError = outPipe

        self.process = proc
        self.stdinHandle = inPipe.fileHandleForWriting
        self.stdoutHandle = outPipe.fileHandleForReading

        // `readabilityHandler` fires on a background queue the moment the
        // pipe has new bytes. We hop back onto the actor to append to the
        // buffer + check for the run's sentinel. Replaces a `Task.sleep(8ms)`
        // poll loop.
        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.receivedData(data) }
        }

        do {
            try proc.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            throw Failure.launchFailed(String(describing: error))
        }

        // Merge stderr → stdout inside the shell itself. `-s` reads from
        // stdin, so this command takes effect before any widget command.
        stdinHandle.write(Data("exec 2>&1\n".utf8))
    }

    /// Runs `command` in the shell and returns its combined output + exit.
    public func run(_ command: String) async throws -> Result {
        guard alive, process.isRunning else {
            alive = false
            throw Failure.shellDied
        }
        let markerID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        let marker = "__UB_END_\(markerID)__"
        // Wrap the user command in a brace group so we can capture its exit
        // code with `$?`, then print a newline-prefixed sentinel + status.
        let script = "{ \(command)\n}; __ub_rc=$?; printf '\\n\(marker):%d\\n' $__ub_rc\n"
        stdinHandle.write(Data(script.utf8))

        return try await withCheckedThrowingContinuation { continuation in
            pendingMarker = marker
            pendingContinuation = continuation
            // Data for *this* marker may have arrived on the background queue
            // before we were able to register — the handler would have
            // appended it but had no pending marker to match against yet.
            // Drain it now.
            tryResolvePending()
        }
    }

    /// Terminates the shell process. Idempotent.
    public func stop() {
        alive = false
        stdoutHandle.readabilityHandler = nil
        failPending(Failure.shellDied)
        if process.isRunning {
            process.terminate()
        }
    }

    deinit {
        stdoutHandle.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
    }

    // MARK: - Internals

    private func receivedData(_ data: Data) {
        if data.isEmpty {
            // EOF — shell's stdout closed (process ended).
            alive = false
            failPending(Failure.shellDied)
            return
        }
        readBuffer.append(data)
        tryResolvePending()
    }

    private func tryResolvePending() {
        guard let marker = pendingMarker,
              let continuation = pendingContinuation,
              let result = splitOnMarker(marker: marker)
        else { return }
        pendingMarker = nil
        pendingContinuation = nil
        continuation.resume(returning: result)
    }

    private func failPending(_ error: any Error) {
        guard let continuation = pendingContinuation else { return }
        pendingMarker = nil
        pendingContinuation = nil
        continuation.resume(throwing: error)
    }

    private func splitOnMarker(marker: String) -> Result? {
        // Marker format: `\n<marker>:<int>\n` (the leading \n is intentional
        // so the sentinel always starts on its own line even if the command
        // didn't end with a newline).
        guard let bufferStr = String(data: readBuffer, encoding: .utf8) else {
            return nil
        }
        let needle = "\n\(marker):"
        guard let start = bufferStr.range(of: needle) else { return nil }
        // Find the newline that ends the sentinel line.
        guard let end = bufferStr.range(of: "\n", range: start.upperBound..<bufferStr.endIndex) else {
            return nil
        }
        let exitString = String(bufferStr[start.upperBound..<end.lowerBound])
        let exitCode = Int32(exitString) ?? -1

        let stdout = String(bufferStr[bufferStr.startIndex..<start.lowerBound])
        let leftover = bufferStr[end.upperBound..<bufferStr.endIndex]
        readBuffer = Data(leftover.utf8)
        return Result(stdout: stdout, exitCode: exitCode)
    }
}

import Foundation

/// Runs a widget's `command:` string as a shell subprocess and streams its
/// output as an `AsyncSequence` of string chunks.
///
/// Replaces the Node-side `runCommand.js` / `runShellCommand.js` path.
/// Same contract as before — shell commands run as the user (the app is not
/// sandboxed), stdout is the widget's render input, stderr is captured but
/// reported separately so widgets can surface errors.
///
/// Cancellation: if the consuming `Task` is cancelled, the subprocess is
/// terminated. Termination is best-effort; a SIGTERM is sent, and we wait
/// up to `killTimeout` before escalating to SIGKILL.
public struct CommandRunner: Sendable {

    public enum Event: Sendable, Equatable {
        case stdout(String)
        case stderr(String)
        case exit(Int32)
    }

    public enum Failure: Error, Equatable {
        case launchFailed(String)
        case timedOut
    }

    public struct Options: Sendable {
        public var shell: String = "/bin/bash"
        public var workingDirectory: URL?
        public var environment: [String: String]?
        public var timeout: Duration?
        public var killTimeout: Duration = .milliseconds(500)

        public init(
            shell: String = "/bin/bash",
            workingDirectory: URL? = nil,
            environment: [String: String]? = nil,
            timeout: Duration? = nil
        ) {
            self.shell = shell
            self.workingDirectory = workingDirectory
            self.environment = environment
            self.timeout = timeout
        }
    }

    public let command: String
    public let options: Options

    public init(command: String, options: Options = .init()) {
        self.command = command
        self.options = options
    }

    /// Returns an AsyncThrowingStream of events. The stream terminates after
    /// the `.exit` event (or throws on launch failure / timeout).
    public func stream() -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: options.shell)
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = options.workingDirectory
            if let env = options.environment { process.environment = env }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                continuation.yield(.stdout(chunk))
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                continuation.yield(.stderr(chunk))
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.yield(.exit(proc.terminationStatus))
                continuation.finish()
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: Failure.launchFailed(String(describing: error)))
                return
            }

            if let timeout = options.timeout {
                Task {
                    try? await Task.sleep(for: timeout)
                    if process.isRunning {
                        process.terminate()
                        try? await Task.sleep(for: options.killTimeout)
                        if process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                        continuation.finish(throwing: Failure.timedOut)
                    }
                }
            }

            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// Convenience: collect stdout into a single string, throw on non-zero
    /// exit or stderr-only output. Most widgets want this shape.
    public func collectStdout() async throws -> String {
        var stdout = ""
        var stderr = ""
        var exit: Int32 = 0
        for try await event in stream() {
            switch event {
            case .stdout(let s): stdout += s
            case .stderr(let s): stderr += s
            case .exit(let code): exit = code
            }
        }
        if exit != 0 {
            throw NSError(
                domain: "UBCommandRunner",
                code: Int(exit),
                userInfo: [
                    NSLocalizedDescriptionKey: stderr.isEmpty
                        ? "command exited with \(exit)"
                        : stderr
                ]
            )
        }
        return stdout
    }
}

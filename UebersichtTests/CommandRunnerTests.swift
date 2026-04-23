import Testing
import Foundation
@testable import Uebersicht

@Suite("CommandRunner")
struct CommandRunnerTests {

    @Test("stdout is streamed and exit code is surfaced")
    func basicStdout() async throws {
        let runner = CommandRunner(command: "echo 'hello widget'")
        var chunks: [String] = []
        var exit: Int32?
        for try await event in runner.stream() {
            switch event {
            case .stdout(let s): chunks.append(s)
            case .stderr: break
            case .exit(let code): exit = code
            }
        }
        #expect(chunks.joined().contains("hello widget"))
        #expect(exit == 0)
    }

    @Test("non-zero exit is reported via collectStdout throw")
    func nonZeroExit() async {
        let runner = CommandRunner(command: "exit 7")
        await #expect(throws: (any Error).self) {
            _ = try await runner.collectStdout()
        }
    }

    @Test("stderr is separated from stdout")
    func stderrSeparate() async throws {
        let runner = CommandRunner(command: "echo good; echo bad >&2")
        var out = ""
        var err = ""
        for try await event in runner.stream() {
            switch event {
            case .stdout(let s): out += s
            case .stderr(let s): err += s
            case .exit: break
            }
        }
        #expect(out.contains("good"))
        #expect(err.contains("bad"))
    }

    @Test("timeout terminates a long-running command")
    func timeout() async throws {
        var opts = CommandRunner.Options()
        opts.timeout = .milliseconds(200)
        let runner = CommandRunner(command: "sleep 5", options: opts)

        let started = Date()
        // The timeout path can finish the stream either via the terminate()
        // → termination handler branch (non-throwing) or via the explicit
        // finish(throwing: .timedOut) branch. The invariant we actually
        // care about is "the process was killed long before the sleep
        // would have completed" — assert on elapsed time.
        do {
            for try await _ in runner.stream() {}
        } catch {
            // swallow; either shape is fine
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 3.0, "timeout should fire well under the 5s sleep")
    }
}

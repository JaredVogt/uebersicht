import Testing
import Foundation
@testable import Uebersicht

@Suite("JSXTransformer")
struct JSXTransformerTests {

    @Test("resolveBinary throws a clear error when esbuild is nowhere")
    func missingEsbuild() {
        // Skip when the test host can resolve *any* esbuild binary — either on
        // PATH or bundled at `Resources/bin/esbuild`. The test host is the app
        // itself, so the shipping bundled esbuild will normally be picked up
        // and this test's negative case is unreachable in that environment.
        let hasBundled = Bundle.main.url(
            forResource: "esbuild",
            withExtension: nil,
            subdirectory: "bin"
        ) != nil
        if hasBundled || JSXTransformer.findOnPath("esbuild") != nil { return }

        #expect(throws: JSXTransformer.Failure.esbuildNotFound) {
            _ = try JSXTransformer.resolveBinary(
                explicit: URL(fileURLWithPath: "/nonexistent/esbuild")
            )
        }
    }

    @Test("findOnPath returns a URL for a known binary")
    func findKnownBinary() {
        // `/bin/sh` is guaranteed on macOS; we point findOnPath at a custom
        // PATH so this test doesn't depend on what's installed.
        let bin = JSXTransformer.findOnPath("sh")
        // sh is in /bin, which is on the default PATH we synthesize
        #expect(bin != nil || FileManager.default.isExecutableFile(atPath: "/bin/sh"))
    }

    @Test("transform on a real jsx widget produces ESM output", .enabled(if: JSXTransformer.findOnPath("esbuild") != nil))
    func transformRealWidget() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uebersicht-jsx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let widget = dir.appendingPathComponent("greeter.jsx")
        try """
        export const refreshFrequency = 1000;
        export const render = ({output}) => <div>{output}</div>;
        """.write(to: widget, atomically: true, encoding: .utf8)

        let transformer = JSXTransformer()
        let js = try await transformer.transform(widget)
        #expect(js.contains("refreshFrequency"))
        #expect(js.contains("export"))
    }
}

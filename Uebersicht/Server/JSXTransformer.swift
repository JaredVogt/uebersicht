import Foundation

/// Transforms a widget source file (`.jsx`) into a browser-ready ES module
/// by shelling out to `esbuild`. Replaces the Browserify + Babel pipeline
/// from the old Node sidecar (`server/src/bundleWidget.js`).
///
/// Why esbuild: single static Go binary, 10× faster than Browserify, MIT,
/// handles JSX + bundle + source maps + tree shaking with one process
/// invocation. No JS runtime required on our side.
///
/// Binary resolution order:
/// 1. Explicit path passed into `Options.binaryPath`.
/// 2. Bundled at `<App>.app/Contents/Resources/bin/esbuild` (populated by
///    the `fetch-esbuild.sh` build script).
/// 3. `esbuild` on `PATH`.
///
/// If none of those resolve, `transform` throws `Failure.esbuildNotFound`
/// with an actionable install hint.
public struct JSXTransformer: Sendable {

    public enum Failure: Error, Equatable {
        case esbuildNotFound
        case transformFailed(String)
    }

    public struct Options: Sendable {
        public var binaryPath: URL?
        public var sourceMap: Bool = true
        public var target: String = "safari16"
        public var format: String = "esm"
        /// Matches the old Babel `pragma: 'html'` setup where widgets use
        /// `html(...)` (an alias for `React.createElement`) rather than the
        /// automatic JSX runtime. Avoids needing to resolve `react/jsx-runtime`
        /// in the bundle.
        public var jsxFactory: String = "html"
        public var jsxFragment: String = "Fragment"
        /// `uebersicht` is provided by the host client (exports run/request/
        /// css/styled/React). Widgets must import from `uebersicht`; direct
        /// `import React from 'react'` is no longer supported — the client
        /// bundle doesn't expose `react` as its own module anymore.
        public var externalModules: [String] = ["uebersicht"]

        public init(
            binaryPath: URL? = nil,
            sourceMap: Bool = true,
            target: String = "safari16",
            format: String = "esm",
            jsxFactory: String = "html",
            jsxFragment: String = "Fragment",
            externalModules: [String]? = nil
        ) {
            self.binaryPath = binaryPath
            self.sourceMap = sourceMap
            self.target = target
            self.format = format
            self.jsxFactory = jsxFactory
            self.jsxFragment = jsxFragment
            if let externalModules { self.externalModules = externalModules }
        }
    }

    public let options: Options

    public init(options: Options = .init()) {
        self.options = options
    }

    /// Bundles the widget at `sourceURL` and returns the JavaScript as UTF-8
    /// text. The result is a complete ES module containing the widget and
    /// all its internal dependencies, minus anything in `externalModules`.
    public func transform(_ sourceURL: URL) async throws -> String {
        let binary = try Self.resolveBinary(explicit: options.binaryPath)

        var args = [
            "--bundle",
            "--format=\(options.format)",
            "--target=\(options.target)",
            "--loader:.jsx=jsx",
            "--loader:.js=jsx",
            "--jsx=transform",
            "--jsx-factory=\(options.jsxFactory)",
            "--jsx-fragment=\(options.jsxFragment)",
            sourceURL.path
        ]
        if options.sourceMap { args.append("--sourcemap=inline") }
        for ext in options.externalModules { args.append("--external:\(ext)") }

        let process = Process()
        process.executableURL = binary
        process.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? "unknown error"
            throw Failure.transformFailed(msg)
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    // MARK: - Binary resolution

    static func resolveBinary(explicit: URL?) throws -> URL {
        if let explicit, FileManager.default.isExecutableFile(atPath: explicit.path) {
            return explicit
        }
        if let bundled = Bundle.main.url(forResource: "esbuild", withExtension: nil, subdirectory: "bin"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        if let onPath = Self.findOnPath("esbuild") {
            return onPath
        }
        throw Failure.esbuildNotFound
    }

    static func findOnPath(_ name: String) -> URL? {
        let env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

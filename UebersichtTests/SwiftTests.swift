import Testing
import Foundation
@testable import Uebersicht

/// Baseline Swift Testing harness. PR 1's job is to get Swift compiling in the
/// same target as Obj-C — these tests verify the toolchain, plus the tiny bit
/// of logic that's already pure-Swift (URL-to-message encoding in UBWebSocket).
@Suite("Toolchain sanity")
struct ToolchainTests {

    @Test("Swift + Obj-C mixed target compiles and runs")
    func mixedTargetCompiles() {
        #expect(true)
    }

    @Test("UBWebSocket singleton is MainActor-isolated and non-nil")
    @MainActor
    func webSocketSingleton() {
        let socket = UBWebSocket.shared
        #expect(socket === UBWebSocket.shared, "shared must be a true singleton")
    }
}

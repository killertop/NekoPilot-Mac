import Testing
@testable import NekoPilotCore

@Suite("Typed engine failures")
struct EngineFailureTests {
    @Test("Legacy string factories preserve text with a typed fallback kind")
    func legacyFactoriesRemainCompatible() {
        let status = EngineStatus.failed("legacy status")
        let error = NekoPilotError.processFailed("legacy error")

        #expect(status == .failed(EngineFailure(kind: .operation, message: "legacy status")))
        #expect(error == .processFailed(EngineFailure(kind: .operation, message: "legacy error")))
        #expect(error.localizedDescription == "legacy error")
    }

    @Test("Failure kinds distinguish cleanup from core exit")
    func failureKindsAreActionable() {
        let cleanup = EngineFailure(kind: .systemProxy, message: "restore failed")
        let exit = EngineFailure(kind: .unexpectedExit, message: "core exited")

        #expect(cleanup.kind == .systemProxy)
        #expect(exit.kind == .unexpectedExit)
        #expect(cleanup != exit)
    }
}

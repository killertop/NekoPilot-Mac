import Testing
@testable import NekoPilotCore

@Suite("Typed engine failures")
struct EngineFailureTests {
    @Test("Legacy string cases remain pattern-match compatible")
    func legacyCasesRemainCompatible() {
        let status = EngineStatus.failed("legacy status")
        let error = NekoPilotError.processFailed("legacy error")

        guard case let .failed(statusMessage) = status else {
            Issue.record("Expected the source-compatible failed(String) case")
            return
        }
        guard case let .processFailed(errorMessage) = error else {
            Issue.record("Expected the source-compatible processFailed(String) case")
            return
        }

        #expect(statusMessage == "legacy status")
        #expect(errorMessage == "legacy error")
        #expect(error.localizedDescription == "legacy error")
    }

    @Test("Typed failures retain categories while projecting unchanged UI text")
    func failureKindsAreActionable() throws {
        let cleanup = EngineFailure(kind: .systemProxy, message: "restore failed")
        let exit = EngineFailure(kind: .unexpectedExit, message: "core exited")
        let projectedStatus = EngineStatus.failed(cleanup)

        #expect(cleanup.kind == .systemProxy)
        #expect(exit.kind == .unexpectedExit)
        #expect(cleanup != exit)
        #expect(cleanup.localizedDescription == "restore failed")
        #expect(projectedStatus == .failed("restore failed"))

        do {
            throw exit
        } catch let failure as EngineFailure {
            #expect(failure.kind == .unexpectedExit)
            #expect(failure.message == "core exited")
        }
    }

    @Test("Reload recovery changes only after candidate commit")
    func reloadRecoveryUsesCommitBoundary() {
        let controlError = NekoPilotError.processFailed("control unavailable")
        let beforeCommit = EngineSupervisor.classifyReloadFailure(
            controlError,
            candidateWasCommitted: false
        )
        let afterCommit = EngineSupervisor.classifyReloadFailure(
            controlError,
            candidateWasCommitted: true
        )

        #expect(beforeCommit as? NekoPilotError == controlError)
        #expect((afterCommit as? EngineFailure)?.kind == .reloadCommitted)
        #expect((afterCommit as? EngineFailure)?.message == "control unavailable")
    }
}

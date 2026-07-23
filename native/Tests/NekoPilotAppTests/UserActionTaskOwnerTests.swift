@testable import NekoPilot
import NekoPilotCore
import Testing

@Suite("User action task ownership and recovery")
struct UserActionTaskOwnerTests {
    @MainActor
    @Test("Cancellation waits until an active operation has finished")
    func testCancellationWaitsForActiveOperation() async {
        let owner = UserActionTaskOwner()
        let probe = CancellationProbe()

        owner.submit {
            await probe.markStarted()
            while !Task.isCancelled {
                await Task.yield()
            }
            await probe.markFinished()
        }

        await probe.waitUntilStarted()
        #expect(owner.activeCount == 1)
        await owner.cancelAndWait()
        #expect(owner.activeCount == 0)
        let finished = await probe.isFinished
        #expect(finished)
    }

    @Test("Cancellation never rolls back durable rules")
    func testCancellationNeverRollsBackDurableRules() {
        #expect(AppRuntimeRecoveryPolicy.keepsPersistedRules(
            after: CancellationError(),
            didPersist: true
        ))
        #expect(!AppRuntimeRecoveryPolicy.keepsPersistedRules(
            after: CancellationError(),
            didPersist: false
        ))
    }

    @Test("Committed reload ambiguity never rolls back durable rules")
    func testCommittedReloadAmbiguityNeverRollsBackDurableRules() {
        let committed = EngineFailure(kind: .reloadCommitted, message: "confirmation lost")
        let preflight = EngineFailure(kind: .reload, message: "candidate unhealthy")

        #expect(AppRuntimeRecoveryPolicy.keepsPersistedRules(
            after: committed,
            didPersist: true
        ))
        #expect(!AppRuntimeRecoveryPolicy.keepsPersistedRules(
            after: committed,
            didPersist: false
        ))
        #expect(!AppRuntimeRecoveryPolicy.keepsPersistedRules(
            after: preflight,
            didPersist: true
        ))
    }

    @MainActor
    @Test("Cancelled import post-processing stops before reload and selection")
    func testCancelledImportPostprocessingStopsSideEffects() async {
        let probe = ImportedNodeWorkflowProbe()
        let operation = Task { @MainActor in
            try await ImportedNodePostprocessor.run(
                refresh: { await probe.refreshAndWait() },
                resolveNode: {
                    probe.record("resolve")
                    return 1
                },
                isEngineRunning: {
                    probe.record("status")
                    return true
                },
                reload: { _ in probe.record("reload") },
                select: { _ in probe.record("select") },
                isShuttingDown: { false }
            )
        }

        await probe.waitUntilRefreshStarted()
        operation.cancel()
        probe.releaseRefresh()
        do {
            try await operation.value
            Issue.record("Cancelled post-processing reported success")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
        #expect(probe.events == ["refresh"])
    }
}

private actor CancellationProbe {
    private var started = false
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isFinished: Bool { finished }

    func markStarted() {
        started = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func markFinished() {
        finished = true
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

@MainActor
private final class ImportedNodeWorkflowProbe {
    private(set) var events: [String] = []
    private var refreshStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var refreshRelease: CheckedContinuation<Void, Never>?

    func record(_ event: String) {
        events.append(event)
    }

    func refreshAndWait() async {
        record("refresh")
        refreshStarted = true
        let pending = startWaiters
        startWaiters.removeAll()
        pending.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            refreshRelease = continuation
        }
    }

    func waitUntilRefreshStarted() async {
        guard !refreshStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseRefresh() {
        refreshRelease?.resume()
        refreshRelease = nil
    }
}

import Foundation
import Testing
@testable import NekoPilotCore

@Suite("Node selection coordination", .serialized)
struct NodeSelectionCoordinatorTests {
    @Test("Superseded in-flight selections never publish stale UI state")
    func coalescesRapidSelections() async throws {
        let probe = SelectionProbe()
        let coordinator = NodeSelectionCoordinator(
            applySelection: { node in try await probe.apply(node) },
            persistSelection: { node in
                guard let node else { return }
                await probe.persist(node)
            }
        )
        let updates = await coordinator.selections()
        let published = Task { () -> String? in
            for await node in updates { return node }
            return nil
        }

        let first = Task { try await coordinator.submit(node: "A") }
        await probe.waitUntilFirstStarted()
        let second = Task { try await coordinator.submit(node: "B") }
        let third = Task { try await coordinator.submit(node: "C") }
        while await coordinator.pendingNodeForTesting != "C" { await Task.yield() }
        await probe.releaseFirst()

        _ = try await first.value
        _ = try await second.value
        _ = try await third.value
        let publishedNode = await published.value
        let persisted = await probe.persisted
        let applied = await probe.applied
        #expect(publishedNode == "C")
        #expect(persisted == ["C"])
        #expect(applied == ["A", "C"])
    }

    @Test("Failover cannot supersede an active manual choice")
    func manualSelectionHasPriority() async throws {
        let probe = SelectionProbe()
        let coordinator = NodeSelectionCoordinator(
            applySelection: { node in try await probe.apply(node) },
            persistSelection: { node in
                guard let node else { return }
                await probe.persist(node)
            }
        )

        let manual = Task { try await coordinator.submit(node: "A") }
        await probe.waitUntilFirstStarted()
        let failoverApplied = try await coordinator.submitFailover(node: "B")
        await probe.releaseFirst()
        #expect(failoverApplied == false)
        #expect(try await manual.value == true)

        #expect(await probe.applied == ["A"])
        #expect(await probe.persisted == ["A"])
    }

    @Test("A manual choice supersedes a failover already in flight")
    func manualSelectionWinsAfterFailoverStarts() async throws {
        let probe = SelectionProbe()
        let coordinator = NodeSelectionCoordinator(
            applySelection: { node in try await probe.apply(node) },
            persistSelection: { node in
                guard let node else { return }
                await probe.persist(node)
            }
        )

        let failover = Task { try await coordinator.submitFailover(node: "A") }
        await probe.waitUntilFirstStarted()
        let manual = Task { try await coordinator.submit(node: "C") }
        while await coordinator.pendingNodeForTesting != "C" { await Task.yield() }
        await probe.releaseFirst()

        #expect(try await failover.value == false)
        #expect(try await manual.value == true)
        #expect(await probe.applied == ["A", "C"])
        #expect(await probe.persisted == ["C"])
    }

    @Test("A disabled coordinator rejects failover without touching runtime state")
    func disabledCoordinatorRejectsFailover() async throws {
        let probe = SelectionProbe()
        let coordinator = NodeSelectionCoordinator(
            applySelection: { node in try await probe.apply(node) },
            persistSelection: { node in
                guard let node else { return }
                await probe.persist(node)
            }
        )

        await coordinator.setAutomaticSwitchingEnabled(false)
        let applied = try await coordinator.submitFailover(node: "B")

        #expect(applied == false)
        #expect(await probe.applied.isEmpty)
        #expect(await probe.persisted.isEmpty)
    }

    @Test("Disabling automatic switching lets a manual choice take over an in-flight failover")
    func disablingAutomaticSwitchingRestoresManualPriority() async throws {
        let probe = SelectionProbe()
        let coordinator = NodeSelectionCoordinator(
            applySelection: { node in try await probe.apply(node) },
            persistSelection: { node in
                guard let node else { return }
                await probe.persist(node)
            }
        )

        let failover = Task { try await coordinator.submitFailover(node: "A") }
        await probe.waitUntilFirstStarted()
        await coordinator.setAutomaticSwitchingEnabled(false)
        let manual = Task { try await coordinator.submit(node: "C") }
        while await coordinator.pendingNodeForTesting != "C" { await Task.yield() }
        await probe.releaseFirst()

        #expect(try await failover.value == false)
        #expect(try await manual.value == true)
        #expect(await probe.applied == ["A", "C"])
        #expect(await probe.persisted == ["C"])
    }

    @Test("Disabling during persistence rolls back the failover choice")
    func disablingAutomaticSwitchingDuringPersistenceRollsBack() async throws {
        let probe = PersistenceGateProbe()
        let coordinator = NodeSelectionCoordinator(
            applySelection: { node in await probe.apply(node) },
            persistSelection: { node in
                guard let node else { return }
                await probe.persist(node)
            },
            loadPersistedSelection: { "Previous" }
        )

        let failover = Task { try await coordinator.submitFailover(node: "A") }
        await probe.waitUntilFirstPersistenceStarted()
        await coordinator.setAutomaticSwitchingEnabled(false)
        await probe.releaseFirstPersistence()

        #expect(try await failover.value == false)
        #expect(await probe.applied == ["A", "Previous"])
        #expect(await probe.persisted == ["A", "Previous"])
    }

    @Test("Cancelling an in-flight failover rolls back its runtime change")
    func cancellingFailoverRollsBackRuntime() async {
        let probe = SelectionProbe()
        let coordinator = NodeSelectionCoordinator(
            applySelection: { node in try await probe.apply(node) },
            persistSelection: { node in
                guard let node else { return }
                await probe.persist(node)
            },
            loadPersistedSelection: { "Previous" }
        )

        let failover = Task { try await coordinator.submitFailover(node: "A") }
        await probe.waitUntilFirstStarted()
        failover.cancel()
        while !(await coordinator.activeRequestCancelledForTesting) { await Task.yield() }
        await probe.releaseFirst()

        do {
            _ = try await failover.value
            Issue.record("Expected failover cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
        #expect(await probe.applied == ["A", "Previous"])
        #expect(await probe.persisted.isEmpty)
    }

    @Test("A superseded persisted failover is restored before a failing manual choice")
    func supersededPersistedFailoverDoesNotSurviveManualFailure() async throws {
        let probe = SupersededPersistenceProbe()
        let coordinator = NodeSelectionCoordinator(
            applySelection: { node in try await probe.apply(node) },
            persistSelection: { node in await probe.persist(node) },
            loadPersistedSelection: { await probe.persistedNode }
        )

        let failover = Task { try await coordinator.submitFailover(node: "Failover") }
        await probe.waitUntilFirstPersistenceStarted()
        let manual = Task { try await coordinator.submit(node: "Manual") }
        while await coordinator.pendingNodeForTesting != "Manual" { await Task.yield() }
        await probe.releaseFirstPersistence()

        #expect(try await failover.value == false)
        do {
            _ = try await manual.value
            Issue.record("Expected the manual engine call to fail")
        } catch {
            #expect(error as? NekoPilotError == .processFailed("manual apply failed"))
        }
        #expect(await probe.persistedNode == "Previous")
        #expect(await probe.persisted == ["Failover", "Previous"])
        #expect(await probe.applied == ["Failover", "Previous", "Manual", "Previous"])
    }

    @Test("A persistence failure restores the last committed runtime node")
    func persistenceFailureRollsBackRuntime() async {
        let probe = SelectionProbe()
        let coordinator = NodeSelectionCoordinator(
            applySelection: { node in try await probe.apply(node) },
            persistSelection: { _ in throw NekoPilotError.processFailed("disk unavailable") },
            loadPersistedSelection: { "Previous" }
        )

        do {
            try await coordinator.submit(node: "Next")
            Issue.record("Expected persistence to fail")
        } catch {
            #expect(error as? NekoPilotError == .processFailed("disk unavailable"))
        }
        #expect(await probe.applied == ["Next", "Previous"])
        #expect(await probe.persisted.isEmpty)
    }
}

private actor SupersededPersistenceProbe {
    private(set) var applied: [String] = []
    private(set) var persisted: [String] = []
    private(set) var persistedNode: String? = "Previous"
    private var firstPersistenceStarted = false
    private var firstPersistenceWaiter: CheckedContinuation<Void, Never>?
    private var firstPersistenceGate: CheckedContinuation<Void, Never>?

    func apply(_ node: String) async throws {
        applied.append(node)
        if node == "Manual" {
            throw NekoPilotError.processFailed("manual apply failed")
        }
    }

    func persist(_ node: String?) async {
        persistedNode = node
        persisted.append(node ?? "<nil>")
        guard !firstPersistenceStarted else { return }
        firstPersistenceStarted = true
        firstPersistenceWaiter?.resume()
        firstPersistenceWaiter = nil
        await withCheckedContinuation { firstPersistenceGate = $0 }
    }

    func waitUntilFirstPersistenceStarted() async {
        if firstPersistenceStarted { return }
        await withCheckedContinuation { firstPersistenceWaiter = $0 }
    }

    func releaseFirstPersistence() {
        firstPersistenceGate?.resume()
        firstPersistenceGate = nil
    }
}

private actor PersistenceGateProbe {
    private(set) var applied: [String] = []
    private(set) var persisted: [String] = []
    private var firstPersistenceStarted = false
    private var firstPersistenceWaiter: CheckedContinuation<Void, Never>?
    private var firstPersistenceGate: CheckedContinuation<Void, Never>?

    func apply(_ node: String) {
        applied.append(node)
    }

    func persist(_ node: String) async {
        persisted.append(node)
        guard !firstPersistenceStarted else { return }
        firstPersistenceStarted = true
        firstPersistenceWaiter?.resume()
        firstPersistenceWaiter = nil
        await withCheckedContinuation { firstPersistenceGate = $0 }
    }

    func waitUntilFirstPersistenceStarted() async {
        if firstPersistenceStarted { return }
        await withCheckedContinuation { firstPersistenceWaiter = $0 }
    }

    func releaseFirstPersistence() {
        firstPersistenceGate?.resume()
        firstPersistenceGate = nil
    }
}

private actor SelectionProbe {
    private(set) var applied: [String] = []
    private(set) var persisted: [String] = []
    private var firstStarted: CheckedContinuation<Void, Never>?
    private var firstWasStarted = false
    private var firstGate: CheckedContinuation<Void, Never>?

    func apply(_ node: String) async throws {
        applied.append(node)
        guard node == "A" else { return }
        firstWasStarted = true
        firstStarted?.resume()
        firstStarted = nil
        await withCheckedContinuation { firstGate = $0 }
    }

    func persist(_ node: String) {
        persisted.append(node)
    }

    func waitUntilFirstStarted() async {
        if firstWasStarted { return }
        await withCheckedContinuation { firstStarted = $0 }
    }

    func releaseFirst() {
        firstGate?.resume()
        firstGate = nil
    }
}

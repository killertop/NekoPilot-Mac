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
            persistSelection: { node in await probe.persist(node) }
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

    @Test("Automatic selection supersedes an active manual choice")
    func automaticSelectionHasPriority() async throws {
        let probe = SelectionProbe()
        let coordinator = NodeSelectionCoordinator(
            applySelection: { node in try await probe.apply(node) },
            persistSelection: { node in await probe.persist(node) }
        )

        let manual = Task { try await coordinator.submit(node: "A") }
        await probe.waitUntilFirstStarted()
        let automatic = Task { try await coordinator.submitAutomatic(node: "B") }
        while await coordinator.pendingNodeForTesting != "B" { await Task.yield() }
        await probe.releaseFirst()
        #expect(try await manual.value == false)
        #expect(try await automatic.value == true)

        #expect(await probe.applied == ["A", "B"])
        #expect(await probe.persisted == ["B"])
    }

    @Test("A manual choice cannot supersede an automatic request already in flight")
    func automaticSelectionWinsAfterApplyStarts() async throws {
        let probe = SelectionProbe()
        let coordinator = NodeSelectionCoordinator(
            applySelection: { node in try await probe.apply(node) },
            persistSelection: { node in await probe.persist(node) }
        )

        let automatic = Task { try await coordinator.submitAutomatic(node: "A") }
        await probe.waitUntilFirstStarted()
        let manualApplied = try await coordinator.submit(node: "C")
        #expect(manualApplied == false)
        await probe.releaseFirst()

        #expect(try await automatic.value == true)
        #expect(await probe.applied == ["A"])
        #expect(await probe.persisted == ["A"])
    }

    @Test("Disabling automatic selection lets a manual choice take over an in-flight request")
    func disablingAutomaticSelectionRestoresManualPriority() async throws {
        let probe = SelectionProbe()
        let coordinator = NodeSelectionCoordinator(
            applySelection: { node in try await probe.apply(node) },
            persistSelection: { node in await probe.persist(node) }
        )

        let automatic = Task { try await coordinator.submitAutomatic(node: "A") }
        await probe.waitUntilFirstStarted()
        await coordinator.setAutomaticSelectionEnabled(false)
        let manual = Task { try await coordinator.submit(node: "C") }
        while await coordinator.pendingNodeForTesting != "C" { await Task.yield() }
        await probe.releaseFirst()

        #expect(try await automatic.value == false)
        #expect(try await manual.value == true)
        #expect(await probe.applied == ["A", "C"])
        #expect(await probe.persisted == ["C"])
    }

    @Test("Disabling during persistence rolls back the automatic choice")
    func disablingAutomaticSelectionDuringPersistenceRollsBack() async throws {
        let probe = PersistenceGateProbe()
        let coordinator = NodeSelectionCoordinator(
            applySelection: { node in await probe.apply(node) },
            persistSelection: { node in await probe.persist(node) },
            loadPersistedSelection: { "Previous" }
        )

        let automatic = Task { try await coordinator.submitAutomatic(node: "A") }
        await probe.waitUntilFirstPersistenceStarted()
        await coordinator.setAutomaticSelectionEnabled(false)
        await probe.releaseFirstPersistence()

        #expect(try await automatic.value == false)
        #expect(await probe.applied == ["A", "Previous"])
        #expect(await probe.persisted == ["A", "Previous"])
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

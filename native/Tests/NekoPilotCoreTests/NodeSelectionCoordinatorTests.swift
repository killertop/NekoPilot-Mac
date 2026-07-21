import Foundation
import Testing
@testable import NekoPilotCore

@Suite("Node selection coordination")
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

        try await first.value
        try await second.value
        try await third.value
        let publishedNode = await published.value
        let persisted = await probe.persisted
        let applied = await probe.applied
        #expect(publishedNode == "C")
        #expect(persisted == ["C"])
        #expect(applied == ["A", "C"])
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

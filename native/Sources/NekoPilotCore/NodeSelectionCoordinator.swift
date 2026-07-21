import Foundation

public actor NodeSelectionCoordinator {
    private struct Request {
        let node: String
        let continuation: CheckedContinuation<Void, Error>
    }

    private let applySelection: @Sendable (String) async throws -> Void
    private let persistSelection: @Sendable (String) async throws -> Void
    private var pending: Request?
    private var processing = false
    private var continuations: [UUID: AsyncStream<String>.Continuation] = [:]

    public init(engine: EngineSupervisor, settings: SettingsStore) {
        applySelection = { node in try await engine.select(node: node) }
        persistSelection = { node in
            try await settings.set(.string(node), for: SettingsStore.Key.selectedNode)
        }
    }

    init(
        applySelection: @escaping @Sendable (String) async throws -> Void,
        persistSelection: @escaping @Sendable (String) async throws -> Void
    ) {
        self.applySelection = applySelection
        self.persistSelection = persistSelection
    }

    public func submit(node: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            if let superseded = pending {
                superseded.continuation.resume()
            }
            pending = Request(node: node, continuation: continuation)
            guard !processing else { return }
            processing = true
            Task { await self.processPendingRequests() }
        }
    }

    public func selections() -> AsyncStream<String> {
        let identifier = UUID()
        return AsyncStream { continuation in
            continuations[identifier] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(identifier) }
            }
        }
    }

    private func processPendingRequests() async {
        while let request = pending {
            pending = nil
            do {
                try await applySelection(request.node)
                // A newer tap may arrive while the engine call is suspended.
                // Keep the optimistic UI on the newest request instead of
                // publishing an already superseded intermediate selection.
                if pending != nil {
                    request.continuation.resume()
                    continue
                }
                try await persistSelection(request.node)
                if pending != nil {
                    request.continuation.resume()
                    continue
                }
                for continuation in continuations.values { continuation.yield(request.node) }
                request.continuation.resume()
            } catch {
                request.continuation.resume(throwing: error)
            }
        }
        processing = false
    }

    private func removeContinuation(_ identifier: UUID) {
        continuations.removeValue(forKey: identifier)
    }

    #if DEBUG
    var pendingNodeForTesting: String? { pending?.node }
    #endif
}

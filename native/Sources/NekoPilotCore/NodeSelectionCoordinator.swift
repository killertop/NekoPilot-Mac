import Foundation

public actor NodeSelectionCoordinator {
    private struct Request {
        let node: String
        let continuation: CheckedContinuation<Void, Error>
    }

    private let engine: EngineSupervisor
    private let settings: SettingsStore
    private var pending: Request?
    private var processing = false
    private var continuations: [UUID: AsyncStream<String>.Continuation] = [:]

    public init(engine: EngineSupervisor, settings: SettingsStore) {
        self.engine = engine
        self.settings = settings
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
                try await engine.select(node: request.node)
                try await settings.set(.string(request.node), for: SettingsStore.Key.selectedNode)
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
}

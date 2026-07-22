import Foundation

public actor NodeSelectionCoordinator {
    private enum Origin {
        case failover
        case manual
    }

    private struct Request {
        let id: UUID
        let node: String
        let origin: Origin
        let cancellation: SelectionRequestCancellation
        let continuation: CheckedContinuation<Bool, Error>
    }

    private let applySelection: @Sendable (String) async throws -> Void
    private let persistSelection: @Sendable (String?) async throws -> Void
    private let loadPersistedSelection: @Sendable () async -> String?
    private var pending: Request?
    private var processing = false
    private var activeOrigin: Origin?
    private var activeRequestID: UUID?
    private var activeCancellation: SelectionRequestCancellation?
    private var automaticSwitchingEnabled = true
    private var continuations: [UUID: AsyncStream<String>.Continuation] = [:]

    public init(engine: EngineSupervisor, settings: SettingsStore) {
        applySelection = { node in try await engine.select(node: node) }
        persistSelection = { node in
            try await settings.set(node.map(JSONValue.string), for: SettingsStore.Key.selectedNode)
        }
        loadPersistedSelection = {
            let value = await settings.string(SettingsStore.Key.selectedNode)
            return value.isEmpty ? nil : value
        }
    }

    init(
        applySelection: @escaping @Sendable (String) async throws -> Void,
        persistSelection: @escaping @Sendable (String?) async throws -> Void,
        loadPersistedSelection: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.applySelection = applySelection
        self.persistSelection = persistSelection
        self.loadPersistedSelection = loadPersistedSelection
    }

    @discardableResult
    public func submit(node: String) async throws -> Bool {
        try await submit(node: node, origin: .manual)
    }

    /// A failover is deliberately lower priority than a new manual choice.
    /// `false` means the request was disabled or superseded before it became
    /// the persisted selection.
    public func submitFailover(node: String) async throws -> Bool {
        try await submit(node: node, origin: .failover)
    }

    public func setAutomaticSwitchingEnabled(_ enabled: Bool) {
        automaticSwitchingEnabled = enabled
        if !enabled, let request = pending, request.origin == .failover {
            pending = nil
            request.continuation.resume(returning: false)
        }
    }

    private func submit(node: String, origin: Origin) async throws -> Bool {
        let requestID = UUID()
        let cancellation = SelectionRequestCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled || cancellation.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if origin == .failover, !automaticSwitchingEnabled {
                    continuation.resume(returning: false)
                    return
                }
                if origin == .failover,
                   activeOrigin == .manual || pending?.origin == .manual {
                    continuation.resume(returning: false)
                    return
                }
                if let superseded = pending {
                    superseded.continuation.resume(returning: false)
                }
                pending = Request(
                    id: requestID,
                    node: node,
                    origin: origin,
                    cancellation: cancellation,
                    continuation: continuation
                )
                guard !processing else { return }
                processing = true
                Task { await self.processPendingRequests() }
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancel(requestID: requestID) }
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
            activeOrigin = request.origin
            activeRequestID = request.id
            activeCancellation = request.cancellation
            let previousNode = await loadPersistedSelection()
            if shouldAbort(request) {
                finishAborted(request)
                continue
            }
            var runtimeMayHaveChanged = false
            var persistenceMayHaveChanged = false
            do {
                runtimeMayHaveChanged = true
                try await applySelection(request.node)
                if shouldAbort(request) {
                    try await restore(
                        previousNode: previousNode,
                        request: request,
                        restoreRuntime: true,
                        restorePersistence: false
                    )
                    finishAborted(request)
                    continue
                }
                persistenceMayHaveChanged = true
                try await persistSelection(request.node)
                if shouldAbort(request) {
                    try await restore(
                        previousNode: previousNode,
                        request: request,
                        restoreRuntime: true,
                        restorePersistence: true
                    )
                    finishAborted(request)
                    continue
                }
                for continuation in continuations.values { continuation.yield(request.node) }
                clearActiveRequest(request)
                request.continuation.resume(returning: true)
            } catch {
                // The API can apply a selector change before its response or
                // the subsequent preference write fails. Restore the last
                // committed node so runtime, UI, and disk never diverge.
                try? await restore(
                    previousNode: previousNode,
                    request: request,
                    restoreRuntime: runtimeMayHaveChanged,
                    restorePersistence: persistenceMayHaveChanged
                )
                clearActiveRequest(request)
                request.continuation.resume(throwing: error)
            }
        }
        activeOrigin = nil
        activeRequestID = nil
        activeCancellation = nil
        processing = false
    }

    private func shouldAbort(_ request: Request) -> Bool {
        request.cancellation.isCancelled
            || pending != nil
            || (request.origin == .failover && !automaticSwitchingEnabled)
    }

    private func finishAborted(_ request: Request) {
        let wasCancelled = request.cancellation.isCancelled
        clearActiveRequest(request)
        if wasCancelled {
            request.continuation.resume(throwing: CancellationError())
        } else {
            request.continuation.resume(returning: false)
        }
    }

    private func clearActiveRequest(_ request: Request) {
        if activeRequestID == request.id {
            activeRequestID = nil
            activeCancellation = nil
        }
        activeOrigin = nil
    }

    private func restore(
        previousNode: String?,
        request: Request,
        restoreRuntime: Bool,
        restorePersistence: Bool
    ) async throws {
        if restoreRuntime, let previousNode, previousNode != request.node {
            try await applySelection(previousNode)
        }
        if restorePersistence {
            try await persistSelection(previousNode)
        }
    }

    private func cancel(requestID: UUID) {
        if let request = pending, request.id == requestID {
            pending = nil
            request.continuation.resume(throwing: CancellationError())
            return
        }
        // An active request observes its lock-backed cancellation flag at the
        // next mutation boundary. The actor hop is only needed to remove a
        // request that has not started yet.
    }

    private func removeContinuation(_ identifier: UUID) {
        continuations.removeValue(forKey: identifier)
    }

    #if DEBUG
    var pendingNodeForTesting: String? { pending?.node }
    var activeRequestCancelledForTesting: Bool {
        activeCancellation?.isCancelled ?? false
    }
    #endif
}

private final class SelectionRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

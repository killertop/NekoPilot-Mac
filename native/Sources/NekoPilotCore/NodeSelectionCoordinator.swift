import Foundation

public actor NodeSelectionCoordinator {
    private enum Origin {
        case automatic
        case manual
    }

    private struct Request {
        let node: String
        let origin: Origin
        let continuation: CheckedContinuation<Bool, Error>
    }

    private let applySelection: @Sendable (String) async throws -> Void
    private let persistSelection: @Sendable (String) async throws -> Void
    private let loadPersistedSelection: @Sendable () async -> String?
    private var pending: Request?
    private var processing = false
    private var activeOrigin: Origin?
    private var automaticSelectionEnabled = true
    private var continuations: [UUID: AsyncStream<String>.Continuation] = [:]

    public init(engine: EngineSupervisor, settings: SettingsStore) {
        applySelection = { node in try await engine.select(node: node) }
        persistSelection = { node in
            try await settings.set(.string(node), for: SettingsStore.Key.selectedNode)
        }
        loadPersistedSelection = {
            let value = await settings.string(SettingsStore.Key.selectedNode)
            return value.isEmpty ? nil : value
        }
    }

    init(
        applySelection: @escaping @Sendable (String) async throws -> Void,
        persistSelection: @escaping @Sendable (String) async throws -> Void,
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

    /// While automatic selection is enabled, its requests are authoritative.
    /// `false` means a higher-priority automatic request was already active or
    /// superseded this request before it became the persisted selection.
    public func submitAutomatic(node: String) async throws -> Bool {
        try await submit(node: node, origin: .automatic)
    }

    public func setAutomaticSelectionEnabled(_ enabled: Bool) {
        automaticSelectionEnabled = enabled
        if !enabled, let request = pending, request.origin == .automatic {
            pending = nil
            request.continuation.resume(returning: false)
        }
    }

    private func submit(node: String, origin: Origin) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            if origin == .automatic, !automaticSelectionEnabled {
                continuation.resume(returning: false)
                return
            }
            if origin == .manual,
               automaticSelectionEnabled,
               activeOrigin == .automatic || pending?.origin == .automatic {
                continuation.resume(returning: false)
                return
            }
            if let superseded = pending {
                superseded.continuation.resume(returning: false)
            }
            pending = Request(node: node, origin: origin, continuation: continuation)
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
            activeOrigin = request.origin
            let previousNode = await loadPersistedSelection()
            do {
                try await applySelection(request.node)
                if request.origin == .automatic, !automaticSelectionEnabled {
                    // Disabling the feature while the engine call is in flight
                    // revokes the automatic choice. A queued manual request
                    // will immediately replace it; otherwise restore disk's
                    // last committed runtime selection.
                    if pending == nil, let previousNode, previousNode != request.node {
                        try? await applySelection(previousNode)
                    }
                    request.continuation.resume(returning: false)
                    continue
                }
                // A newer tap may arrive while the engine call is suspended.
                // Keep the optimistic UI on the newest request instead of
                // publishing an already superseded intermediate selection.
                if pending != nil {
                    request.continuation.resume(returning: false)
                    continue
                }
                try await persistSelection(request.node)
                if request.origin == .automatic, !automaticSelectionEnabled {
                    // The preference write can suspend. Re-check after it so
                    // disabling automatic selection cannot commit and publish
                    // one final automatic node behind the user's switch.
                    if pending == nil, let previousNode, previousNode != request.node {
                        try await applySelection(previousNode)
                        try await persistSelection(previousNode)
                    }
                    request.continuation.resume(returning: false)
                    continue
                }
                if pending != nil {
                    request.continuation.resume(returning: false)
                    continue
                }
                for continuation in continuations.values { continuation.yield(request.node) }
                request.continuation.resume(returning: true)
            } catch {
                // The API can apply a selector change before its response or
                // the subsequent preference write fails. Restore the last
                // committed node so runtime, UI, and disk never diverge.
                if let previousNode, previousNode != request.node {
                    try? await applySelection(previousNode)
                }
                request.continuation.resume(throwing: error)
            }
        }
        activeOrigin = nil
        processing = false
    }

    private func removeContinuation(_ identifier: UUID) {
        continuations.removeValue(forKey: identifier)
    }

    #if DEBUG
    var pendingNodeForTesting: String? { pending?.node }
    #endif
}

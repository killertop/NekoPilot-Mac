import Foundation
import Network

public final class NetworkReadiness: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.nekopilot.network-readiness")
    private let lock = NSLock()
    // Do not report a usable network before NWPathMonitor has delivered its
    // initial path. Assuming readiness here defeated the wake/retry gate on a
    // machine that resumed before Wi-Fi had reassociated.
    private var satisfied = false
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
        lock.lock()
        let continuations = Array(self.continuations.values)
        self.continuations.removeAll()
        lock.unlock()
        continuations.forEach { $0.finish() }
    }

    public var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return satisfied
    }

    /// Emits the current path state immediately and every subsequent change.
    /// Consumers can react to a network becoming usable without waiting for a
    /// periodic retry timer.
    public func states() -> AsyncStream<Bool> {
        let identifier = UUID()
        return AsyncStream { continuation in
            lock.lock()
            let current = satisfied
            continuations[identifier] = continuation
            continuation.yield(current)
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(identifier)
            }
        }
    }

    public func waitUntilReady(attempts: Int = 10, interval: TimeInterval = 2) async -> Bool {
        for _ in 0 ..< max(1, attempts) {
            if Task.isCancelled { return false }
            if isReady { return true }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return isReady
    }

    private func update(_ ready: Bool) {
        lock.lock()
        guard satisfied != ready else {
            lock.unlock()
            return
        }
        satisfied = ready
        let continuations = Array(self.continuations.values)
        lock.unlock()
        continuations.forEach { $0.yield(ready) }
    }

    private func removeContinuation(_ identifier: UUID) {
        lock.lock()
        continuations.removeValue(forKey: identifier)
        lock.unlock()
    }
}

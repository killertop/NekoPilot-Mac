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

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.lock.lock()
            self?.satisfied = path.status == .satisfied
            self?.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    public var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return satisfied
    }

    public func waitUntilReady(attempts: Int = 10, interval: TimeInterval = 2) async -> Bool {
        for _ in 0 ..< max(1, attempts) {
            if Task.isCancelled { return false }
            if isReady { return true }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return isReady
    }
}

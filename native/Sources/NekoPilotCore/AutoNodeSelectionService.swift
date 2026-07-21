import Foundation

public struct AutoNodeSelectionUpdate: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case kept(node: String, delay: Int)
        case switched(node: String, delay: Int)
        case deferredBusy
        case unavailable
        case failed
    }

    public let delays: [String: DelayRecord]
    public let outcome: Outcome
    public let measuredAt: Date

    public init(delays: [String: DelayRecord], outcome: Outcome, measuredAt: Date = Date()) {
        self.delays = delays
        self.outcome = outcome
        self.measuredAt = measuredAt
    }
}

public actor AutoNodeSelectionService {
    public static let interval: TimeInterval = 10 * 60

    private let engine: EngineSupervisor
    private let repository: SubscriptionRepository
    private let settings: SettingsStore
    private let tester: URLTester
    private let clashAPI: ClashAPIClient
    private let selection: NodeSelectionCoordinator
    private var timerTask: Task<Void, Never>?
    private var isStarted = false
    private var updateContinuations: [UUID: AsyncStream<AutoNodeSelectionUpdate>.Continuation] = [:]

    public init(
        engine: EngineSupervisor,
        repository: SubscriptionRepository,
        settings: SettingsStore,
        tester: URLTester,
        clashAPI: ClashAPIClient,
        selection: NodeSelectionCoordinator
    ) {
        self.engine = engine
        self.repository = repository
        self.settings = settings
        self.tester = tester
        self.clashAPI = clashAPI
        self.selection = selection
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        schedule()
    }

    public func stop() {
        isStarted = false
        timerTask?.cancel()
        timerTask = nil
    }

    public func updates() -> AsyncStream<AutoNodeSelectionUpdate> {
        let identifier = UUID()
        return AsyncStream { continuation in
            updateContinuations[identifier] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeUpdateContinuation(identifier) }
            }
        }
    }

    public func deferAfterManualSelection() {
        guard isStarted else { return }
        schedule()
    }

    private func schedule() {
        timerTask?.cancel()
        timerTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.runCycle()
            guard !Task.isCancelled else { return }
            self.scheduleNextCycle()
        }
    }

    private func scheduleNextCycle() {
        guard isStarted else { return }
        schedule()
    }

    private func runCycle() async {
        guard await settings.bool(SettingsStore.Key.autoSelect, default: true),
              (await engine.currentStatus()).isRunning,
              let nodes = try? await repository.nodes(),
              nodes.count > 1 else { return }
        let delays = await tester.test(nodes: nodes, engineRunning: true)
        do {
            try await repository.replaceDelayHistory(delays)
        } catch {
            AppLogger.shared.warning("automatic URL Test history could not be saved: \(error.localizedDescription)")
        }
        guard let fastest = delays
            .compactMap({ entry -> (String, Int)? in entry.value.delay.map { (entry.key, $0) } })
            .min(by: { $0.1 < $1.1 }) else {
            publish(AutoNodeSelectionUpdate(delays: delays, outcome: .unavailable))
            return
        }
        guard let selector = try? await clashAPI.selector(), selector.nodes.contains(fastest.0) else {
            publish(AutoNodeSelectionUpdate(delays: delays, outcome: .failed))
            return
        }
        if selector.current == fastest.0 {
            publish(AutoNodeSelectionUpdate(delays: delays, outcome: .kept(node: fastest.0, delay: fastest.1)))
            return
        }
        guard let hasLongConnection = await clashAPI.hasLongLivedConnection(),
              !hasLongConnection else {
            AppLogger.shared.info("automatic node switch deferred because connection state is unavailable or busy")
            publish(AutoNodeSelectionUpdate(delays: delays, outcome: .deferredBusy))
            return
        }
        do {
            try await selection.submit(node: fastest.0)
            AppLogger.shared.info("automatically selected fastest node delay=\(fastest.1)ms")
            publish(AutoNodeSelectionUpdate(delays: delays, outcome: .switched(node: fastest.0, delay: fastest.1)))
        } catch {
            AppLogger.shared.warning("automatic node selection failed: \(error.localizedDescription)")
            publish(AutoNodeSelectionUpdate(delays: delays, outcome: .failed))
        }
    }

    private func publish(_ update: AutoNodeSelectionUpdate) {
        for continuation in updateContinuations.values { continuation.yield(update) }
    }

    private func removeUpdateContinuation(_ identifier: UUID) {
        updateContinuations.removeValue(forKey: identifier)
    }
}

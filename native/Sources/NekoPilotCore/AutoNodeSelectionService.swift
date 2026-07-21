import Foundation

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
    private var updateContinuations: [UUID: AsyncStream<[String: DelayRecord]>.Continuation] = [:]

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

    public func updates() -> AsyncStream<[String: DelayRecord]> {
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
        for continuation in updateContinuations.values {
            continuation.yield(delays)
        }
        guard let fastest = delays
            .compactMap({ entry -> (String, Int)? in entry.value.delay.map { (entry.key, $0) } })
            .min(by: { $0.1 < $1.1 }),
              let selector = try? await clashAPI.selector(),
              selector.current != fastest.0,
              selector.nodes.contains(fastest.0) else { return }
        guard let hasLongConnection = await clashAPI.hasLongLivedConnection(),
              !hasLongConnection else {
            AppLogger.shared.info("automatic node switch deferred because connection state is unavailable or busy")
            return
        }
        do {
            try await selection.submit(node: fastest.0)
            AppLogger.shared.info("automatically selected fastest node delay=\(fastest.1)ms")
        } catch {
            AppLogger.shared.warning("automatic node selection failed: \(error.localizedDescription)")
        }
    }

    private func removeUpdateContinuation(_ identifier: UUID) {
        updateContinuations.removeValue(forKey: identifier)
    }
}

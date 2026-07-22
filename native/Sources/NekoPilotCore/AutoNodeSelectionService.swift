import Foundation

public struct AutoNodeSelectionUpdate: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case kept(node: String, delay: Int)
        case considering(node: String, delay: Int, confirmations: Int)
        case switched(node: String, delay: Int)
        case manualHold(node: String?, delay: Int?)
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

struct AutoNodeSelectionDecisionState: Equatable, Sendable {
    var candidate: String?
    var candidateConfirmations = 0
    var currentFailures = 0
    var lastSwitchAt: Date?

    mutating func resetCandidate() {
        candidate = nil
        candidateConfirmations = 0
    }

    mutating func recordSwitch(at date: Date) {
        lastSwitchAt = date
        currentFailures = 0
        resetCandidate()
    }
}

enum AutoNodeSelectionDecision: Equatable, Sendable {
    case keep(node: String, delay: Int)
    case considering(node: String, delay: Int, confirmations: Int, retrySoon: Bool)
    case switchTo(node: String, delay: Int)
    case unavailable(retrySoon: Bool)

    static let minimumAbsoluteImprovement = 50
    static let minimumRelativeImprovement = 0.20
    static let requiredConfirmations = 2
    static let switchCooldown: TimeInterval = 20 * 60

    static func evaluate(
        currentNode: String,
        delays: [String: DelayRecord],
        now: Date,
        state: inout AutoNodeSelectionDecisionState
    ) -> AutoNodeSelectionDecision {
        let reachable = delays.compactMap { tag, record -> (String, Int)? in
            record.delay.map { (tag, $0) }
        }.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 < rhs.1
        }

        guard let fastest = reachable.first else {
            state.currentFailures += 1
            state.resetCandidate()
            return .unavailable(retrySoon: state.currentFailures == 1)
        }

        guard let currentDelay = delays[currentNode]?.delay else {
            state.currentFailures += 1
            if state.currentFailures >= requiredConfirmations {
                return .switchTo(node: fastest.0, delay: fastest.1)
            }
            state.candidate = fastest.0
            state.candidateConfirmations = state.currentFailures
            return .considering(
                node: fastest.0,
                delay: fastest.1,
                confirmations: state.currentFailures,
                retrySoon: true
            )
        }

        state.currentFailures = 0
        guard fastest.0 != currentNode else {
            state.resetCandidate()
            return .keep(node: currentNode, delay: currentDelay)
        }

        if let lastSwitchAt = state.lastSwitchAt,
           now.timeIntervalSince(lastSwitchAt) < switchCooldown {
            state.resetCandidate()
            return .keep(node: currentNode, delay: currentDelay)
        }

        let absoluteImprovement = currentDelay - fastest.1
        let relativeImprovement = currentDelay > 0
            ? Double(absoluteImprovement) / Double(currentDelay)
            : 0
        guard absoluteImprovement >= minimumAbsoluteImprovement,
              relativeImprovement >= minimumRelativeImprovement else {
            state.resetCandidate()
            return .keep(node: currentNode, delay: currentDelay)
        }

        if state.candidate == fastest.0 {
            state.candidateConfirmations += 1
        } else {
            state.candidate = fastest.0
            state.candidateConfirmations = 1
        }
        guard state.candidateConfirmations >= requiredConfirmations else {
            return .considering(
                node: fastest.0,
                delay: fastest.1,
                confirmations: state.candidateConfirmations,
                retrySoon: false
            )
        }
        return .switchTo(node: fastest.0, delay: fastest.1)
    }
}

public actor AutoNodeSelectionService {
    public static let interval: TimeInterval = 10 * 60
    private static let failureConfirmationDelay: TimeInterval = 3
    private static let networkRetryDelay: TimeInterval = 30
    private static let enableDelay: TimeInterval = 1

    private let engine: EngineSupervisor
    private let repository: SubscriptionRepository
    private let settings: SettingsStore
    private let tester: URLTester
    private let nativeAPI: NativeControlClient
    private let selection: NodeSelectionCoordinator
    private let networkReadiness: NetworkReadiness
    private var timerTask: Task<Void, Never>?
    private var generation = 0
    private var isStarted = false
    private var isEnabled = true
    private var isEngineRunning = false
    private var isExplicitTestActive = false
    private var isLifecycleSuspended = false
    private var hasManualOverride = false
    private var decisionState = AutoNodeSelectionDecisionState()
    private var updateContinuations: [UUID: AsyncStream<AutoNodeSelectionUpdate>.Continuation] = [:]

    public init(
        engine: EngineSupervisor,
        repository: SubscriptionRepository,
        settings: SettingsStore,
        tester: URLTester,
        nativeAPI: NativeControlClient,
        selection: NodeSelectionCoordinator,
        networkReadiness: NetworkReadiness
    ) {
        self.engine = engine
        self.repository = repository
        self.settings = settings
        self.tester = tester
        self.nativeAPI = nativeAPI
        self.selection = selection
        self.networkReadiness = networkReadiness
    }

    public func start(enabled: Bool, engineRunning: Bool) {
        guard !isStarted else { return }
        isStarted = true
        isEnabled = enabled
        isEngineRunning = engineRunning
        reschedule(after: Self.interval)
    }

    public func stop() {
        isStarted = false
        invalidateCycle()
    }

    public func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        decisionState = AutoNodeSelectionDecisionState()
        if enabled {
            hasManualOverride = false
            reschedule(after: Self.enableDelay)
        } else {
            invalidateCycle()
        }
    }

    public func updateConnectionState(isRunning: Bool) {
        guard isEngineRunning != isRunning else { return }
        isEngineRunning = isRunning
        decisionState.resetCandidate()
        if isRunning {
            reschedule(after: Self.interval)
        } else {
            invalidateCycle()
        }
    }

    public func nodesDidChange() {
        decisionState.resetCandidate()
        reschedule(after: Self.interval)
    }

    public func setManualOverride(_ active: Bool) {
        guard hasManualOverride != active else { return }
        hasManualOverride = active
        decisionState.resetCandidate()
        // Cancelling first guarantees an in-flight automatic request cannot be
        // submitted after a direct user selection. Periodic history refreshes
        // resume later, but the service will not switch while the hold is set.
        reschedule(after: Self.interval)
    }

    public func setExplicitTestActive(_ active: Bool) {
        guard isExplicitTestActive != active else { return }
        isExplicitTestActive = active
        if active {
            invalidateCycle()
        } else {
            reschedule(after: Self.interval)
        }
    }

    public func setLifecycleSuspended(_ suspended: Bool) {
        guard isLifecycleSuspended != suspended else { return }
        isLifecycleSuspended = suspended
        if suspended {
            invalidateCycle()
        } else {
            reschedule(after: Self.networkRetryDelay)
        }
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

    private var canRunCycle: Bool {
        isStarted && isEnabled && isEngineRunning && !isExplicitTestActive && !isLifecycleSuspended
    }

    private func invalidateCycle() {
        generation += 1
        timerTask?.cancel()
        timerTask = nil
    }

    private func reschedule(after delay: TimeInterval) {
        invalidateCycle()
        guard canRunCycle else { return }
        let scheduledGeneration = generation
        timerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.runCycle(generation: scheduledGeneration)
        }
    }

    private func cycleIsCurrent(_ scheduledGeneration: Int) -> Bool {
        scheduledGeneration == generation && !Task.isCancelled && canRunCycle
    }

    private func finishCycle(generation scheduledGeneration: Int, nextDelay: TimeInterval) {
        guard cycleIsCurrent(scheduledGeneration) else { return }
        reschedule(after: nextDelay)
    }

    private func runCycle(generation scheduledGeneration: Int) async {
        guard cycleIsCurrent(scheduledGeneration) else { return }
        guard networkReadiness.isReady else {
            finishCycle(generation: scheduledGeneration, nextDelay: Self.networkRetryDelay)
            return
        }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            finishCycle(generation: scheduledGeneration, nextDelay: Self.interval)
            return
        }
        guard let testedNodes = try? await repository.nodes(), testedNodes.count > 1 else {
            finishCycle(generation: scheduledGeneration, nextDelay: Self.interval)
            return
        }

        let delays = await tester.test(nodes: testedNodes, engineRunning: true)
        guard cycleIsCurrent(scheduledGeneration),
              (await engine.currentStatus()).isRunning,
              await settings.bool(SettingsStore.Key.autoSelect, default: true),
              let currentNodes = try? await repository.nodes() else { return }

        let currentTags = Set(currentNodes.map(\.runtimeTag))
        let history: [String: DelayRecord]
        do {
            history = try await repository.mergeDelayHistory(delays, retaining: currentTags)
        } catch {
            AppLogger.shared.warning("automatic URL Test history could not be saved: \(error.localizedDescription)")
            publish(AutoNodeSelectionUpdate(delays: delays, outcome: .failed))
            finishCycle(generation: scheduledGeneration, nextDelay: Self.interval)
            return
        }

        guard cycleIsCurrent(scheduledGeneration),
              Set(testedNodes.map(\.runtimeTag)) == currentTags,
              let selector = try? await nativeAPI.selector(knownNodes: Array(currentTags)),
              currentTags.contains(selector.current) else {
            publish(AutoNodeSelectionUpdate(delays: history, outcome: .failed))
            finishCycle(generation: scheduledGeneration, nextDelay: Self.interval)
            return
        }

        if hasManualOverride {
            decisionState.resetCandidate()
            publish(AutoNodeSelectionUpdate(
                delays: history,
                outcome: .manualHold(node: selector.current, delay: delays[selector.current]?.delay)
            ))
            finishCycle(generation: scheduledGeneration, nextDelay: Self.interval)
            return
        }

        let now = Date()
        let decision = AutoNodeSelectionDecision.evaluate(
            currentNode: selector.current,
            delays: delays,
            now: now,
            state: &decisionState
        )
        switch decision {
        case let .keep(node, delay):
            publish(AutoNodeSelectionUpdate(delays: history, outcome: .kept(node: node, delay: delay)))
            finishCycle(generation: scheduledGeneration, nextDelay: Self.interval)
        case let .considering(node, delay, confirmations, retrySoon):
            publish(AutoNodeSelectionUpdate(
                delays: history,
                outcome: .considering(node: node, delay: delay, confirmations: confirmations)
            ))
            finishCycle(
                generation: scheduledGeneration,
                nextDelay: retrySoon ? Self.failureConfirmationDelay : Self.interval
            )
        case let .switchTo(node, delay):
            guard cycleIsCurrent(scheduledGeneration), selector.nodes.contains(node) else { return }
            do {
                guard try await selection.submitAutomatic(node: node),
                      cycleIsCurrent(scheduledGeneration) else { return }
                decisionState.recordSwitch(at: now)
                AppLogger.shared.info("automatically selected stable faster node delay=\(delay)ms")
                publish(AutoNodeSelectionUpdate(delays: history, outcome: .switched(node: node, delay: delay)))
            } catch is CancellationError {
                return
            } catch {
                AppLogger.shared.warning("automatic node selection failed: \(error.localizedDescription)")
                publish(AutoNodeSelectionUpdate(delays: history, outcome: .failed))
            }
            finishCycle(generation: scheduledGeneration, nextDelay: Self.interval)
        case let .unavailable(retrySoon):
            publish(AutoNodeSelectionUpdate(delays: history, outcome: .unavailable))
            finishCycle(
                generation: scheduledGeneration,
                nextDelay: retrySoon ? Self.failureConfirmationDelay : Self.interval
            )
        }
    }

    private func publish(_ update: AutoNodeSelectionUpdate) {
        for continuation in updateContinuations.values { continuation.yield(update) }
    }

    private func removeUpdateContinuation(_ identifier: UUID) {
        updateContinuations.removeValue(forKey: identifier)
    }
}

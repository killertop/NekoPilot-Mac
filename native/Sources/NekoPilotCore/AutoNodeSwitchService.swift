import Foundation

public struct AutoNodeSwitchUpdate: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case monitoring(node: String, delay: Int)
        case confirming(node: String, failures: Int)
        case switched(from: String, to: String, delay: Int)
        case unavailable(node: String)
        case failed(node: String?)
    }

    public let outcome: Outcome
    public let measuredAt: Date

    public init(outcome: Outcome, measuredAt: Date = Date()) {
        self.outcome = outcome
        self.measuredAt = measuredAt
    }
}

struct AutoNodeSwitchDecisionState: Equatable, Sendable {
    private(set) var monitoredNode: String?
    private(set) var consecutiveFailures = 0

    mutating func reset() {
        monitoredNode = nil
        consecutiveFailures = 0
    }

    mutating func evaluate(
        node: String,
        result: ProxyHealthProbeResult
    ) -> AutoNodeSwitchDecision {
        if monitoredNode != node {
            monitoredNode = node
            consecutiveFailures = 0
        }
        switch result {
        case let .reachable(delay):
            consecutiveFailures = 0
            return .healthy(node: node, delay: delay)
        case .unreachable:
            consecutiveFailures += 1
            if consecutiveFailures >= AutoNodeSwitchDecision.requiredFailures {
                return .verifyCandidates(node: node)
            }
            return .confirmFailure(node: node, failures: consecutiveFailures)
        case .indeterminate:
            consecutiveFailures = 0
            return .indeterminate(node: node)
        }
    }
}

enum AutoNodeSwitchDecision: Equatable, Sendable {
    case healthy(node: String, delay: Int)
    case confirmFailure(node: String, failures: Int)
    case verifyCandidates(node: String)
    case indeterminate(node: String)

    static let requiredFailures = 2
}

enum AutoNodeSwitchCandidates {
    static func rankedForFailover(
        nodes: [ProxyNode],
        excluding currentNode: String,
        recentlyUnavailable: Set<String>,
        history: [String: DelayRecord],
        limit: Int
    ) -> [ProxyNode] {
        let preferred = ranked(
            nodes: nodes,
            excluding: currentNode,
            recentlyUnavailable: recentlyUnavailable,
            history: history,
            limit: limit
        )
        guard preferred.isEmpty, !recentlyUnavailable.isEmpty else { return preferred }
        // Staying on a confirmed-dead node is worse than retrying a cooled-down
        // candidate when every alternative has recently failed. Cooldown is a
        // stability preference, not a hard availability blacklist.
        return ranked(
            nodes: nodes,
            excluding: currentNode,
            history: history,
            limit: limit
        )
    }

    static func ranked(
        nodes: [ProxyNode],
        excluding currentNode: String,
        recentlyUnavailable: Set<String> = [],
        history: [String: DelayRecord],
        limit: Int
    ) -> [ProxyNode] {
        guard limit > 0 else { return [] }
        let eligible = nodes.filter { node in
            guard node.runtimeTag != currentNode else { return false }
            guard !recentlyUnavailable.contains(node.runtimeTag) else { return false }
            guard let delay = history[node.runtimeTag]?.delay else { return true }
            return delay > 0
        }
        let measured = eligible.compactMap { node -> (ProxyNode, Int)? in
            guard let delay = history[node.runtimeTag]?.delay else { return nil }
            return (node, delay)
        }.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.runtimeTag < rhs.0.runtimeTag : lhs.1 < rhs.1
        }.map(\.0)
        let unmeasured = eligible.filter { history[$0.runtimeTag]?.delay == nil }
            .sorted { $0.runtimeTag < $1.runtimeTag }
        return Array((measured + unmeasured).prefix(limit))
    }

    static func fastestVerified(
        candidates: [ProxyNode],
        results: [String: DelayRecord]
    ) -> (node: ProxyNode, delay: Int)? {
        candidates.compactMap { node -> (ProxyNode, Int)? in
            guard let delay = results[node.runtimeTag]?.delay, delay > 0 else { return nil }
            return (node, delay)
        }.min { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.runtimeTag < rhs.0.runtimeTag : lhs.1 < rhs.1
        }
    }
}

public actor AutoNodeSwitchService {
    /// The live probe is intentionally lightweight, but not continuous. A
    /// 30-second cadence bounds failover detection without turning the proxy
    /// into a permanent connectivity-check client.
    public static let interval: TimeInterval = 30
    private static let failureConfirmationDelay: TimeInterval = 3
    private static let networkRetryDelay: TimeInterval = 30
    private static let enableDelay: TimeInterval = 1
    private static let maximumCandidateChecks = 3
    private static let failedNodeCooldown: TimeInterval = 5 * 60

    private let engine: EngineSupervisor
    private let repository: SubscriptionRepository
    private let settings: SettingsStore
    private let tester: URLTester
    private let nativeAPI: NativeControlClient
    private let selection: NodeSelectionCoordinator
    private let networkReadiness: NetworkReadiness
    private let healthProbe: ProxyHealthProbe
    private let logger: any AppLogging
    private var timerTask: Task<Void, Never>?
    private var networkTask: Task<Void, Never>?
    private var generation = 0
    private var isStarted = false
    private var isEnabled = true
    private var isEngineRunning = false
    private var isExplicitTestActive = false
    private var isLifecycleSuspended = false
    private var decisionState = AutoNodeSwitchDecisionState()
    private var failedNodeDeadlines: [String: Date] = [:]
    private var updateContinuations: [UUID: AsyncStream<AutoNodeSwitchUpdate>.Continuation] = [:]

    public init(
        engine: EngineSupervisor,
        repository: SubscriptionRepository,
        settings: SettingsStore,
        tester: URLTester,
        nativeAPI: NativeControlClient,
        selection: NodeSelectionCoordinator,
        networkReadiness: NetworkReadiness,
        logger: any AppLogging = AppLogger.shared
    ) {
        self.engine = engine
        self.repository = repository
        self.settings = settings
        self.tester = tester
        self.nativeAPI = nativeAPI
        self.selection = selection
        self.networkReadiness = networkReadiness
        self.logger = logger
        healthProbe = ProxyHealthProbe()
    }

    public func start(enabled: Bool, engineRunning: Bool) {
        guard !isStarted else { return }
        isStarted = true
        isEnabled = enabled
        isEngineRunning = engineRunning
        let stream = networkReadiness.states()
        networkTask = Task { [weak self] in
            for await ready in stream {
                guard let self else { return }
                await self.handleNetworkReadinessChange(ready)
            }
        }
        reschedule(after: Self.interval)
    }

    public func stop() {
        isStarted = false
        decisionState.reset()
        failedNodeDeadlines.removeAll()
        networkTask?.cancel()
        networkTask = nil
        invalidateCycle()
    }

    public func setAutomaticSwitchingEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        decisionState.reset()
        if enabled {
            reschedule(after: Self.enableDelay)
        } else {
            failedNodeDeadlines.removeAll()
            invalidateCycle()
        }
    }

    public func updateConnectionState(isRunning: Bool) {
        guard isEngineRunning != isRunning else { return }
        isEngineRunning = isRunning
        decisionState.reset()
        if isRunning {
            reschedule(after: Self.interval)
        } else {
            invalidateCycle()
        }
    }

    public func nodesDidChange() {
        decisionState.reset()
        reschedule(after: Self.interval)
    }

    public func manualSelectionDidApply() {
        decisionState.reset()
        reschedule(after: Self.interval)
    }

    public func setExplicitTestActive(_ active: Bool) {
        guard isExplicitTestActive != active else { return }
        isExplicitTestActive = active
        decisionState.reset()
        if active {
            invalidateCycle()
        } else {
            reschedule(after: Self.interval)
        }
    }

    public func setLifecycleSuspended(_ suspended: Bool) {
        guard isLifecycleSuspended != suspended else { return }
        isLifecycleSuspended = suspended
        decisionState.reset()
        if suspended {
            invalidateCycle()
        } else {
            reschedule(after: Self.networkRetryDelay)
        }
    }

    public func updates() -> AsyncStream<AutoNodeSwitchUpdate> {
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

    private func handleNetworkReadinessChange(_ ready: Bool) {
        guard isStarted else { return }
        decisionState.reset()
        if ready {
            // The path monitor is the first signal that a suspended or
            // switched interface is usable again. Probe immediately so a
            // recovered node is restored quickly and a dead node enters
            // candidate verification without waiting for the 30-second timer.
            reschedule(after: 0.5)
        } else {
            invalidateCycle()
        }
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
            decisionState.reset()
            finishCycle(generation: scheduledGeneration, nextDelay: Self.networkRetryDelay)
            return
        }
        let engineIsRunning = await engine.currentStatus().isRunning
        guard cycleIsCurrent(scheduledGeneration), engineIsRunning else { return }
        let settingIsEnabled = await settings.bool(SettingsStore.Key.autoSwitch, default: true)
        guard cycleIsCurrent(scheduledGeneration), settingIsEnabled else { return }
        guard let nodes = try? await repository.nodes() else {
            guard cycleIsCurrent(scheduledGeneration) else { return }
            decisionState.reset()
            publish(AutoNodeSwitchUpdate(outcome: .failed(node: nil)))
            finishCycle(generation: scheduledGeneration, nextDelay: Self.networkRetryDelay)
            return
        }
        guard cycleIsCurrent(scheduledGeneration) else { return }
        guard nodes.count > 1 else {
            decisionState.reset()
            finishCycle(generation: scheduledGeneration, nextDelay: Self.interval)
            return
        }

        let nodeTags = Set(nodes.map(\.runtimeTag))
        guard let selector = try? await nativeAPI.selector(knownNodes: Array(nodeTags)) else {
            guard cycleIsCurrent(scheduledGeneration) else { return }
            decisionState.reset()
            publish(AutoNodeSwitchUpdate(outcome: .failed(node: nil)))
            finishCycle(generation: scheduledGeneration, nextDelay: Self.networkRetryDelay)
            return
        }
        guard cycleIsCurrent(scheduledGeneration) else { return }
        guard nodeTags.contains(selector.current) else {
            decisionState.reset()
            publish(AutoNodeSwitchUpdate(outcome: .failed(node: nil)))
            finishCycle(generation: scheduledGeneration, nextDelay: Self.networkRetryDelay)
            return
        }
        let currentNode = selector.current
        let healthPort = await engine.currentHealthProbePort()
        guard cycleIsCurrent(scheduledGeneration) else { return }
        let health = await healthProbe.check(port: healthPort)
        guard cycleIsCurrent(scheduledGeneration) else { return }
        let stillRunning = await engine.currentStatus().isRunning
        guard cycleIsCurrent(scheduledGeneration), stillRunning else { return }
        let stillEnabled = await settings.bool(SettingsStore.Key.autoSwitch, default: true)
        guard cycleIsCurrent(scheduledGeneration), stillEnabled else { return }
        guard let currentSelector = try? await nativeAPI.selector(knownNodes: Array(nodeTags)) else {
            guard cycleIsCurrent(scheduledGeneration) else { return }
            decisionState.reset()
            publish(AutoNodeSwitchUpdate(outcome: .failed(node: currentNode)))
            finishCycle(generation: scheduledGeneration, nextDelay: Self.networkRetryDelay)
            return
        }
        guard cycleIsCurrent(scheduledGeneration) else { return }
        guard currentSelector.current == currentNode else {
            decisionState.reset()
            finishCycle(generation: scheduledGeneration, nextDelay: Self.interval)
            return
        }

        switch decisionState.evaluate(node: currentNode, result: health) {
        case let .healthy(node, delay):
            failedNodeDeadlines.removeValue(forKey: node)
            publish(AutoNodeSwitchUpdate(outcome: .monitoring(node: node, delay: delay)))
            finishCycle(generation: scheduledGeneration, nextDelay: Self.interval)
        case let .confirmFailure(node, failures):
            publish(AutoNodeSwitchUpdate(outcome: .confirming(node: node, failures: failures)))
            finishCycle(generation: scheduledGeneration, nextDelay: Self.failureConfirmationDelay)
        case let .indeterminate(node):
            publish(AutoNodeSwitchUpdate(outcome: .failed(node: node)))
            finishCycle(generation: scheduledGeneration, nextDelay: Self.networkRetryDelay)
        case .verifyCandidates:
            failedNodeDeadlines[currentNode] = Date().addingTimeInterval(Self.failedNodeCooldown)
            await verifyCandidates(
                currentNode: currentNode,
                nodes: nodes,
                generation: scheduledGeneration
            )
        }
    }

    private func verifyCandidates(
        currentNode: String,
        nodes: [ProxyNode],
        generation scheduledGeneration: Int
    ) async {
        let history: [String: DelayRecord]
        do {
            history = try await repository.delayHistory()
        } catch {
            guard cycleIsCurrent(scheduledGeneration) else { return }
            logger.warning("saved node delays could not be read: \(error.localizedDescription)")
            publish(AutoNodeSwitchUpdate(outcome: .failed(node: currentNode)))
            finishCycle(generation: scheduledGeneration, nextDelay: Self.networkRetryDelay)
            return
        }
        guard cycleIsCurrent(scheduledGeneration) else { return }
        let candidates = AutoNodeSwitchCandidates.rankedForFailover(
            nodes: nodes,
            excluding: currentNode,
            recentlyUnavailable: recentlyUnavailableNodes(in: Set(nodes.map(\.runtimeTag))),
            history: history,
            limit: Self.maximumCandidateChecks
        )
        guard !candidates.isEmpty else {
            publish(AutoNodeSwitchUpdate(outcome: .unavailable(node: currentNode)))
            finishCycle(generation: scheduledGeneration, nextDelay: Self.networkRetryDelay)
            return
        }

        let results = await tester.test(nodes: candidates)
        guard cycleIsCurrent(scheduledGeneration) else { return }
        let candidateCooldownDeadline = Date().addingTimeInterval(Self.failedNodeCooldown)
        for candidate in candidates {
            if let delay = results[candidate.runtimeTag]?.delay, delay > 0 {
                failedNodeDeadlines.removeValue(forKey: candidate.runtimeTag)
            } else {
                // Move past dead historically-fast nodes on the next cycle so
                // later candidates are not starved forever by the three-node
                // verification budget.
                failedNodeDeadlines[candidate.runtimeTag] = candidateCooldownDeadline
            }
        }
        guard let verified = AutoNodeSwitchCandidates.fastestVerified(
            candidates: candidates,
            results: results
        ) else {
            publish(AutoNodeSwitchUpdate(outcome: .unavailable(node: currentNode)))
            finishCycle(generation: scheduledGeneration, nextDelay: Self.networkRetryDelay)
            return
        }
        let engineIsRunning = await engine.currentStatus().isRunning
        guard cycleIsCurrent(scheduledGeneration), engineIsRunning else { return }
        let settingIsEnabled = await settings.bool(SettingsStore.Key.autoSwitch, default: true)
        guard cycleIsCurrent(scheduledGeneration), settingIsEnabled else { return }

        let validTags = Set(nodes.map(\.runtimeTag))
        guard let selector = try? await nativeAPI.selector(knownNodes: Array(validTags)) else {
            guard cycleIsCurrent(scheduledGeneration) else { return }
            publish(AutoNodeSwitchUpdate(outcome: .failed(node: currentNode)))
            finishCycle(generation: scheduledGeneration, nextDelay: Self.networkRetryDelay)
            return
        }
        guard cycleIsCurrent(scheduledGeneration) else { return }
        guard selector.current == currentNode,
              selector.nodes.contains(verified.node.runtimeTag) else {
            decisionState.reset()
            finishCycle(generation: scheduledGeneration, nextDelay: Self.interval)
            return
        }
        // Candidate verification can take one native URL Test window. Avoid
        // replacing a node that only suffered a short interruption and has
        // already recovered while those candidates were being checked.
        let currentHealthPort = await engine.currentHealthProbePort()
        guard cycleIsCurrent(scheduledGeneration) else { return }
        let recovered = await healthProbe.check(port: currentHealthPort)
        guard cycleIsCurrent(scheduledGeneration) else { return }
        switch recovered {
        case let .reachable(delay):
            decisionState.reset()
            failedNodeDeadlines.removeValue(forKey: currentNode)
            publish(AutoNodeSwitchUpdate(outcome: .monitoring(node: currentNode, delay: delay)))
            finishCycle(generation: scheduledGeneration, nextDelay: Self.interval)
            return
        case .indeterminate:
            decisionState.reset()
            publish(AutoNodeSwitchUpdate(outcome: .failed(node: currentNode)))
            finishCycle(generation: scheduledGeneration, nextDelay: Self.networkRetryDelay)
            return
        case .unreachable:
            break
        }
        guard let currentSelector = try? await nativeAPI.selector(knownNodes: Array(validTags)) else {
            guard cycleIsCurrent(scheduledGeneration) else { return }
            publish(AutoNodeSwitchUpdate(outcome: .failed(node: currentNode)))
            finishCycle(generation: scheduledGeneration, nextDelay: Self.networkRetryDelay)
            return
        }
        guard cycleIsCurrent(scheduledGeneration) else { return }
        guard currentSelector.current == currentNode,
              currentSelector.nodes.contains(verified.node.runtimeTag) else {
            decisionState.reset()
            finishCycle(generation: scheduledGeneration, nextDelay: Self.interval)
            return
        }
        do {
            let didSwitch = try await selection.submitFailover(node: verified.node.runtimeTag)
            guard cycleIsCurrent(scheduledGeneration) else { return }
            guard didSwitch else {
                finishCycle(generation: scheduledGeneration, nextDelay: Self.interval)
                return
            }
            decisionState.reset()
            logger.info("failed-over from unavailable node to verified candidate delay=\(verified.delay)ms")
            publish(AutoNodeSwitchUpdate(outcome: .switched(
                from: currentNode,
                to: verified.node.runtimeTag,
                delay: verified.delay
            )))
            finishCycle(generation: scheduledGeneration, nextDelay: Self.interval)
        } catch is CancellationError {
            return
        } catch {
            guard cycleIsCurrent(scheduledGeneration) else { return }
            logger.warning("automatic node failover failed: \(error.localizedDescription)")
            publish(AutoNodeSwitchUpdate(outcome: .failed(node: currentNode)))
            finishCycle(generation: scheduledGeneration, nextDelay: Self.networkRetryDelay)
        }
    }

    private func publish(_ update: AutoNodeSwitchUpdate) {
        for continuation in updateContinuations.values { continuation.yield(update) }
    }

    private func recentlyUnavailableNodes(in validNodes: Set<String>, now: Date = Date()) -> Set<String> {
        failedNodeDeadlines = failedNodeDeadlines.filter { validNodes.contains($0.key) && $0.value > now }
        return Set(failedNodeDeadlines.keys)
    }

    private func removeUpdateContinuation(_ identifier: UUID) {
        updateContinuations.removeValue(forKey: identifier)
    }
}

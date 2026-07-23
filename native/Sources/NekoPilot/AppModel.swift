import AppKit
import Combine
import Foundation
import NekoPilotCore
import Darwin

enum MainTab: String, CaseIterable, Identifiable {
    case home, nodes, rules, settings
    var id: String { rawValue }
}

struct PendingDeepLink: Identifiable, Equatable {
    let id = UUID()
    let input: String
    let shouldConnect: Bool
}

enum URLTestStopPolicy: Equatable {
    case keepPartialResults
    case restorePreviousResults
}

@MainActor
final class AppModel: ObservableObject {
    private static let successfulLocationLifetime: TimeInterval = 30 * 24 * 60 * 60
    private static let failedLocationRetryDelay: TimeInterval = 6 * 60 * 60

    @Published var status: EngineStatus = .stopped
    @Published var nodes: [ProxyNode] = []
    @Published private(set) var sortedNodes: [ProxyNode] = []
    @Published private(set) var nodeRows: [NodeListRow] = []
    @Published private(set) var nodeCountsBySource: [String: Int] = [:]
    @Published var subscriptions: [NekoPilotCore.Subscription] = []
    @Published var selectedNode: String?
    @Published var delayHistory: [String: DelayRecord] = [:]
    @Published private(set) var currentNodeTraffic = NodeTrafficSnapshot.zero
    @Published var isURLTesting = false
    @Published var selectedTab: MainTab = .home
    @Published var errorMessage: String?
    @Published var rules: [RoutingRule] = []
    @Published var autoSwitch = true
    @Published var showProtocol = false
    @Published var showServerLocation = false
    @Published private(set) var nodeLocations: [String: NodeLocationRecord] = [:]
    @Published private(set) var isNodeLocationProbing = false
    @Published private(set) var nodeLocationProbeCompleted = 0
    @Published private(set) var nodeLocationProbeTotal = 0
    @Published var allowLAN = false
    @Published var skipSystemProxy = false
    @Published var proxyPort = SettingsStore.defaultProxyPort
    @Published var directDNS = "223.5.5.5"
    @Published var userAgent = "sing-box 1.14.0-alpha.48"
    @Published var isInitialized = false
    @Published var pendingDeepLink: PendingDeepLink?
    @Published var pendingLANEnable = false
    @Published var availableUpdate: GitHubReleaseUpdate?
    @Published private(set) var lastAutomaticSwitchUpdate: AutoNodeSwitchUpdate?
    @Published private(set) var refreshingSubscriptionIDs: Set<String> = []
    @Published private(set) var subscriptionRefreshErrors: [String: String] = [:]

    let paths: AppPaths
    let logger: AppLogger
    let settings: SettingsStore
    let repository: SubscriptionRepository
    let importer: SubscriptionImporter
    let compiler: ConfigurationCompiler
    let nativeAPI: NativeControlClient
    let systemProxy: SystemProxyManager
    let engine: EngineSupervisor
    let tester: URLTester
    let locationProbe: NodeLocationProbe
    let selection: NodeSelectionCoordinator
    let automaticSwitching: AutoNodeSwitchService
    let ruleSetUpdater: RuleSetUpdater
    let releaseChecker: GitHubReleaseChecker
    let networkReadiness = NetworkReadiness()
    private var statusTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var automaticSwitchTask: Task<Void, Never>?
    private var bootstrapTask: Task<Void, Never>?
    private var lanConfirmationTasks: [UUID: Task<Void, Never>] = [:]
    private var deepLinkTasks: [UUID: Task<Void, Never>] = [:]
    private let userActionTaskOwner = UserActionTaskOwner()
    private var urlTestTask: Task<Void, Never>?
    private var nodeLocationTask: Task<Void, Never>?
    private var nodeLocationPredecessorTask: Task<Void, Never>?
    private var trafficTask: Task<Void, Never>?
    private var urlTestProgressFlushTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var ruleUpdateTask: Task<Void, Never>?
    private var releaseCheckTask: Task<Void, Never>?
    private var selectionGeneration = 0
    private var dataRefreshGeneration = 0
    private var urlTestGeneration = 0
    private var nodeLocationGeneration = 0
    private var nodeLocationSettingGeneration = 0
    private var urlTestBaselineHistory: [String: DelayRecord]?
    private var pendingURLTestProgress: [String: DelayRecord] = [:]
    private var ruleUpdateGeneration = 0
    private var sleepStartedAt: Date?
    private var wasRunningBeforeSleep = false
    private var lifecycleGeneration = 0
    private var isShuttingDown = false
    private let storageAvailable: Bool
    private let bootstrapError: String?

    init() throws {
        let storage = try AppStorageBootstrap.resolve()
        paths = storage.paths
        logger = AppLogger()
        logger.configure(destination: paths.logFile)
        settings = storage.settings
        repository = storage.repository
        storageAvailable = storage.isPersistent
        bootstrapError = storage.recoveryMessage
        importer = SubscriptionImporter(repository: repository, settings: settings)
        compiler = ConfigurationCompiler(paths: paths, settings: settings, repository: repository)
        nativeAPI = NativeControlClient(logger: logger)
        systemProxy = SystemProxyManager(markerURL: paths.proxyOwnership, logger: logger)
        engine = EngineSupervisor(
            settings: settings,
            compiler: compiler,
            systemProxy: systemProxy,
            nativeAPI: nativeAPI,
            ownershipURL: paths.engineOwnership,
            logger: logger
        )
        tester = URLTester(compiler: compiler, logger: logger)
        locationProbe = NodeLocationProbe(compiler: compiler)
        selection = NodeSelectionCoordinator(engine: engine, settings: settings)
        automaticSwitching = AutoNodeSwitchService(
            engine: engine,
            repository: repository,
            settings: settings,
            tester: tester,
            nativeAPI: nativeAPI,
            selection: selection,
            networkReadiness: networkReadiness,
            logger: logger
        )
        ruleSetUpdater = RuleSetUpdater(paths: paths, logger: logger)
        releaseChecker = GitHubReleaseChecker(settings: settings, logger: logger)
    }

    deinit {
        statusTask?.cancel()
        selectionTask?.cancel()
        automaticSwitchTask?.cancel()
        bootstrapTask?.cancel()
        lanConfirmationTasks.values.forEach { $0.cancel() }
        deepLinkTasks.values.forEach { $0.cancel() }
        trafficTask?.cancel()
        urlTestTask?.cancel()
        nodeLocationTask?.cancel()
        nodeLocationPredecessorTask?.cancel()
        urlTestProgressFlushTask?.cancel()
        wakeTask?.cancel()
        ruleUpdateTask?.cancel()
        releaseCheckTask?.cancel()
    }

    func initialize() {
        guard !isInitialized else { return }
        isInitialized = true
        statusTask = Task { [weak self] in
            guard let self else { return }
            let stream = await engine.states()
            for await next in stream {
                guard !Task.isCancelled else { return }
                status = next
                if case let .failed(message) = next, errorMessage == nil {
                    errorMessage = message
                }
                await automaticSwitching.updateConnectionState(isRunning: next.isRunning)
                if next.isRunning {
                    startTrafficMonitoring()
                    scheduleRuleSetRefresh()
                } else {
                    stopTrafficMonitoring()
                    ruleUpdateTask?.cancel()
                    ruleUpdateTask = nil
                }
            }
        }
        selectionTask = Task { [weak self] in
            guard let self else { return }
            let stream = await selection.selections()
            for await node in stream {
                guard !Task.isCancelled else { return }
                // Invalidate any optimistic request that was waiting for the
                // coordinator while this authoritative selection committed.
                selectionGeneration += 1
                selectedNode = node
                currentNodeTraffic = .zero
                rebuildSortedNodes()
            }
        }
        automaticSwitchTask = Task { [weak self] in
            guard let self else { return }
            let stream = await automaticSwitching.updates()
            for await update in stream {
                guard !Task.isCancelled else { return }
                lastAutomaticSwitchUpdate = update
                rebuildSortedNodes()
            }
        }
        bootstrapTask = Task { [weak self] in
            guard let self else { return }
            await engine.recoverOwnedProcess()
            await engine.recoverSystemProxy()
            guard !Task.isCancelled, !isShuttingDown else { return }
            guard storageAvailable else {
                if let bootstrapError { errorMessage = bootstrapError }
                return
            }
            await loadSettings()
            guard !Task.isCancelled, !isShuttingDown else { return }
            await refreshData()
            guard !Task.isCancelled, !isShuttingDown else { return }
            let engineRunning = await engine.currentStatus().isRunning
            guard !Task.isCancelled, !isShuttingDown else { return }
            await automaticSwitching.start(enabled: autoSwitch, engineRunning: engineRunning)
            guard !Task.isCancelled, !isShuttingDown else { return }
            scheduleReleaseCheck()
        }
    }

    /// Registers business work initiated by a view with the application
    /// lifecycle. Views still own presentation-only tasks such as animation
    /// timers, while storage, settings, and engine mutations come through this
    /// entry point so shutdown can cancel and await them before stopping the
    /// core.
    func performUserAction(
        _ operation: @escaping @MainActor (AppModel) async -> Void
    ) {
        guard !isShuttingDown else { return }
        userActionTaskOwner.submit { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, !isShuttingDown else { return }
            await operation(self)
        }
    }

    func refreshData() async {
        guard storageAvailable, !isShuttingDown else { return }
        // Node-source mutations may keep a runtime tag while changing its
        // endpoint. Stop the old generation before reading the new snapshot;
        // completed results stay in SQLite and are picked up below.
        let interruptedLocationTask = cancelNodeLocationProbe(resetProgress: false)
        dataRefreshGeneration += 1
        let generation = dataRefreshGeneration
        do {
            let previousTags = Set(nodes.map(\.runtimeTag))
            async let loadedNodes = repository.nodes()
            async let loadedSources = repository.subscriptions()
            let refreshedNodes = try await loadedNodes
            let refreshedSources = try await loadedSources
            guard generation == dataRefreshGeneration, !isShuttingDown else { return }
            nodes = refreshedNodes
            subscriptions = refreshedSources
            rebuildNodeCounts()
            let availableTags = Set(nodes.map(\.runtimeTag))
            if previousTags != availableTags { lastAutomaticSwitchUpdate = nil }
            var refreshedHistory = try await repository.pruneDelayHistory(retaining: availableTags)
            guard generation == dataRefreshGeneration, !isShuttingDown else { return }
            // A source refresh can finish while an explicit URL Test is still
            // streaming progress. Keep newer in-memory measurements visible;
            // the completed test will persist them atomically afterwards.
            for (tag, record) in delayHistory where availableTags.contains(tag) {
                if let persisted = refreshedHistory[tag], persisted.measuredAt >= record.measuredAt { continue }
                refreshedHistory[tag] = record
            }
            delayHistory = refreshedHistory
            do {
                nodeLocations = try await repository.nodeLocationCache(retaining: nodes)
            } catch {
                // Location metadata is optional presentation state. A cache
                // read must never prevent the freshly imported nodes from
                // becoming usable.
                logger.warning("server-location cache refresh failed: \(error.localizedDescription)")
                let currentNodes = nodes.reduce(into: [String: String]()) {
                    $0[$1.runtimeTag] = $1.locationFingerprint
                }
                nodeLocations = nodeLocations.filter { tag, record in
                    currentNodes[tag] == record.fingerprint
                }
            }
            guard generation == dataRefreshGeneration, !isShuttingDown else { return }
            if selectedNode == nil || !nodes.contains(where: { $0.runtimeTag == selectedNode }) {
                selectedNode = nodes.first?.runtimeTag
                // A user selection may interleave while the actor-backed
                // preferences write is suspended. Keep writing the current
                // value until the state observed before the write still
                // matches afterwards, so an older fallback can never replace
                // a newer manual choice on disk.
                while !isShuttingDown {
                    let value = selectedNode
                    try await settings.set(value.map(JSONValue.string), for: SettingsStore.Key.selectedNode)
                    if value == selectedNode { break }
                }
                guard generation == dataRefreshGeneration, !isShuttingDown else { return }
            }
            rebuildSortedNodes()
            await automaticSwitching.nodesDidChange()
            if status.isRunning { startTrafficMonitoring() }
            scheduleNodeLocationProbeIfNeeded(waitingFor: interruptedLocationTask)
        } catch {
            scheduleNodeLocationProbeIfNeeded(waitingFor: interruptedLocationTask)
            show(error)
        }
    }

    func toggleConnection() async {
        guard storageAvailable, !isShuttingDown else {
            if let bootstrapError { errorMessage = bootstrapError }
            return
        }
        let engineStatus = await engine.currentStatus()
        if engineStatus.isRunning || engineStatus.isBusy {
            await engine.stop()
            return
        }
        guard !nodes.isEmpty else {
            show(NekoPilotError.noNodes)
            selectedTab = .nodes
            return
        }
        do {
            let target = selectedNode ?? nodes.first?.runtimeTag
            if selectedNode != target {
                let previous = selectedNode
                selectionGeneration += 1
                let generation = selectionGeneration
                selectedNode = target
                rebuildSortedNodes()
                do {
                    try await settings.set(target.map(JSONValue.string), for: SettingsStore.Key.selectedNode)
                } catch {
                    if selectionGeneration == generation {
                        selectedNode = previous
                        rebuildSortedNodes()
                    }
                    throw error
                }
            }
            try await engine.start(selectedNode: selectedNode ?? target)
        } catch is CancellationError {
            return
        } catch {
            show(error)
        }
    }

    func selectNode(_ node: ProxyNode) async {
        let engineStatus = await engine.currentStatus()
        guard storageAvailable, !isShuttingDown, !engineStatus.isBusy else { return }
        selectionGeneration += 1
        let generation = selectionGeneration
        selectedNode = node.runtimeTag
        currentNodeTraffic = .zero
        rebuildSortedNodes()
        do {
            let applied = try await selection.submit(node: node.runtimeTag)
            if !applied {
                // A newer manual tap superseded this optimistic request before
                // it committed. Reconcile from disk unless the newer request
                // has already advanced the local generation.
                await restoreCommittedSelection(ifCurrent: generation)
            } else if autoSwitch {
                lastAutomaticSwitchUpdate = nil
                await automaticSwitching.manualSelectionDidApply()
            }
        } catch is CancellationError {
            await restoreCommittedSelection(ifCurrent: generation)
        } catch {
            await restoreCommittedSelection(ifCurrent: generation)
            show(error)
        }
    }

    func runURLTest() {
        guard !isURLTesting, !nodes.isEmpty else { return }
        // Explicit speed tests have priority over optional location discovery.
        // Wait for cancelled workers to exit before creating another isolated
        // sing-box pool, otherwise the two background features can briefly
        // double their process and memory footprint.
        let interruptedLocationTask = cancelNodeLocationProbe()
        urlTestTask?.cancel()
        urlTestGeneration += 1
        let generation = urlTestGeneration
        isURLTesting = true
        urlTestBaselineHistory = delayHistory
        let snapshot = nodes
        urlTestProgressFlushTask?.cancel()
        urlTestProgressFlushTask = nil
        pendingURLTestProgress.removeAll(keepingCapacity: true)
        urlTestTask = Task { [weak self] in
            guard let self else { return }
            await interruptedLocationTask?.value
            guard generation == urlTestGeneration, isURLTesting else { return }
            await automaticSwitching.setExplicitTestActive(true)
            guard generation == urlTestGeneration, isURLTesting else { return }
            defer {
                if generation == urlTestGeneration {
                    isURLTesting = false
                    urlTestTask = nil
                    urlTestBaselineHistory = nil
                    scheduleNodeLocationProbeIfNeeded()
                }
            }
            let results = await tester.test(
                nodes: snapshot
            ) { [weak self] tag, record in
                await self?.enqueueURLTestProgress(tag: tag, record: record, generation: generation)
            }
            // An older cancelled task may finish after a new user test starts.
            // Only the current generation may resume background health checks.
            if generation == urlTestGeneration {
                await automaticSwitching.setExplicitTestActive(false)
            }
            guard !Task.isCancelled, generation == urlTestGeneration else { return }
            flushURLTestProgress(generation: generation)
            do {
                let validTags = Set(nodes.map(\.runtimeTag))
                delayHistory = try await repository.mergeDelayHistory(results, retaining: validTags)
                rebuildSortedNodes()
            } catch {
                show(error)
            }
        }
    }

    private func enqueueURLTestProgress(tag: String, record: DelayRecord, generation: Int) {
        guard generation == urlTestGeneration, isURLTesting else { return }
        pendingURLTestProgress[tag] = record
        guard urlTestProgressFlushTask == nil else { return }
        urlTestProgressFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            self?.flushURLTestProgress(generation: generation)
        }
    }

    private func flushURLTestProgress(generation: Int) {
        urlTestProgressFlushTask = nil
        guard generation == urlTestGeneration, isURLTesting, !pendingURLTestProgress.isEmpty else { return }
        delayHistory.merge(pendingURLTestProgress, uniquingKeysWith: { _, newer in newer })
        pendingURLTestProgress.removeAll(keepingCapacity: true)
        rebuildSortedNodes()
    }

    /// Stops an explicit user test using the choice made in the confirmation
    /// dialog. Keeping partial results persists every completed measurement;
    /// restoring discards them and returns both UI and disk to the pre-test
    /// snapshot.
    func cancelURLTest(policy: URLTestStopPolicy) async {
        guard isURLTesting else { return }
        urlTestProgressFlushTask?.cancel()
        urlTestProgressFlushTask = nil
        if policy == .keepPartialResults {
            flushURLTestProgress(generation: urlTestGeneration)
        }
        let baseline = urlTestBaselineHistory ?? delayHistory
        urlTestGeneration += 1
        urlTestTask?.cancel()
        urlTestTask = nil
        await automaticSwitching.setExplicitTestActive(false)
        pendingURLTestProgress.removeAll(keepingCapacity: true)
        urlTestBaselineHistory = nil
        isURLTesting = false
        defer {
            rebuildSortedNodes()
            scheduleNodeLocationProbeIfNeeded()
        }
        do {
            let validTags = Set(nodes.map(\.runtimeTag))
            switch policy {
            case .keepPartialResults:
                delayHistory = try await repository.mergeDelayHistory(delayHistory, retaining: validTags)
            case .restorePreviousResults:
                let restored = baseline.filter { validTags.contains($0.key) }
                delayHistory = restored
                try await repository.replaceDelayHistory(restored)
            }
        } catch {
            show(error)
        }
    }

    func importNode(_ input: String, name: String?) async -> Bool {
        guard storageAvailable, !isShuttingDown else { return false }
        do {
            let identifier = try await importer.importInput(input, name: name)
            try await ImportedNodePostprocessor.run(
                refresh: { await self.refreshData() },
                resolveNode: { self.nodes.first(where: { $0.sourceIdentifier == identifier }) },
                isEngineRunning: { await self.engine.currentStatus().isRunning },
                reload: { try await self.reloadRunningEngine(selectedNode: $0.runtimeTag) },
                select: { await self.selectNode($0) },
                isShuttingDown: { self.isShuttingDown }
            )
            return true
        } catch is CancellationError {
            return false
        } catch {
            show(error)
            return false
        }
    }

    func refresh(_ subscription: NekoPilotCore.Subscription) async {
        guard storageAvailable, !isShuttingDown,
              subscription.sourceType == .subscription,
              refreshingSubscriptionIDs.insert(subscription.identifier).inserted else { return }
        defer { refreshingSubscriptionIDs.remove(subscription.identifier) }
        do {
            try await importer.refresh(identifier: subscription.identifier)
            try Task.checkCancellation()
            guard !isShuttingDown else { throw CancellationError() }
            subscriptionRefreshErrors.removeValue(forKey: subscription.identifier)
            await refreshData()
            try Task.checkCancellation()
            guard !isShuttingDown else { throw CancellationError() }
            if await engine.currentStatus().isRunning {
                try Task.checkCancellation()
                try await reloadRunningEngine(selectedNode: selectedNode)
            }
        } catch is CancellationError {
            return
        } catch {
            subscriptionRefreshErrors[subscription.identifier] = error.localizedDescription
            show(error)
        }
    }

    func edit(_ subscription: NekoPilotCore.Subscription, name: String, input: String) async -> Bool {
        guard storageAvailable, !isShuttingDown else { return false }
        do {
            let replacement = try await importer.replace(
                identifier: subscription.identifier,
                rawInput: input,
                name: name
            )
            try Task.checkCancellation()
            guard !isShuttingDown else { throw CancellationError() }
            await refreshData()
            try Task.checkCancellation()
            guard !isShuttingDown else { throw CancellationError() }
            if replacement == .contentChanged, await engine.currentStatus().isRunning {
                try Task.checkCancellation()
                try await reloadRunningEngine(selectedNode: selectedNode)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            show(error)
            return false
        }
    }

    func delete(_ subscription: NekoPilotCore.Subscription) async {
        guard storageAvailable, !isShuttingDown else { return }
        do {
            try await repository.delete(identifier: subscription.identifier)
            try Task.checkCancellation()
            guard !isShuttingDown else { throw CancellationError() }
            await refreshData()
            try Task.checkCancellation()
            guard !isShuttingDown else { throw CancellationError() }
            if await engine.currentStatus().isRunning {
                try Task.checkCancellation()
                try await reloadRunningEngine(selectedNode: selectedNode)
            }
        } catch is CancellationError {
            return
        } catch {
            show(error)
        }
    }

    func addRules(action: RuleAction, kind: RuleKind, input: String) async -> RuleBatchMutation? {
        let previous = rules
        do {
            let mutation = try RuleMutation.add(to: rules, action: action, kind: kind, rawInput: input)
            rules = mutation.rules
            return await persistRules(previous: previous) ? mutation : nil
        } catch {
            show(error)
            return nil
        }
    }

    @discardableResult
    func deleteRule(_ rule: RoutingRule) async -> Bool {
        let previous = rules
        rules.removeAll { $0.id == rule.id }
        return await persistRules(previous: previous)
    }

    @discardableResult
    func restoreRule(_ rule: RoutingRule) async -> Bool {
        guard !rules.contains(where: { $0.id == rule.id }) else { return true }
        let previous = rules
        rules.append(rule)
        rules = RuleMutation.sorted(rules)
        return await persistRules(previous: previous)
    }

    func updateRule(
        _ rule: RoutingRule,
        action: RuleAction,
        kind: RuleKind,
        value: String
    ) async -> RuleEditMutation? {
        let previous = rules
        do {
            let mutation = try RuleMutation.update(
                in: rules,
                original: rule,
                action: action,
                kind: kind,
                value: value
            )
            if mutation.unchanged { return mutation }
            rules = mutation.rules
            return await persistRules(previous: previous) ? mutation : nil
        } catch {
            show(error)
            return nil
        }
    }

    func setAutoSwitch(_ value: Bool) async {
        guard !isShuttingDown else { return }
        let previous = autoSwitch
        autoSwitch = value
        // Disabling must cancel an in-flight cycle before the preference write
        // touches disk; otherwise a slow filesystem could still allow one last
        // unexpected automatic switch after the user turned the feature off.
        if !value { await automaticSwitching.setAutomaticSwitchingEnabled(false) }
        await selection.setAutomaticSwitchingEnabled(value)
        do {
            try await settings.set(.bool(value), for: SettingsStore.Key.autoSwitch)
            try Task.checkCancellation()
            guard !isShuttingDown else { throw CancellationError() }
            lastAutomaticSwitchUpdate = nil
            if value { await automaticSwitching.setAutomaticSwitchingEnabled(true) }
        } catch is CancellationError where isShuttingDown {
            return
        } catch {
            autoSwitch = previous
            await selection.setAutomaticSwitchingEnabled(previous)
            await automaticSwitching.setAutomaticSwitchingEnabled(previous)
            show(error)
        }
    }

    func setShowProtocol(_ value: Bool) async {
        guard !isShuttingDown else { return }
        let previous = showProtocol
        showProtocol = value
        do {
            try await settings.set(.bool(value), for: SettingsStore.Key.showProtocol)
        } catch is CancellationError where isShuttingDown {
            return
        } catch {
            showProtocol = previous
            show(error)
        }
    }

    func setShowServerLocation(_ value: Bool) async {
        guard !isShuttingDown else { return }
        nodeLocationSettingGeneration += 1
        let settingGeneration = nodeLocationSettingGeneration
        let previous = showServerLocation
        showServerLocation = value
        let interrupted = value ? nil : (cancelNodeLocationProbe() ?? nodeLocationPredecessorTask)
        do {
            try await settings.set(.bool(value), for: SettingsStore.Key.showServerLocation)
            try Task.checkCancellation()
            guard settingGeneration == nodeLocationSettingGeneration, !isShuttingDown else { return }
            if value {
                do {
                    nodeLocations = try await repository.nodeLocationCache(retaining: nodes)
                } catch {
                    logger.warning("server-location cache load failed: \(error.localizedDescription)")
                }
                guard settingGeneration == nodeLocationSettingGeneration, showServerLocation else { return }
                scheduleNodeLocationProbeIfNeeded(forceRetryFailures: !previous)
            } else {
                await interrupted?.value
                guard settingGeneration == nodeLocationSettingGeneration,
                      !showServerLocation,
                      nodeLocationTask == nil else { return }
                nodeLocationPredecessorTask = nil
            }
        } catch is CancellationError where isShuttingDown {
            return
        } catch {
            guard settingGeneration == nodeLocationSettingGeneration else { return }
            showServerLocation = previous
            if previous {
                scheduleNodeLocationProbeIfNeeded()
            } else {
                cancelNodeLocationProbe()
            }
            show(error)
        }
    }

    func setAllowLAN(_ value: Bool) async {
        if value, !allowLAN {
            pendingLANEnable = true
            return
        }
        await applyAllowLAN(value)
    }

    func confirmAllowLAN() {
        pendingLANEnable = false
        lanConfirmationTasks.values.forEach { $0.cancel() }
        let identifier = UUID()
        lanConfirmationTasks[identifier] = Task { [weak self] in
            guard let self, !Task.isCancelled, !isShuttingDown else { return }
            defer { lanConfirmationTasks[identifier] = nil }
            await applyAllowLAN(true)
        }
    }

    func cancelAllowLAN() {
        pendingLANEnable = false
    }

    func openAvailableUpdate() {
        guard let update = availableUpdate else { return }
        availableUpdate = nil
        NSWorkspace.shared.open(update.url)
    }

    func dismissAvailableUpdate() {
        availableUpdate = nil
    }

    private func applyAllowLAN(_ value: Bool) async {
        guard !isShuttingDown else { return }
        let previous = allowLAN
        let wasRunning = await engine.currentStatus().isRunning
        allowLAN = value
        do {
            try await settings.set(.bool(value), for: SettingsStore.Key.allowLAN)
            try await applyConnectionSettingChange()
        } catch {
            if error is CancellationError, isShuttingDown { return }
            allowLAN = previous
            try? await settings.set(.bool(previous), for: SettingsStore.Key.allowLAN)
            await restoreConnectionIfNeeded(wasRunning)
            show(error)
        }
    }

    func setSkipSystemProxy(_ value: Bool) async {
        guard !isShuttingDown else { return }
        let previous = skipSystemProxy
        let wasRunning = await engine.currentStatus().isRunning
        skipSystemProxy = value
        do {
            try await settings.set(.bool(value), for: SettingsStore.Key.skipSystemProxy)
            try await applyConnectionSettingChange()
        } catch {
            if error is CancellationError, isShuttingDown { return }
            skipSystemProxy = previous
            try? await settings.set(.bool(previous), for: SettingsStore.Key.skipSystemProxy)
            await restoreConnectionIfNeeded(wasRunning)
            show(error)
        }
    }

    func setProxyPort(_ value: Int) async -> Bool {
        guard !isShuttingDown else { return false }
        guard (1 ... 65_535).contains(value) else {
            show(NekoPilotError.invalidSetting("proxy_port"))
            return false
        }
        let previous = proxyPort
        let wasRunning = await engine.currentStatus().isRunning
        proxyPort = value
        do {
            try await settings.set(.number(Double(value)), for: SettingsStore.Key.proxyPort)
            try await applyConnectionSettingChange()
            return true
        } catch {
            if error is CancellationError, isShuttingDown { return false }
            proxyPort = previous
            try? await settings.set(.number(Double(previous)), for: SettingsStore.Key.proxyPort)
            await restoreConnectionIfNeeded(wasRunning)
            show(error)
            return false
        }
    }

    func setDirectDNS(_ value: String) async -> Bool {
        guard !isShuttingDown else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = directDNS
        let wasRunning = await engine.currentStatus().isRunning
        directDNS = trimmed
        do {
            try await settings.set(.string(trimmed), for: SettingsStore.Key.directDNS)
            try await applyConnectionSettingChange()
            return true
        } catch {
            if error is CancellationError, isShuttingDown { return false }
            directDNS = previous
            try? await settings.set(.string(previous), for: SettingsStore.Key.directDNS)
            await restoreConnectionIfNeeded(wasRunning)
            show(error)
            return false
        }
    }

    func setUserAgent(_ value: String) async -> Bool {
        guard !isShuttingDown else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = userAgent
        userAgent = trimmed
        do {
            try await settings.set(.string(trimmed), for: SettingsStore.Key.userAgent)
            return true
        } catch is CancellationError where isShuttingDown {
            return true
        } catch {
            userAgent = previous
            show(error)
            return false
        }
    }

    func handleSleep() async {
        guard !isShuttingDown else { return }
        wakeTask?.cancel()
        wakeTask = nil
        sleepStartedAt = Date()
        wasRunningBeforeSleep = await engine.currentStatus().isRunning
        lifecycleGeneration += 1
        // Awaiting the actor call preserves event order: a subsequent wake can
        // enqueue only after this suspension request, so it always owns the
        // final lifecycle state instead of racing an untracked sleep Task.
        await automaticSwitching.setLifecycleSuspended(true)
    }

    func handleWake() async {
        guard !isShuttingDown else { return }
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        guard wasRunningBeforeSleep,
              let sleepStartedAt,
              Date().timeIntervalSince(sleepStartedAt) >= 30 else {
            await automaticSwitching.setLifecycleSuspended(false)
            return
        }
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard generation == lifecycleGeneration else { return }
            guard await networkReadiness.waitUntilReady() else {
                logger.warning("wake restart deferred because network is not ready")
                await automaticSwitching.setLifecycleSuspended(false)
                return
            }
            guard generation == lifecycleGeneration else { return }
            await engine.restartAfterLifecycleEvent(selectedNode: selectedNode)
            await automaticSwitching.setLifecycleSuspended(false)
        }
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme == "nekopilot", url.host == "config",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encoded = components.queryItems?.first(where: { $0.name == "data" })?.value,
              encoded.utf8.count <= 64 * 1024 else { return }
        let apply = components.queryItems?.first(where: { $0.name == "apply" })?.value == "1"
        var normalized = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let data = Data(base64Encoded: normalized), let input = String(data: data, encoding: .utf8) else { return }
        // A custom URL may be opened by an arbitrary web page. Importing and
        // especially taking over the system proxy always requires an explicit
        // confirmation in the native shell.
        pendingDeepLink = PendingDeepLink(input: input, shouldConnect: apply)
    }

    func confirmDeepLink() {
        guard let request = pendingDeepLink else { return }
        pendingDeepLink = nil
        deepLinkTasks.values.forEach { $0.cancel() }
        let identifier = UUID()
        deepLinkTasks[identifier] = Task { [weak self] in
            guard let self else { return }
            defer { deepLinkTasks[identifier] = nil }
            guard !Task.isCancelled, !isShuttingDown else { return }
            guard await importNode(request.input, name: nil) else { return }
            guard !Task.isCancelled, !isShuttingDown else { return }
            if request.shouldConnect, !(await engine.currentStatus().isRunning) {
                await toggleConnection()
            }
        }
    }

    func cancelDeepLink() {
        pendingDeepLink = nil
    }

    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        lifecycleGeneration += 1
        let bootstrapping = bootstrapTask
        let confirmingLAN = Array(lanConfirmationTasks.values)
        let importingDeepLink = Array(deepLinkTasks.values)
        bootstrapping?.cancel()
        confirmingLAN.forEach { $0.cancel() }
        importingDeepLink.forEach { $0.cancel() }
        userActionTaskOwner.cancelAll()
        bootstrapTask = nil
        lanConfirmationTasks.removeAll()
        deepLinkTasks.removeAll()
        wakeTask?.cancel()
        wakeTask = nil
        // Join view-launched mutations before running shutdown's own URL-test
        // transaction or tearing down the engine. This also prevents a user
        // "keep results" action from racing the identical quit-time action.
        await userActionTaskOwner.cancelAndWait()
        let testing = urlTestTask
        if isURLTesting {
            // Quitting is the only non-user navigation event that must stop a
            // test. Persist completed work so the next launch matches the last
            // results the user saw instead of silently reverting to disk.
            await cancelURLTest(policy: .keepPartialResults)
        } else {
            testing?.cancel()
            urlTestTask = nil
        }
        // Location discovery is optional and owns only disposable workers.
        // Start cancellation now, finish the critical engine/system-proxy
        // cleanup first, then wait for the disposable workers so the process
        // cannot exit while a child sing-box instance is still unwinding.
        let locating = cancelNodeLocationProbe() ?? nodeLocationPredecessorTask
        statusTask?.cancel()
        selectionTask?.cancel()
        automaticSwitchTask?.cancel()
        stopTrafficMonitoring()
        ruleUpdateTask?.cancel()
        ruleUpdateTask = nil
        releaseCheckTask?.cancel()
        releaseCheckTask = nil
        // Every view-launched storage/settings/runtime mutation must quiesce
        // before the engine is torn down. Import and configuration boundaries
        // cooperate with cancellation, so no task can resume after shutdown
        // and write state or restart the core.
        await bootstrapping?.value
        for task in confirmingLAN { await task.value }
        for task in importingDeepLink { await task.value }
        await automaticSwitching.stop()
        // Releasing the system proxy and the long-lived sing-box process is
        // the only shutdown work that must finish before the app may exit.
        // Network-backed maintenance tasks can take until their URLSession
        // timeout even after cancellation, so they must never stand in front
        // of engine cleanup.
        logger.info("shutdown: stopping proxy engine")
        await engine.shutdown()
        logger.info("shutdown: proxy engine stopped")
        await testing?.value
        await locating?.value
        nodeLocationPredecessorTask = nil
        // Rule-set refresh owns no child process or system state. URLSession
        // cancellation is enough here; waiting for a remote server timeout
        // would make the app appear stuck after all critical cleanup finished.
        logger.info("shutdown: critical cleanup complete")
    }

    private func rebuildSortedNodes() {
        nodeRows = NodeListPresentation.rows(nodes, using: delayHistory, pinning: selectedNode)
        sortedNodes = nodeRows.map(\.node)
    }

    private func rebuildNodeCounts() {
        nodeCountsBySource = NodeListPresentation.countsBySource(nodes)
    }

    @discardableResult
    private func cancelNodeLocationProbe(resetProgress: Bool = true) -> Task<Void, Never>? {
        nodeLocationGeneration += 1
        let interrupted = nodeLocationTask
        interrupted?.cancel()
        if let interrupted { nodeLocationPredecessorTask = interrupted }
        nodeLocationTask = nil
        isNodeLocationProbing = false
        if resetProgress {
            nodeLocationProbeCompleted = 0
            nodeLocationProbeTotal = 0
        }
        return interrupted
    }

    private func scheduleNodeLocationProbeIfNeeded(
        waitingFor interruptedTask: Task<Void, Never>? = nil,
        forceRetryFailures: Bool = false
    ) {
        // Always cancel the task that is active *now*. A refresh may have
        // captured an older task before suspending on repository I/O while a
        // toggle or completed URL Test started a newer one in the meantime.
        // The active task already waits for its predecessor, so waiting for it
        // serializes the complete cleanup chain and keeps every worker tracked.
        let activeTask = cancelNodeLocationProbe(resetProgress: false)
        let previousTask = activeTask ?? nodeLocationPredecessorTask ?? interruptedTask
        guard showServerLocation, !isURLTesting, !isShuttingDown, !nodes.isEmpty else {
            nodeLocationProbeCompleted = 0
            nodeLocationProbeTotal = 0
            return
        }

        let now = Date()
        let candidates = nodes.filter { node in
            guard let record = nodeLocations[node.runtimeTag],
                  record.fingerprint == node.locationFingerprint else { return true }
            if record.countryCode != nil, let locatedAt = record.locatedAt {
                guard now.timeIntervalSince(locatedAt) >= Self.successfulLocationLifetime else {
                    return false
                }
                // A failed refresh keeps the previous successful country for
                // display. Its newer attempt timestamp still applies the
                // six-hour retry backoff.
                return forceRetryFailures
                    || now.timeIntervalSince(record.lastAttemptAt) >= Self.failedLocationRetryDelay
            }
            return forceRetryFailures
                || now.timeIntervalSince(record.lastAttemptAt) >= Self.failedLocationRetryDelay
        }

        guard !candidates.isEmpty else {
            isNodeLocationProbing = false
            nodeLocationProbeCompleted = 0
            nodeLocationProbeTotal = 0
            return
        }

        nodeLocationGeneration += 1
        let generation = nodeLocationGeneration
        nodeLocationProbeCompleted = 0
        nodeLocationProbeTotal = candidates.count
        isNodeLocationProbing = true
        nodeLocationTask = Task { [weak self] in
            guard let self else { return }
            await previousTask?.value
            guard !Task.isCancelled,
                  generation == nodeLocationGeneration,
                  showServerLocation,
                  !isURLTesting,
                  !isShuttingDown else { return }
            nodeLocationPredecessorTask = nil
            // Candidate failover may start its own isolated URL-Test workers.
            // Pause it while location workers are alive to keep the background
            // process budget bounded and resume it on every cancellation path.
            await automaticSwitching.setExplicitTestActive(true)
            guard !Task.isCancelled,
                  generation == nodeLocationGeneration,
                  showServerLocation,
                  !isURLTesting,
                  !isShuttingDown else {
                await automaticSwitching.setExplicitTestActive(false)
                return
            }
            _ = await locationProbe.probe(nodes: candidates) { [weak self] tag, record in
                await self?.acceptNodeLocation(tag: tag, record: record, generation: generation)
            }
            await automaticSwitching.setExplicitTestActive(false)
            guard !Task.isCancelled, generation == nodeLocationGeneration else { return }
            do {
                let persisted = try await repository.nodeLocationCache(retaining: nodes)
                guard !Task.isCancelled,
                      generation == nodeLocationGeneration,
                      showServerLocation,
                      !isURLTesting,
                      !isShuttingDown else { return }
                // Two workers may finish persistence callbacks in a different
                // order from their UI continuations. Reloading once after the
                // group completes makes the published snapshot authoritative.
                nodeLocations = persisted
            } catch {
                logger.warning("server-location cache reload failed: \(error.localizedDescription)")
            }
            isNodeLocationProbing = false
            nodeLocationTask = nil
        }
    }

    private func acceptNodeLocation(
        tag: String,
        record: NodeLocationRecord,
        generation: Int
    ) async {
        guard generation == nodeLocationGeneration,
              showServerLocation,
              !isURLTesting,
              !isShuttingDown,
              let currentNode = nodes.first(where: { $0.runtimeTag == tag }),
              currentNode.locationFingerprint == record.fingerprint else { return }

        nodeLocationProbeCompleted = min(nodeLocationProbeCompleted + 1, nodeLocationProbeTotal)
        do {
            let persisted = try await repository.mergeNodeLocation(record, for: currentNode)
            guard generation == nodeLocationGeneration,
                  showServerLocation,
                  !isURLTesting,
                  !isShuttingDown,
                  nodes.contains(where: {
                      $0.runtimeTag == tag && $0.locationFingerprint == record.fingerprint
                  }) else { return }
            if let persisted {
                let current = nodeLocations[tag]
                if current == nil || current!.lastAttemptAt <= persisted.lastAttemptAt {
                    nodeLocations[tag] = persisted
                }
            }
        } catch {
            // Country labels are optional metadata. Report the failure in the
            // diagnostic log without interrupting proxy use or showing one
            // alert per node.
            logger.warning("server-location result persistence failed: \(error.localizedDescription)")
        }
    }

    private func startTrafficMonitoring() {
        trafficTask?.cancel()
        currentNodeTraffic = .zero
        let validNodes = Set(nodes.map(\.runtimeTag))
        guard status.isRunning, !validNodes.isEmpty, !isShuttingDown else {
            trafficTask = nil
            return
        }
        trafficTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, status.isRunning, !isShuttingDown {
                do {
                    let stream = try await nativeAPI.nodeTrafficStream(nodes: validNodes)
                    for try await samples in stream {
                        guard !Task.isCancelled, status.isRunning, !isShuttingDown else { return }
                        let next = selectedNode.flatMap { samples[$0] } ?? .zero
                        if next.upload != currentNodeTraffic.upload || next.download != currentNodeTraffic.download {
                            currentNodeTraffic = next
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard status.isRunning, !isShuttingDown else { return }
                    logger.warning("traffic stream interrupted: \(error.localizedDescription)")
                }
                guard !Task.isCancelled, status.isRunning, !isShuttingDown else { return }
                currentNodeTraffic = .zero
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func stopTrafficMonitoring() {
        trafficTask?.cancel()
        trafficTask = nil
        currentNodeTraffic = .zero
    }

    private func restoreCommittedSelection(ifCurrent generation: Int) async {
        let committed = (await settings.string(SettingsStore.Key.selectedNode)).nilIfEmpty
        guard selectionGeneration == generation else { return }
        selectedNode = committed.flatMap { tag in
            nodes.contains(where: { $0.runtimeTag == tag }) ? tag : nil
        } ?? nodes.first?.runtimeTag
        rebuildSortedNodes()
    }

    func displayName(for node: ProxyNode) -> String {
        NodeListPresentation.displayName(for: node)
    }

    func displayNameWithServerLocation(for node: ProxyNode) -> String {
        let name = displayName(for: node)
        guard showServerLocation,
              let record = nodeLocations[node.runtimeTag],
              record.fingerprint == node.locationFingerprint,
              let code = record.countryCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              code.count == 2,
              let country = Locale.autoupdatingCurrent.localizedString(forRegionCode: code),
              !country.isEmpty else { return name }
        return "\(country) · \(name)"
    }

    func sourceName(for node: ProxyNode) -> String {
        subscriptions.first(where: { $0.identifier == node.sourceIdentifier })?.name ?? node.sourceIdentifier
    }

    var automaticSwitchSummary: String {
        if !autoSwitch {
            return L10n.text("已关闭 · 节点失效时不会自动切换", "Off · nodes will not switch automatically after failure")
        }
        guard let update = lastAutomaticSwitchUpdate else {
            return L10n.text("监测当前节点，失效时按已保存的延迟切换", "Monitor the current node and fail over using saved latency results")
        }
        switch update.outcome {
        case .monitoring:
            return L10n.text("当前节点可用 · 持续监测中", "Current node is available · monitoring")
        case .confirming:
            return L10n.text("正在确认当前节点是否失效", "Confirming whether the current node has failed")
        case let .switched(_, node, _):
            return L10n.text("已自动切换：\(displayName(forTag: node))", "Switched automatically: \(displayName(forTag: node))")
        case .unavailable:
            return L10n.text("当前网络或候选节点暂不可用", "The network or candidate nodes are currently unavailable")
        case .failed:
            return L10n.text("节点监测暂时不可用", "Node monitoring is temporarily unavailable")
        }
    }

    var serverLocationSummary: String {
        if isNodeLocationProbing, nodeLocationProbeTotal > 0 {
            return L10n.text(
                "正在通过每个节点的代理出口识别 · \(nodeLocationProbeCompleted)/\(nodeLocationProbeTotal)",
                "Identifying through each node's proxy exit · \(nodeLocationProbeCompleted)/\(nodeLocationProbeTotal)"
            )
        }
        let identified = nodes.reduce(into: 0) { count, node in
            guard let record = nodeLocations[node.runtimeTag],
                  record.fingerprint == node.locationFingerprint,
                  record.countryCode?.isEmpty == false else { return }
            count += 1
        }
        if showServerLocation, !nodes.isEmpty {
            return L10n.text(
                "已通过代理出口识别 \(identified)/\(nodes.count) 个节点",
                "Identified \(identified)/\(nodes.count) nodes through their proxy exits"
            )
        }
        return L10n.text(
            "通过每个节点的代理出口向 Cloudflare 查询国家或地区",
            "Query Cloudflare for a country or region through each node's proxy exit"
        )
    }

    private func displayName(forTag tag: String) -> String {
        nodes.first(where: { $0.runtimeTag == tag }).map(displayName(for:)) ?? tag
    }

    private func loadSettings() async {
        autoSwitch = await settings.bool(SettingsStore.Key.autoSwitch, default: true)
        guard !Task.isCancelled, !isShuttingDown else { return }
        await selection.setAutomaticSwitchingEnabled(autoSwitch)
        guard !Task.isCancelled, !isShuttingDown else { return }
        showProtocol = await settings.bool(SettingsStore.Key.showProtocol)
        guard !Task.isCancelled, !isShuttingDown else { return }
        showServerLocation = await settings.bool(SettingsStore.Key.showServerLocation, default: false)
        guard !Task.isCancelled, !isShuttingDown else { return }
        allowLAN = await settings.bool(SettingsStore.Key.allowLAN)
        guard !Task.isCancelled, !isShuttingDown else { return }
        skipSystemProxy = await settings.bool(SettingsStore.Key.skipSystemProxy)
        guard !Task.isCancelled, !isShuttingDown else { return }
        proxyPort = await settings.proxyPort()
        guard !Task.isCancelled, !isShuttingDown else { return }
        let storedDNS = await settings.string(SettingsStore.Key.directDNS)
        guard !Task.isCancelled, !isShuttingDown else { return }
        if DNSResolverDetector.isUsableIPAddress(storedDNS) {
            directDNS = storedDNS
        } else {
            directDNS = await DNSResolverDetector.detectSystemResolver(logger: logger) ?? DNSResolverDetector.fallback
            guard !Task.isCancelled, !isShuttingDown else { return }
            try? await settings.set(.string(directDNS), for: SettingsStore.Key.directDNS)
            guard !Task.isCancelled, !isShuttingDown else { return }
        }
        userAgent = await settings.string(SettingsStore.Key.userAgent, default: "sing-box 1.14.0-alpha.48")
        guard !Task.isCancelled, !isShuttingDown else { return }
        selectedNode = (await settings.string(SettingsStore.Key.selectedNode)).nilIfEmpty
        guard !Task.isCancelled, !isShuttingDown else { return }
        let storedHistory = (try? await repository.delayHistory()) ?? [:]
        guard !Task.isCancelled, !isShuttingDown else { return }
        let legacyHistory = (try? await settings.takeLegacyDelayHistory()) ?? [:]
        guard !Task.isCancelled, !isShuttingDown else { return }
        if storedHistory.isEmpty, !legacyHistory.isEmpty {
            try? await repository.replaceDelayHistory(legacyHistory)
            guard !Task.isCancelled, !isShuttingDown else { return }
            delayHistory = legacyHistory
        } else {
            delayHistory = storedHistory
        }
        do {
            rules = try await settings.rulesInstallingDefaultsIfNeeded()
        } catch {
            guard !Task.isCancelled, !isShuttingDown else { return }
            rules = await settings.rules()
            guard !Task.isCancelled, !isShuttingDown else { return }
            show(error)
        }
        guard !Task.isCancelled, !isShuttingDown else { return }
        rebuildSortedNodes()
    }

    private func persistRules(previous: [RoutingRule]) async -> Bool {
        guard !Task.isCancelled, !isShuttingDown else {
            rules = previous
            return false
        }
        let wasRunning = await engine.currentStatus().isRunning
        var didPersistRules = false
        do {
            try await settings.replaceRules(rules)
            didPersistRules = true
            if wasRunning {
                try await reloadRunningEngine(selectedNode: selectedNode)
            } else {
                try await engine.prepareConfiguration(selectedNode: selectedNode)
            }
            return true
        } catch let cancellation as CancellationError {
            // Once rules are durable, cancellation means a shutdown or a newer
            // configuration operation superseded only the runtime reload.
            // Rewriting `previous` would overwrite the newer persisted intent.
            if AppRuntimeRecoveryPolicy.keepsPersistedRules(
                after: cancellation,
                didPersist: didPersistRules
            ) {
                return true
            }
            rules = previous
            return false
        } catch {
            rules = previous
            try? await settings.replaceRules(previous)
            if wasRunning {
                do {
                    if await engine.currentStatus().isRunning {
                        try await reloadRunningEngine(selectedNode: selectedNode)
                    } else {
                        try await engine.start(selectedNode: selectedNode)
                    }
                } catch {
                    logger.error("failed to restore previous routing rules: \(error.localizedDescription)")
                }
            } else {
                try? await engine.prepareConfiguration(selectedNode: selectedNode)
            }
            show(error)
            return false
        }
    }

    private func applyConnectionSettingChange() async throws {
        guard !isShuttingDown else { throw CancellationError() }
        if await engine.currentStatus().isRunning {
            await engine.stop()
            guard !isShuttingDown else { throw CancellationError() }
            try await engine.start(selectedNode: selectedNode)
        } else {
            try await engine.prepareConfiguration(selectedNode: selectedNode)
        }
    }

    private func restoreConnectionIfNeeded(_ wasRunning: Bool) async {
        guard !isShuttingDown else { return }
        let engineStatus = await engine.currentStatus()
        guard wasRunning, !engineStatus.isRunning, !engineStatus.isBusy else { return }
        do {
            try await engine.start(selectedNode: selectedNode)
        } catch {
            logger.error("failed to restore previous connection settings: \(error.localizedDescription)")
        }
    }

    private func reloadRunningEngine(selectedNode: String?) async throws {
        guard !isShuttingDown else { throw CancellationError() }
        do {
            try await engine.reload(selectedNode: selectedNode)
        } catch {
            // Only `.reload` failures occur after the validated candidate was
            // committed and SIGHUP was sent. Configuration/startup/control
            // failures leave the existing live file and process untouched.
            guard AppRuntimeRecoveryPolicy.shouldRestartAfterReloadFailure(error),
                  await engine.currentStatus().isRunning else { throw error }
            // A reload request can succeed in sing-box while the short status
            // confirmation is lost, leaving UI and runtime state ambiguous.
            // A bounded full restart gives every source/rule mutation one
            // deterministic final state instead of silently running an older
            // or only partially observed configuration.
            logger.warning("live reload failed; restarting sing-box: \(error.localizedDescription)")
            await engine.stop()
            try await engine.start(selectedNode: selectedNode)
        }
    }

    private func scheduleRuleSetRefresh() {
        guard ruleUpdateTask == nil else { return }
        ruleUpdateGeneration += 1
        let generation = ruleUpdateGeneration
        ruleUpdateTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, status.isRunning, generation == ruleUpdateGeneration {
                let result = await ruleSetUpdater.refreshIfDue()
                guard !Task.isCancelled, generation == ruleUpdateGeneration else { return }
                if result.didUpdate {
                    do {
                        try await reloadRunningEngine(selectedNode: selectedNode)
                    } catch {
                        logger.warning("updated rule sets require a later reload: \(error.localizedDescription)")
                    }
                }
                let delay = result.nextCheckDelay
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
            }
            if generation == ruleUpdateGeneration { ruleUpdateTask = nil }
        }
    }

    private func scheduleReleaseCheck() {
        guard releaseCheckTask == nil else { return }
        releaseCheckTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, !isShuttingDown else { return }
            guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  !version.isEmpty else {
                releaseCheckTask = nil
                return
            }
            availableUpdate = await releaseChecker.checkIfDue(currentVersion: version)
            releaseCheckTask = nil
        }
    }

    private func show(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

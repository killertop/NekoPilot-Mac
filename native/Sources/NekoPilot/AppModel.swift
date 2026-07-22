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
    let settings: SettingsStore
    let repository: SubscriptionRepository
    let importer: SubscriptionImporter
    let compiler: ConfigurationCompiler
    let nativeAPI: NativeControlClient
    let systemProxy: SystemProxyManager
    let engine: EngineSupervisor
    let tester: URLTester
    let selection: NodeSelectionCoordinator
    let automaticSwitching: AutoNodeSwitchService
    let ruleSetUpdater: RuleSetUpdater
    let releaseChecker: GitHubReleaseChecker
    let networkReadiness = NetworkReadiness()
    private var statusTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var automaticSwitchTask: Task<Void, Never>?
    private var urlTestTask: Task<Void, Never>?
    private var trafficTask: Task<Void, Never>?
    private var urlTestProgressFlushTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var ruleUpdateTask: Task<Void, Never>?
    private var releaseCheckTask: Task<Void, Never>?
    private var selectionGeneration = 0
    private var dataRefreshGeneration = 0
    private var urlTestGeneration = 0
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
        settings = storage.settings
        repository = storage.repository
        storageAvailable = storage.isPersistent
        bootstrapError = storage.recoveryMessage
        importer = SubscriptionImporter(repository: repository, settings: settings)
        compiler = ConfigurationCompiler(paths: paths, settings: settings, repository: repository)
        nativeAPI = NativeControlClient()
        systemProxy = SystemProxyManager(markerURL: paths.proxyOwnership)
        engine = EngineSupervisor(
            settings: settings,
            compiler: compiler,
            systemProxy: systemProxy,
            nativeAPI: nativeAPI,
            ownershipURL: paths.engineOwnership
        )
        tester = URLTester(compiler: compiler)
        selection = NodeSelectionCoordinator(engine: engine, settings: settings)
        automaticSwitching = AutoNodeSwitchService(
            engine: engine,
            repository: repository,
            settings: settings,
            tester: tester,
            nativeAPI: nativeAPI,
            selection: selection,
            networkReadiness: networkReadiness
        )
        ruleSetUpdater = RuleSetUpdater(paths: paths)
        releaseChecker = GitHubReleaseChecker(settings: settings)
        AppLogger.shared.configure(destination: paths.logFile)
    }

    deinit {
        statusTask?.cancel()
        selectionTask?.cancel()
        automaticSwitchTask?.cancel()
        trafficTask?.cancel()
        urlTestTask?.cancel()
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
        Task { [weak self] in
            guard let self else { return }
            await engine.recoverOwnedProcess()
            await engine.recoverSystemProxy()
            guard storageAvailable else {
                if let bootstrapError { errorMessage = bootstrapError }
                return
            }
            await loadSettings()
            await refreshData()
            await automaticSwitching.start(enabled: autoSwitch, engineRunning: status.isRunning)
            scheduleReleaseCheck()
        }
    }

    func refreshData() async {
        guard storageAvailable, !isShuttingDown else { return }
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
        } catch {
            show(error)
        }
    }

    func toggleConnection() async {
        guard storageAvailable, !isShuttingDown else {
            if let bootstrapError { errorMessage = bootstrapError }
            return
        }
        if status.isRunning || status.isBusy {
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
        guard storageAvailable, !isShuttingDown, !status.isBusy else { return }
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
            guard generation == urlTestGeneration, isURLTesting else { return }
            await automaticSwitching.setExplicitTestActive(true)
            guard generation == urlTestGeneration, isURLTesting else { return }
            defer {
                if generation == urlTestGeneration {
                    isURLTesting = false
                    urlTestTask = nil
                    urlTestBaselineHistory = nil
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
        defer { rebuildSortedNodes() }
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
            await refreshData()
            if let node = nodes.first(where: { $0.sourceIdentifier == identifier }) {
                if status.isRunning { try await reloadRunningEngine(selectedNode: node.runtimeTag) }
                await selectNode(node)
            }
            return true
        } catch {
            show(error)
            return false
        }
    }

    func refresh(_ subscription: NekoPilotCore.Subscription) async {
        guard subscription.sourceType == .subscription,
              refreshingSubscriptionIDs.insert(subscription.identifier).inserted else { return }
        defer { refreshingSubscriptionIDs.remove(subscription.identifier) }
        do {
            try await importer.refresh(identifier: subscription.identifier)
            subscriptionRefreshErrors.removeValue(forKey: subscription.identifier)
            await refreshData()
            if status.isRunning { try await reloadRunningEngine(selectedNode: selectedNode) }
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
            await refreshData()
            if replacement == .contentChanged, status.isRunning {
                try await reloadRunningEngine(selectedNode: selectedNode)
            }
            return true
        } catch {
            show(error)
            return false
        }
    }

    func delete(_ subscription: NekoPilotCore.Subscription) async {
        do {
            try await repository.delete(identifier: subscription.identifier)
            await refreshData()
            if status.isRunning { try await reloadRunningEngine(selectedNode: selectedNode) }
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
        let previous = autoSwitch
        autoSwitch = value
        // Disabling must cancel an in-flight cycle before the preference write
        // touches disk; otherwise a slow filesystem could still allow one last
        // unexpected automatic switch after the user turned the feature off.
        if !value { await automaticSwitching.setAutomaticSwitchingEnabled(false) }
        await selection.setAutomaticSwitchingEnabled(value)
        do {
            try await settings.set(.bool(value), for: SettingsStore.Key.autoSwitch)
            lastAutomaticSwitchUpdate = nil
            if value { await automaticSwitching.setAutomaticSwitchingEnabled(true) }
        } catch {
            autoSwitch = previous
            await selection.setAutomaticSwitchingEnabled(previous)
            await automaticSwitching.setAutomaticSwitchingEnabled(previous)
            show(error)
        }
    }

    func setShowProtocol(_ value: Bool) async {
        let previous = showProtocol
        showProtocol = value
        do {
            try await settings.set(.bool(value), for: SettingsStore.Key.showProtocol)
        } catch {
            showProtocol = previous
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
        Task { [weak self] in await self?.applyAllowLAN(true) }
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
        let previous = allowLAN
        let wasRunning = status.isRunning
        allowLAN = value
        do {
            try await settings.set(.bool(value), for: SettingsStore.Key.allowLAN)
            try await applyConnectionSettingChange()
        } catch {
            allowLAN = previous
            try? await settings.set(.bool(previous), for: SettingsStore.Key.allowLAN)
            await restoreConnectionIfNeeded(wasRunning)
            show(error)
        }
    }

    func setSkipSystemProxy(_ value: Bool) async {
        let previous = skipSystemProxy
        let wasRunning = status.isRunning
        skipSystemProxy = value
        do {
            try await settings.set(.bool(value), for: SettingsStore.Key.skipSystemProxy)
            try await applyConnectionSettingChange()
        } catch {
            skipSystemProxy = previous
            try? await settings.set(.bool(previous), for: SettingsStore.Key.skipSystemProxy)
            await restoreConnectionIfNeeded(wasRunning)
            show(error)
        }
    }

    func setProxyPort(_ value: Int) async -> Bool {
        guard (1 ... 65_535).contains(value) else {
            show(NekoPilotError.invalidSetting("proxy_port"))
            return false
        }
        let previous = proxyPort
        let wasRunning = status.isRunning
        proxyPort = value
        do {
            try await settings.set(.number(Double(value)), for: SettingsStore.Key.proxyPort)
            try await applyConnectionSettingChange()
            return true
        } catch {
            proxyPort = previous
            try? await settings.set(.number(Double(previous)), for: SettingsStore.Key.proxyPort)
            await restoreConnectionIfNeeded(wasRunning)
            show(error)
            return false
        }
    }

    func setDirectDNS(_ value: String) async -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = directDNS
        let wasRunning = status.isRunning
        directDNS = trimmed
        do {
            try await settings.set(.string(trimmed), for: SettingsStore.Key.directDNS)
            try await applyConnectionSettingChange()
            return true
        } catch {
            directDNS = previous
            try? await settings.set(.string(previous), for: SettingsStore.Key.directDNS)
            await restoreConnectionIfNeeded(wasRunning)
            show(error)
            return false
        }
    }

    func setUserAgent(_ value: String) async -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = userAgent
        userAgent = trimmed
        do {
            try await settings.set(.string(trimmed), for: SettingsStore.Key.userAgent)
            return true
        } catch {
            userAgent = previous
            show(error)
            return false
        }
    }

    func handleSleep() async {
        wakeTask?.cancel()
        wakeTask = nil
        sleepStartedAt = Date()
        wasRunningBeforeSleep = status.isRunning
        lifecycleGeneration += 1
        // Awaiting the actor call preserves event order: a subsequent wake can
        // enqueue only after this suspension request, so it always owns the
        // final lifecycle state instead of racing an untracked sleep Task.
        await automaticSwitching.setLifecycleSuspended(true)
    }

    func handleWake() async {
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
                AppLogger.shared.warning("wake restart deferred because network is not ready")
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
        Task { [weak self] in
            guard let self, await importNode(request.input, name: nil) else { return }
            if request.shouldConnect, !status.isRunning { await toggleConnection() }
        }
    }

    func cancelDeepLink() {
        pendingDeepLink = nil
    }

    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        lifecycleGeneration += 1
        wakeTask?.cancel()
        wakeTask = nil
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
        statusTask?.cancel()
        selectionTask?.cancel()
        automaticSwitchTask?.cancel()
        stopTrafficMonitoring()
        ruleUpdateTask?.cancel()
        ruleUpdateTask = nil
        releaseCheckTask?.cancel()
        releaseCheckTask = nil
        await automaticSwitching.stop()
        // Releasing the system proxy and the long-lived sing-box process is
        // the only shutdown work that must finish before the app may exit.
        // Network-backed maintenance tasks can take until their URLSession
        // timeout even after cancellation, so they must never stand in front
        // of engine cleanup.
        AppLogger.shared.info("shutdown: stopping proxy engine")
        await engine.shutdown()
        AppLogger.shared.info("shutdown: proxy engine stopped")
        await testing?.value
        // Rule-set refresh owns no child process or system state. URLSession
        // cancellation is enough here; waiting for a remote server timeout
        // would make the app appear stuck after all critical cleanup finished.
        AppLogger.shared.info("shutdown: critical cleanup complete")
    }

    private func rebuildSortedNodes() {
        nodeRows = NodeListPresentation.rows(nodes, using: delayHistory, pinning: selectedNode)
        sortedNodes = nodeRows.map(\.node)
    }

    private func rebuildNodeCounts() {
        nodeCountsBySource = NodeListPresentation.countsBySource(nodes)
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
                    AppLogger.shared.warning("traffic stream interrupted: \(error.localizedDescription)")
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

    private func displayName(forTag tag: String) -> String {
        nodes.first(where: { $0.runtimeTag == tag }).map(displayName(for:)) ?? tag
    }

    private func loadSettings() async {
        autoSwitch = await settings.bool(SettingsStore.Key.autoSwitch, default: true)
        await selection.setAutomaticSwitchingEnabled(autoSwitch)
        showProtocol = await settings.bool(SettingsStore.Key.showProtocol)
        allowLAN = await settings.bool(SettingsStore.Key.allowLAN)
        skipSystemProxy = await settings.bool(SettingsStore.Key.skipSystemProxy)
        proxyPort = await settings.proxyPort()
        let storedDNS = await settings.string(SettingsStore.Key.directDNS)
        if DNSResolverDetector.isUsableIPAddress(storedDNS) {
            directDNS = storedDNS
        } else {
            directDNS = await DNSResolverDetector.detectSystemResolver() ?? DNSResolverDetector.fallback
            try? await settings.set(.string(directDNS), for: SettingsStore.Key.directDNS)
        }
        userAgent = await settings.string(SettingsStore.Key.userAgent, default: "sing-box 1.14.0-alpha.48")
        selectedNode = (await settings.string(SettingsStore.Key.selectedNode)).nilIfEmpty
        let storedHistory = (try? await repository.delayHistory()) ?? [:]
        let legacyHistory = (try? await settings.takeLegacyDelayHistory()) ?? [:]
        if storedHistory.isEmpty, !legacyHistory.isEmpty {
            try? await repository.replaceDelayHistory(legacyHistory)
            delayHistory = legacyHistory
        } else {
            delayHistory = storedHistory
        }
        do {
            rules = try await settings.rulesInstallingDefaultsIfNeeded()
        } catch {
            rules = await settings.rules()
            show(error)
        }
        rebuildSortedNodes()
    }

    private func persistRules(previous: [RoutingRule]) async -> Bool {
        let wasRunning = status.isRunning
        do {
            try await settings.replaceRules(rules)
            _ = try await compiler.compile(selectedNode: selectedNode)
            if wasRunning { try await reloadRunningEngine(selectedNode: selectedNode) }
            return true
        } catch {
            rules = previous
            try? await settings.replaceRules(previous)
            _ = try? await compiler.compile(selectedNode: selectedNode)
            if wasRunning {
                do {
                    if status.isRunning {
                        try await reloadRunningEngine(selectedNode: selectedNode)
                    } else {
                        try await engine.start(selectedNode: selectedNode)
                    }
                } catch {
                    AppLogger.shared.error("failed to restore previous routing rules: \(error.localizedDescription)")
                }
            }
            show(error)
            return false
        }
    }

    private func applyConnectionSettingChange() async throws {
        if status.isRunning {
            await engine.stop()
            try await engine.start(selectedNode: selectedNode)
        } else {
            _ = try await compiler.compile(selectedNode: selectedNode)
        }
    }

    private func restoreConnectionIfNeeded(_ wasRunning: Bool) async {
        guard wasRunning, !status.isRunning, !status.isBusy else { return }
        do {
            try await engine.start(selectedNode: selectedNode)
        } catch {
            AppLogger.shared.error("failed to restore previous connection settings: \(error.localizedDescription)")
        }
    }

    private func reloadRunningEngine(selectedNode: String?) async throws {
        do {
            try await engine.reload(selectedNode: selectedNode)
        } catch {
            guard status.isRunning else { throw error }
            // A reload request can succeed in sing-box while the short status
            // confirmation is lost, leaving UI and runtime state ambiguous.
            // A bounded full restart gives every source/rule mutation one
            // deterministic final state instead of silently running an older
            // or only partially observed configuration.
            AppLogger.shared.warning("live reload failed; restarting sing-box: \(error.localizedDescription)")
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
                        AppLogger.shared.warning("updated rule sets require a later reload: \(error.localizedDescription)")
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

private struct AppStorageBootstrap {
    let paths: AppPaths
    let settings: SettingsStore
    let repository: SubscriptionRepository
    let isPersistent: Bool
    let recoveryMessage: String?

    static func resolve() throws -> AppStorageBootstrap {
        do {
            let paths = try AppPaths.live()
            do {
                return AppStorageBootstrap(
                    paths: paths,
                    settings: try SettingsStore(fileURL: paths.settings),
                    repository: try SubscriptionRepository(databaseURL: paths.database),
                    isPersistent: true,
                    recoveryMessage: nil
                )
            } catch {
                return try recovery(
                    message: L10n.text(
                        "本地数据无法读取，应用已进入安全恢复模式；原文件没有被覆盖。\n\(error.localizedDescription)",
                        "Local data could not be read. NekoPilot opened in safe recovery mode without overwriting the original files.\n\(error.localizedDescription)"
                    )
                )
            }
        } catch {
            return try recovery(
                message: L10n.text(
                    "无法访问应用数据目录，连接功能已停用。\n\(error.localizedDescription)",
                    "The application data directory is unavailable, so connection features are disabled.\n\(error.localizedDescription)"
                )
            )
        }
    }

    private static func recovery(message: String) throws -> AppStorageBootstrap {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Recovery-\(UUID().uuidString)", isDirectory: true)
        let paths = AppPaths(applicationSupport: root, logs: root.appendingPathComponent("logs", isDirectory: true))
        try FileManager.default.createDirectory(at: paths.applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        return AppStorageBootstrap(
            paths: paths,
            settings: try SettingsStore(fileURL: paths.settings),
            repository: try SubscriptionRepository(databaseURL: paths.database),
            isPersistent: false,
            recoveryMessage: message
        )
    }
}

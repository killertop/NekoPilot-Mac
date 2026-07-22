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
    @Published var isURLTesting = false
    @Published var selectedTab: MainTab = .home
    @Published var errorMessage: String?
    @Published var rules: [RoutingRule] = []
    @Published var autoSelect = true
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
    @Published private(set) var lastAutomaticSelectionUpdate: AutoNodeSelectionUpdate?
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
    let automaticSelection: AutoNodeSelectionService
    let ruleSetUpdater: RuleSetUpdater
    let releaseChecker: GitHubReleaseChecker
    let networkReadiness = NetworkReadiness()
    private var statusTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var automaticDelayTask: Task<Void, Never>?
    private var urlTestTask: Task<Void, Never>?
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
        tester = URLTester(compiler: compiler, nativeAPI: nativeAPI)
        selection = NodeSelectionCoordinator(engine: engine, settings: settings)
        automaticSelection = AutoNodeSelectionService(
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
        automaticDelayTask?.cancel()
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
                await automaticSelection.updateConnectionState(isRunning: next.isRunning)
                if next.isRunning {
                    scheduleRuleSetRefresh()
                } else {
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
                selectedNode = node
            }
        }
        automaticDelayTask = Task { [weak self] in
            guard let self else { return }
            let stream = await automaticSelection.updates()
            for await update in stream {
                guard !Task.isCancelled else { return }
                let availableTags = Set(nodes.map(\.runtimeTag))
                var mergedHistory = delayHistory.filter { availableTags.contains($0.key) }
                for (tag, record) in update.delays where availableTags.contains(tag) {
                    if let current = mergedHistory[tag], current.measuredAt > record.measuredAt { continue }
                    mergedHistory[tag] = record
                }
                delayHistory = mergedHistory
                lastAutomaticSelectionUpdate = update
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
            await automaticSelection.start(enabled: autoSelect, engineRunning: status.isRunning)
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
            if previousTags != availableTags { lastAutomaticSelectionUpdate = nil }
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
            await automaticSelection.nodesDidChange()
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
            let target = preferredNodeForConnection()
            if selectedNode != target {
                selectedNode = target
                try await settings.set(target.map(JSONValue.string), for: SettingsStore.Key.selectedNode)
            }
            try await engine.start(selectedNode: target)
        } catch is CancellationError {
            return
        } catch {
            show(error)
        }
    }

    func selectNode(_ node: ProxyNode) async {
        guard storageAvailable, !isShuttingDown else { return }
        let previous = selectedNode
        selectionGeneration += 1
        let generation = selectionGeneration
        selectedNode = node.runtimeTag
        do {
            let applied = try await selection.submit(node: node.runtimeTag)
            if !applied {
                // An authoritative automatic request may reject this optimistic
                // manual selection. Restore the last committed value now; a
                // successful automatic request will publish its winner through
                // the selection stream when it finishes.
                let committed = (await settings.string(SettingsStore.Key.selectedNode)).nilIfEmpty
                if selectionGeneration == generation {
                    selectedNode = committed ?? previous
                }
            } else if autoSelect {
                lastAutomaticSelectionUpdate = nil
                await automaticSelection.manualSelectionDidApply()
            }
        } catch {
            if selectionGeneration == generation { selectedNode = previous }
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
        let running = status.isRunning
        urlTestProgressFlushTask?.cancel()
        urlTestProgressFlushTask = nil
        pendingURLTestProgress.removeAll(keepingCapacity: true)
        urlTestTask = Task { [weak self] in
            guard let self else { return }
            guard generation == urlTestGeneration, isURLTesting else { return }
            await automaticSelection.setExplicitTestActive(true)
            guard generation == urlTestGeneration, isURLTesting else { return }
            defer {
                if generation == urlTestGeneration {
                    isURLTesting = false
                    urlTestTask = nil
                    urlTestBaselineHistory = nil
                }
            }
            let results = await tester.test(
                nodes: snapshot,
                engineRunning: running,
                execution: .isolatedWorkers
            ) { [weak self] tag, record in
                await self?.enqueueURLTestProgress(tag: tag, record: record, generation: generation)
            }
            // An older cancelled task may finish after a new user test starts.
            // Only the current generation may release the automatic-test lock.
            if generation == urlTestGeneration {
                await automaticSelection.setExplicitTestActive(false)
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
        await automaticSelection.setExplicitTestActive(false)
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

    func setAutoSelect(_ value: Bool) async {
        let previous = autoSelect
        autoSelect = value
        // Disabling must cancel an in-flight cycle before the preference write
        // touches disk; otherwise a slow filesystem could still allow one last
        // unexpected automatic switch after the user turned the feature off.
        if !value { await automaticSelection.setEnabled(false) }
        await selection.setAutomaticSelectionEnabled(value)
        do {
            try await settings.set(.bool(value), for: SettingsStore.Key.autoSelect)
            lastAutomaticSelectionUpdate = nil
            if value { await automaticSelection.setEnabled(true) }
        } catch {
            autoSelect = previous
            await selection.setAutomaticSelectionEnabled(previous)
            await automaticSelection.setEnabled(previous)
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
        await automaticSelection.setLifecycleSuspended(true)
    }

    func handleWake() async {
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        guard wasRunningBeforeSleep,
              let sleepStartedAt,
              Date().timeIntervalSince(sleepStartedAt) >= 30 else {
            await automaticSelection.setLifecycleSuspended(false)
            return
        }
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard generation == lifecycleGeneration else { return }
            guard await networkReadiness.waitUntilReady() else {
                AppLogger.shared.warning("wake restart deferred because network is not ready")
                await automaticSelection.setLifecycleSuspended(false)
                return
            }
            guard generation == lifecycleGeneration else { return }
            await engine.restartAfterLifecycleEvent(selectedNode: selectedNode)
            await automaticSelection.setLifecycleSuspended(false)
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
        automaticDelayTask?.cancel()
        ruleUpdateTask?.cancel()
        ruleUpdateTask = nil
        releaseCheckTask?.cancel()
        releaseCheckTask = nil
        await automaticSelection.stop()
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
        nodeRows = NodeListPresentation.rows(nodes, using: delayHistory)
        sortedNodes = nodeRows.map(\.node)
    }

    private func rebuildNodeCounts() {
        nodeCountsBySource = NodeListPresentation.countsBySource(nodes)
    }

    func displayName(for node: ProxyNode) -> String {
        NodeListPresentation.displayName(for: node)
    }

    func sourceName(for node: ProxyNode) -> String {
        subscriptions.first(where: { $0.identifier == node.sourceIdentifier })?.name ?? node.sourceIdentifier
    }

    var automaticSelectionSummary: String {
        if !autoSelect {
            return L10n.text("已关闭 · 使用手动选择的节点", "Off · using the manually selected node")
        }
        guard let update = lastAutomaticSelectionUpdate else {
            return L10n.text("每 10 分钟评估，仅在明显更快时切换", "Evaluate every 10 minutes and switch only when clearly faster")
        }
        switch update.outcome {
        case let .kept(node, delay):
            return L10n.text("已是最快：\(displayName(forTag: node)) · \(delay)ms", "Already fastest: \(displayName(forTag: node)) · \(delay)ms")
        case let .switched(node, delay):
            return L10n.text("已切换：\(displayName(forTag: node)) · \(delay)ms", "Switched: \(displayName(forTag: node)) · \(delay)ms")
        case let .considering(node, delay, confirmations):
            return L10n.text(
                "候选：\(displayName(forTag: node)) · \(delay)ms（\(confirmations)/2）",
                "Candidate: \(displayName(forTag: node)) · \(delay)ms (\(confirmations)/2)"
            )
        case .unavailable:
            return L10n.text("测速完成 · 暂无可用节点", "Tested · no reachable nodes")
        case .failed:
            return L10n.text("测速完成 · 自动切换失败", "Tested · automatic switch failed")
        }
    }

    private func displayName(forTag tag: String) -> String {
        nodes.first(where: { $0.runtimeTag == tag }).map(displayName(for:)) ?? tag
    }

    private func preferredNodeForConnection(now: Date = Date()) -> String? {
        guard autoSelect else {
            return selectedNode ?? nodes.first?.runtimeTag
        }
        return NodeListPresentation.preferredNode(nodes, using: delayHistory, now: now)?.runtimeTag
            ?? selectedNode
            ?? nodes.first?.runtimeTag
    }

    private func loadSettings() async {
        autoSelect = await settings.bool(SettingsStore.Key.autoSelect, default: true)
        await selection.setAutomaticSelectionEnabled(autoSelect)
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

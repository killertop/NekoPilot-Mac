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

@MainActor
final class TrafficState: ObservableObject {
    @Published var snapshot: TrafficSnapshot = .zero
}

@MainActor
final class AppModel: ObservableObject {
    @Published var status: EngineStatus = .stopped
    @Published var nodes: [ProxyNode] = []
    @Published private(set) var sortedNodes: [ProxyNode] = []
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
    @Published var userAgent = "sing-box 1.13.14"
    @Published var isInitialized = false
    @Published var pendingDeepLink: PendingDeepLink?
    @Published var pendingLANEnable = false
    @Published var availableUpdate: GitHubReleaseUpdate?
    @Published private(set) var lastAutomaticSelectionUpdate: AutoNodeSelectionUpdate?
    @Published private(set) var refreshingSubscriptionIDs: Set<String> = []
    @Published private(set) var isRefreshingAllSubscriptions = false

    let paths: AppPaths
    let settings: SettingsStore
    let repository: SubscriptionRepository
    let importer: SubscriptionImporter
    let compiler: ConfigurationCompiler
    let clashAPI: ClashAPIClient
    let systemProxy: SystemProxyManager
    let engine: EngineSupervisor
    let tester: URLTester
    let selection: NodeSelectionCoordinator
    let automaticSelection: AutoNodeSelectionService
    let ruleSetUpdater: RuleSetUpdater
    let releaseChecker: GitHubReleaseChecker
    let networkReadiness = NetworkReadiness()
    let trafficState = TrafficState()

    private var statusTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var automaticDelayTask: Task<Void, Never>?
    private var trafficTask: Task<Void, Never>?
    private var urlTestTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var ruleUpdateTask: Task<Void, Never>?
    private var releaseCheckTask: Task<Void, Never>?
    private var selectionGeneration = 0
    private var urlTestGeneration = 0
    private var trafficGeneration = 0
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
        clashAPI = ClashAPIClient(settings: settings)
        systemProxy = SystemProxyManager(markerURL: paths.proxyOwnership)
        engine = EngineSupervisor(
            settings: settings,
            compiler: compiler,
            systemProxy: systemProxy,
            clashAPI: clashAPI,
            ownershipURL: paths.engineOwnership
        )
        tester = URLTester(compiler: compiler, clashAPI: clashAPI)
        selection = NodeSelectionCoordinator(engine: engine, settings: settings)
        automaticSelection = AutoNodeSelectionService(
            engine: engine,
            repository: repository,
            settings: settings,
            tester: tester,
            clashAPI: clashAPI,
            selection: selection
        )
        ruleSetUpdater = RuleSetUpdater(paths: paths)
        releaseChecker = GitHubReleaseChecker(settings: settings)
        AppLogger.shared.configure(destination: paths.logFile)
    }

    deinit {
        statusTask?.cancel()
        selectionTask?.cancel()
        automaticDelayTask?.cancel()
        trafficTask?.cancel()
        urlTestTask?.cancel()
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
                if next.isRunning {
                    startTrafficStream()
                    scheduleRuleSetRefresh()
                } else {
                    stopTrafficStream()
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
                delayHistory = update.delays
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
            await automaticSelection.start()
            scheduleReleaseCheck()
        }
    }

    func refreshData() async {
        guard storageAvailable, !isShuttingDown else { return }
        do {
            async let loadedNodes = repository.nodes()
            async let loadedSources = repository.subscriptions()
            nodes = try await loadedNodes
            subscriptions = try await loadedSources
            rebuildNodeCounts()
            let availableTags = Set(nodes.map(\.runtimeTag))
            let currentHistory = delayHistory.filter { availableTags.contains($0.key) }
            if currentHistory.count != delayHistory.count {
                delayHistory = currentHistory
                try await repository.replaceDelayHistory(currentHistory)
            }
            if selectedNode == nil || !nodes.contains(where: { $0.runtimeTag == selectedNode }) {
                selectedNode = nodes.first?.runtimeTag
                if let selectedNode {
                    try await settings.set(.string(selectedNode), for: SettingsStore.Key.selectedNode)
                } else {
                    try await settings.set(nil, for: SettingsStore.Key.selectedNode)
                }
            }
            rebuildSortedNodes()
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
            try await engine.start(selectedNode: selectedNode ?? nodes.first?.runtimeTag)
        } catch is CancellationError {
            return
        } catch {
            show(error)
        }
    }

    func selectNode(_ node: ProxyNode, manual: Bool = true) async {
        guard storageAvailable, !isShuttingDown else { return }
        let previous = selectedNode
        selectionGeneration += 1
        let generation = selectionGeneration
        selectedNode = node.runtimeTag
        do {
            try await selection.submit(node: node.runtimeTag)
            if manual { await automaticSelection.deferAfterManualSelection() }
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
        let snapshot = nodes
        let running = status.isRunning
        urlTestTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == urlTestGeneration {
                    isURLTesting = false
                    urlTestTask = nil
                }
            }
            let results = await tester.test(nodes: snapshot, engineRunning: running)
            guard !Task.isCancelled else { return }
            delayHistory = results
            rebuildSortedNodes()
            do {
                try await repository.replaceDelayHistory(results)
            } catch {
                show(error)
            }
        }
    }

    func cancelURLTest() {
        urlTestGeneration += 1
        urlTestTask?.cancel()
        urlTestTask = nil
        isURLTesting = false
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
              !isRefreshingAllSubscriptions,
              refreshingSubscriptionIDs.insert(subscription.identifier).inserted else { return }
        defer { refreshingSubscriptionIDs.remove(subscription.identifier) }
        do {
            try await importer.refresh(identifier: subscription.identifier)
            await refreshData()
            if status.isRunning { try await reloadRunningEngine(selectedNode: selectedNode) }
        } catch {
            show(error)
        }
    }

    func refreshAllSubscriptions() async {
        guard !isRefreshingAllSubscriptions, refreshingSubscriptionIDs.isEmpty else { return }
        let candidates = subscriptions.filter { $0.sourceType == .subscription }
        guard !candidates.isEmpty else { return }
        isRefreshingAllSubscriptions = true
        refreshingSubscriptionIDs = Set(candidates.map(\.identifier))
        defer {
            refreshingSubscriptionIDs.removeAll()
            isRefreshingAllSubscriptions = false
        }
        await withTaskGroup(of: (String, String?).self) { group in
            var nextIndex = 0
            let limit = min(3, candidates.count)
            for _ in 0 ..< limit {
                let subscription = candidates[nextIndex]
                nextIndex += 1
                group.addTask { [importer] in
                    do {
                        try await importer.refresh(identifier: subscription.identifier)
                        return (subscription.identifier, nil)
                    } catch {
                        return (subscription.identifier, error.localizedDescription)
                    }
                }
            }
            while let (identifier, errorMessage) = await group.next() {
                if let errorMessage {
                    AppLogger.shared.warning("refresh failed for \(identifier): \(errorMessage)")
                }
                if nextIndex < candidates.count {
                    let subscription = candidates[nextIndex]
                    nextIndex += 1
                    group.addTask { [importer] in
                        do {
                            try await importer.refresh(identifier: subscription.identifier)
                            return (subscription.identifier, nil)
                        } catch {
                            return (subscription.identifier, error.localizedDescription)
                        }
                    }
                }
            }
        }
        await refreshData()
        if status.isRunning {
            do { try await reloadRunningEngine(selectedNode: selectedNode) } catch { show(error) }
        }
    }

    func edit(_ subscription: NekoPilotCore.Subscription, name: String, input: String) async -> Bool {
        guard storageAvailable, !isShuttingDown else { return false }
        do {
            try await importer.replace(identifier: subscription.identifier, rawInput: input, name: name)
            await refreshData()
            if status.isRunning { try await reloadRunningEngine(selectedNode: selectedNode) }
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

    func deleteRule(_ rule: RoutingRule) async {
        let previous = rules
        rules.removeAll { $0.id == rule.id }
        _ = await persistRules(previous: previous)
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
        do {
            try await settings.set(.bool(value), for: SettingsStore.Key.autoSelect)
        } catch {
            autoSelect = previous
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

    func handleSleep() {
        wakeTask?.cancel()
        wakeTask = nil
        sleepStartedAt = Date()
        wasRunningBeforeSleep = status.isRunning
        lifecycleGeneration += 1
    }

    func handleWake() {
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        guard wasRunningBeforeSleep,
              let sleepStartedAt,
              Date().timeIntervalSince(sleepStartedAt) >= 30 else { return }
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard generation == lifecycleGeneration else { return }
            guard await networkReadiness.waitUntilReady() else {
                AppLogger.shared.warning("wake restart deferred because network is not ready")
                return
            }
            guard generation == lifecycleGeneration else { return }
            await engine.restartAfterLifecycleEvent(selectedNode: selectedNode)
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
        testing?.cancel()
        urlTestTask = nil
        isURLTesting = false
        statusTask?.cancel()
        selectionTask?.cancel()
        automaticDelayTask?.cancel()
        trafficTask?.cancel()
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
        sortedNodes = NodeListPresentation.sorted(nodes, using: delayHistory)
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
        guard let update = lastAutomaticSelectionUpdate else {
            return L10n.text("每 10 分钟测速并自动切换", "Test every 10 minutes and switch automatically")
        }
        switch update.outcome {
        case let .kept(node, delay):
            return L10n.text("已是最快：\(displayName(forTag: node)) · \(delay)ms", "Already fastest: \(displayName(forTag: node)) · \(delay)ms")
        case let .switched(node, delay):
            return L10n.text("已切换：\(displayName(forTag: node)) · \(delay)ms", "Switched: \(displayName(forTag: node)) · \(delay)ms")
        case .deferredBusy:
            return L10n.text("测速完成 · 活跃连接中暂缓切换", "Tested · switch deferred for active connection")
        case .unavailable:
            return L10n.text("测速完成 · 暂无可用节点", "Tested · no reachable nodes")
        case .failed:
            return L10n.text("测速完成 · 自动切换失败", "Tested · automatic switch failed")
        }
    }

    private func displayName(forTag tag: String) -> String {
        nodes.first(where: { $0.runtimeTag == tag }).map(displayName(for:)) ?? tag
    }

    private func loadSettings() async {
        autoSelect = await settings.bool(SettingsStore.Key.autoSelect, default: true)
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
        userAgent = await settings.string(SettingsStore.Key.userAgent, default: "sing-box 1.13.14")
        selectedNode = (await settings.string(SettingsStore.Key.selectedNode)).nilIfEmpty
        let storedHistory = (try? await repository.delayHistory()) ?? [:]
        let legacyHistory = (try? await settings.takeLegacyDelayHistory()) ?? [:]
        if storedHistory.isEmpty, !legacyHistory.isEmpty {
            try? await repository.replaceDelayHistory(legacyHistory)
            delayHistory = legacyHistory
        } else {
            delayHistory = storedHistory
        }
        rules = await settings.rules()
        rebuildSortedNodes()
    }

    private func persistRules(previous: [RoutingRule]) async -> Bool {
        do {
            try await settings.replaceRules(rules)
            _ = try await compiler.compile(selectedNode: selectedNode)
            if status.isRunning { try await reloadRunningEngine(selectedNode: selectedNode) }
            return true
        } catch {
            rules = previous
            try? await settings.replaceRules(previous)
            _ = try? await compiler.compile(selectedNode: selectedNode)
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
        stopTrafficStream()
        defer {
            if status.isRunning { startTrafficStream() }
        }
        try await engine.reload(selectedNode: selectedNode)
    }

    private func startTrafficStream() {
        guard trafficTask == nil else { return }
        trafficGeneration += 1
        let generation = trafficGeneration
        trafficTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = await clashAPI.trafficStream()
                for try await sample in stream {
                    guard !Task.isCancelled else { return }
                    trafficState.snapshot = sample
                }
            } catch {
                if !Task.isCancelled { AppLogger.shared.warning("traffic stream ended: \(error.localizedDescription)") }
            }
            if generation == trafficGeneration { trafficTask = nil }
        }
    }

    private func stopTrafficStream() {
        trafficGeneration += 1
        trafficTask?.cancel()
        trafficTask = nil
        trafficState.snapshot = .zero
    }

    private func scheduleRuleSetRefresh() {
        guard ruleUpdateTask == nil else { return }
        ruleUpdateGeneration += 1
        let generation = ruleUpdateGeneration
        ruleUpdateTask = Task { [weak self] in
            guard let self else { return }
            let changed = await ruleSetUpdater.refreshIfDue()
            guard !Task.isCancelled else { return }
            if changed, status.isRunning {
                do {
                    try await reloadRunningEngine(selectedNode: selectedNode)
                } catch {
                    AppLogger.shared.warning("updated rule sets require a later reload: \(error.localizedDescription)")
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

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
final class AppModel: ObservableObject {
    @Published var status: EngineStatus = .stopped
    @Published var nodes: [ProxyNode] = []
    @Published private(set) var sortedNodes: [ProxyNode] = []
    @Published var subscriptions: [NekoPilotCore.Subscription] = []
    @Published var selectedNode: String?
    @Published var delayHistory: [String: DelayRecord] = [:]
    @Published var traffic: TrafficSnapshot = .zero
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

    private var statusTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var automaticDelayTask: Task<Void, Never>?
    private var trafficTask: Task<Void, Never>?
    private var urlTestTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var ruleUpdateTask: Task<Void, Never>?
    private var releaseCheckTask: Task<Void, Never>?
    private var selectionGeneration = 0
    private var sleepStartedAt: Date?
    private var wasRunningBeforeSleep = false
    private var lifecycleGeneration = 0
    private var isShuttingDown = false
    private let storageAvailable: Bool
    private let bootstrapError: String?

    init() {
        var candidatePaths: AppPaths?
        var candidateSettings: SettingsStore?
        var candidateRepository: SubscriptionRepository?
        var storageAvailable = false
        var bootstrapError: String?
        do {
            let livePaths = try AppPaths.live()
            candidatePaths = livePaths
            do {
                candidateSettings = try SettingsStore(fileURL: livePaths.settings)
                candidateRepository = try SubscriptionRepository(databaseURL: livePaths.database)
                storageAvailable = true
                bootstrapError = nil
            } catch {
                let recovery = FileManager.default.temporaryDirectory
                    .appendingPathComponent("NekoPilot-Recovery-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
                let recoveryPaths = AppPaths(applicationSupport: recovery, logs: recovery.appendingPathComponent("logs"))
                candidateSettings = try SettingsStore(fileURL: recoveryPaths.settings)
                candidateRepository = try SubscriptionRepository(databaseURL: recoveryPaths.database)
                storageAvailable = false
                bootstrapError = L10n.text(
                    "本地数据无法读取，应用已进入安全恢复模式；原文件没有被覆盖。\n\(error.localizedDescription)",
                    "Local data could not be read. NekoPilot opened in safe recovery mode without overwriting the original files.\n\(error.localizedDescription)"
                )
            }
        } catch {
            let recovery = FileManager.default.temporaryDirectory
                .appendingPathComponent("NekoPilot-Emergency-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
            let emergencyPaths = AppPaths(applicationSupport: recovery, logs: recovery.appendingPathComponent("logs"))
            candidatePaths = emergencyPaths
            try? FileManager.default.createDirectory(at: emergencyPaths.logs, withIntermediateDirectories: true)
            // If even the process temporary directory is unavailable, the OS
            // cannot provide a usable application environment.
            candidateSettings = try! SettingsStore(fileURL: emergencyPaths.settings)
            candidateRepository = try! SubscriptionRepository(databaseURL: emergencyPaths.database)
            storageAvailable = false
            bootstrapError = L10n.text(
                "无法访问应用数据目录，连接功能已停用。\n\(error.localizedDescription)",
                "The application data directory is unavailable, so connection features are disabled.\n\(error.localizedDescription)"
            )
        }
        guard let resolvedPaths = candidatePaths,
              let resolvedSettings = candidateSettings,
              let resolvedRepository = candidateRepository else {
            fatalError("NekoPilot cannot initialize even temporary storage")
        }
        paths = resolvedPaths
        settings = resolvedSettings
        repository = resolvedRepository
        self.storageAvailable = storageAvailable
        self.bootstrapError = bootstrapError
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
            for await delays in stream {
                guard !Task.isCancelled else { return }
                delayHistory = delays
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
            let availableTags = Set(nodes.map(\.runtimeTag))
            let currentHistory = delayHistory.filter { availableTags.contains($0.key) }
            if currentHistory.count != delayHistory.count {
                delayHistory = currentHistory
                try await settings.replaceDelayHistory(currentHistory)
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
        isURLTesting = true
        let snapshot = nodes
        let running = status.isRunning
        urlTestTask = Task { [weak self] in
            guard let self else { return }
            let results = await tester.test(nodes: snapshot, engineRunning: running)
            guard !Task.isCancelled else { return }
            delayHistory = results
            rebuildSortedNodes()
            do {
                try await settings.replaceDelayHistory(results)
            } catch {
                show(error)
            }
            isURLTesting = false
        }
    }

    func cancelURLTest() {
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
        guard subscription.sourceType == .subscription else { return }
        do {
            try await importer.refresh(identifier: subscription.identifier)
            await refreshData()
            if status.isRunning { try await reloadRunningEngine(selectedNode: selectedNode) }
        } catch {
            show(error)
        }
    }

    func refreshAllSubscriptions() async {
        for subscription in subscriptions where subscription.sourceType == .subscription {
            do {
                try await importer.refresh(identifier: subscription.identifier)
            } catch {
                AppLogger.shared.warning("refresh failed for \(subscription.identifier): \(error.localizedDescription)")
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

    func addRule(action: RuleAction, kind: RuleKind, value: String) async -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validateRule(trimmed, kind: kind) else {
            show(NekoPilotError.invalidSetting("rule"))
            return false
        }
        let previous = rules
        rules.append(RoutingRule(action: action, kind: kind, value: trimmed))
        return await persistRules(previous: previous)
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
    ) async -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validateRule(trimmed, kind: kind),
              !rules.contains(where: {
                  $0.id != rule.id && $0.action == action && $0.kind == kind && $0.value == trimmed
              }),
              let index = rules.firstIndex(where: { $0.id == rule.id }) else {
            show(NekoPilotError.invalidSetting("rule"))
            return false
        }
        let previous = rules
        rules[index].action = action
        rules[index].kind = kind
        rules[index].value = trimmed
        return await persistRules(previous: previous)
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
        allowLAN = value
        do {
            try await settings.set(.bool(value), for: SettingsStore.Key.allowLAN)
            try await applyConnectionSettingChange()
        } catch {
            allowLAN = previous
            try? await settings.set(.bool(previous), for: SettingsStore.Key.allowLAN)
            show(error)
        }
    }

    func setSkipSystemProxy(_ value: Bool) async {
        let previous = skipSystemProxy
        skipSystemProxy = value
        do {
            try await settings.set(.bool(value), for: SettingsStore.Key.skipSystemProxy)
            try await applyConnectionSettingChange()
        } catch {
            skipSystemProxy = previous
            try? await settings.set(.bool(previous), for: SettingsStore.Key.skipSystemProxy)
            show(error)
        }
    }

    func setProxyPort(_ value: Int) async -> Bool {
        guard (1 ... 65_535).contains(value) else {
            show(NekoPilotError.invalidSetting("proxy_port"))
            return false
        }
        proxyPort = value
        do {
            try await settings.set(.number(Double(value)), for: SettingsStore.Key.proxyPort)
            try await applyConnectionSettingChange()
            return true
        } catch {
            show(error)
            return false
        }
    }

    func setDirectDNS(_ value: String) async -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = directDNS
        directDNS = trimmed
        do {
            try await settings.set(.string(trimmed), for: SettingsStore.Key.directDNS)
            try await applyConnectionSettingChange()
            return true
        } catch {
            directDNS = previous
            try? await settings.set(.string(previous), for: SettingsStore.Key.directDNS)
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
        let updatingRules = ruleUpdateTask
        updatingRules?.cancel()
        ruleUpdateTask = nil
        releaseCheckTask?.cancel()
        releaseCheckTask = nil
        await automaticSelection.stop()
        await testing?.value
        await updatingRules?.value
        await engine.shutdown()
    }

    private func rebuildSortedNodes() {
        sortedNodes = NodeListPresentation.sorted(nodes, using: delayHistory)
    }

    func displayName(for node: ProxyNode) -> String {
        NodeListPresentation.displayName(for: node)
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
        delayHistory = await settings.delayHistory()
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

    private func reloadRunningEngine(selectedNode: String?) async throws {
        stopTrafficStream()
        defer {
            if status.isRunning { startTrafficStream() }
        }
        try await engine.reload(selectedNode: selectedNode)
    }

    private func startTrafficStream() {
        guard trafficTask == nil else { return }
        trafficTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = await clashAPI.trafficStream()
                for try await sample in stream {
                    guard !Task.isCancelled else { return }
                    traffic = sample
                }
            } catch {
                if !Task.isCancelled { AppLogger.shared.warning("traffic stream ended: \(error.localizedDescription)") }
            }
            trafficTask = nil
        }
    }

    private func stopTrafficStream() {
        trafficTask?.cancel()
        trafficTask = nil
        traffic = .zero
    }

    private func scheduleRuleSetRefresh() {
        guard ruleUpdateTask == nil else { return }
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
            ruleUpdateTask = nil
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

    private static func validateRule(_ value: String, kind: RuleKind) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512, !value.contains(where: \.isWhitespace) else { return false }
        if kind == .ipCIDR {
            guard let slash = value.lastIndex(of: "/"),
                  let prefix = Int(value[value.index(after: slash)...]) else { return false }
            let address = String(value[..<slash])
            var ipv4 = in_addr(), ipv6 = in6_addr()
            let isV4 = address.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 }
            let isV6 = address.withCString { inet_pton(AF_INET6, $0, &ipv6) == 1 }
            return (isV4 && (0 ... 32).contains(prefix)) || (isV6 && (0 ... 128).contains(prefix))
        }
        return !value.contains("://")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

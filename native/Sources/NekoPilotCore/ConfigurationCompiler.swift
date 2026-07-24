import Foundation
import Darwin

/// A uniquely named runtime configuration that has not yet been promoted to
/// the live `runtime.json`.  Keeping compilation separate from promotion lets
/// the engine validate the exact bytes it will run before replacing the live
/// file.
struct RuntimeConfigurationCandidate: Sendable {
    let configurationURL: URL
    private let liveConfigurationURL: URL
    private let cleanupURLs: [URL]

    init(
        configurationURL: URL,
        liveConfigurationURL: URL,
        cleanupURLs: [URL] = []
    ) {
        self.configurationURL = configurationURL
        self.liveConfigurationURL = liveConfigurationURL
        self.cleanupURLs = cleanupURLs
    }

    @discardableResult
    func promote() throws -> URL {
        let data = try Data(contentsOf: configurationURL)
        try AtomicFile.write(data, to: liveConfigurationURL)
        return liveConfigurationURL
    }

    @discardableResult
    func commit() throws -> URL {
        let liveURL = try promote()
        discard()
        return liveURL
    }

    func discard() {
        try? FileManager.default.removeItem(at: configurationURL)
        for url in cleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

private enum RuntimeCandidateOwnership {
    /// Shared by every compiler created in this process. A random token,
    /// instead of the PID alone, also distinguishes a relaunched process when
    /// macOS happens to reuse the same PID.
    static let currentProcessToken = UUID().uuidString.lowercased()
}

public actor ConfigurationCompiler {
    private let paths: AppPaths
    private let settings: SettingsStore
    private let repository: SubscriptionRepository

    public init(paths: AppPaths, settings: SettingsStore, repository: SubscriptionRepository) {
        self.paths = paths
        self.settings = settings
        self.repository = repository
    }

    /// Removes candidates left by a previous abnormal process exit while
    /// preserving every candidate owned by this process. Recovery can suspend
    /// while terminating an orphan, so a current start/reload may legitimately
    /// create a candidate before cleanup resumes.
    func removeAbandonedRuntimeCandidates() {
        let directory = paths.runtimeConfig.deletingLastPathComponent()
        let currentProcessPrefix = ".runtime.json.\(RuntimeCandidateOwnership.currentProcessToken)."
        let currentPreflightPrefix = ".reload-preflight-\(RuntimeCandidateOwnership.currentProcessToken)."
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in contents {
            let name = url.lastPathComponent
            let isAbandonedCandidate = name.hasPrefix(".runtime.json.")
                && name.hasSuffix(".candidate")
                && !name.hasPrefix(currentProcessPrefix)
            let isPreflightCache = name.hasPrefix(".reload-preflight-")
                && (name.hasSuffix(".db")
                    || name.hasSuffix(".db-shm")
                    || name.hasSuffix(".db-wal"))
            let isAbandonedPreflightCache = isPreflightCache
                && !name.hasPrefix(currentPreflightPrefix)
            if isAbandonedCandidate || isAbandonedPreflightCache {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    @discardableResult
    public func compile(
        selectedNode: String?,
        apiEndpoint: LocalAPIEndpoint? = nil,
        healthProbePort: Int? = nil
    ) async throws -> URL {
        let runtimeSettings = await settings.runtimeConfiguration()
        return try await compile(
            selectedNode: selectedNode,
            apiEndpoint: apiEndpoint,
            healthProbePort: healthProbePort,
            runtimeSettings: runtimeSettings
        )
    }

    @discardableResult
    func compile(
        selectedNode: String?,
        apiEndpoint: LocalAPIEndpoint? = nil,
        healthProbePort: Int? = nil,
        runtimeSettings: RuntimeConfigurationSettings
    ) async throws -> URL {
        let candidate = try await makeRuntimeConfigurationCandidate(
            selectedNode: selectedNode,
            apiEndpoint: apiEndpoint,
            healthProbePort: healthProbePort,
            runtimeSettings: runtimeSettings
        )
        defer { candidate.discard() }
        return try candidate.commit()
    }

    func makeRuntimeConfigurationCandidate(
        selectedNode: String?,
        apiEndpoint: LocalAPIEndpoint? = nil,
        healthProbePort: Int? = nil
    ) async throws -> RuntimeConfigurationCandidate {
        try await makeRuntimeConfigurationCandidate(
            selectedNode: selectedNode,
            apiEndpoint: apiEndpoint,
            healthProbePort: healthProbePort,
            runtimeSettings: await settings.runtimeConfiguration()
        )
    }

    func makeRuntimeConfigurationCandidate(
        selectedNode: String?,
        apiEndpoint: LocalAPIEndpoint? = nil,
        healthProbePort: Int? = nil,
        runtimeSettings: RuntimeConfigurationSettings
    ) async throws -> RuntimeConfigurationCandidate {
        let config = try await makeConfiguration(
            selectedNode: selectedNode,
            apiEndpoint: apiEndpoint,
            healthProbePort: healthProbePort,
            runtimeSettings: runtimeSettings
        )
        let candidateURL = paths.runtimeConfig
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".runtime.json.\(RuntimeCandidateOwnership.currentProcessToken).\(UUID().uuidString).candidate"
            )
        try AtomicFile.write(try JSONValue.encodeObject(config, pretty: true), to: candidateURL)
        return RuntimeConfigurationCandidate(
            configurationURL: candidateURL,
            liveConfigurationURL: paths.runtimeConfig
        )
    }

    /// Builds an isolated configuration that can be started alongside the
    /// active core. Its listeners and cache never overlap the live runtime, so
    /// a reload can prove that the exact candidate starts and reaches its
    /// selected gateway before asking the live core to adopt it.
    func makeReloadPreflightCandidate(
        from sourceConfigurationURL: URL,
        apiEndpoint: LocalAPIEndpoint,
        healthProbePort: Int,
        proxyPort: Int
    ) throws -> RuntimeConfigurationCandidate {
        var config = try JSONValue.decodeObject(
            from: Data(contentsOf: sourceConfigurationURL)
        )
        guard var services = config["services"]?.arrayValue,
              let apiIndex = services.firstIndex(where: {
                  $0.objectValue?["type"]?.stringValue == "api"
                      && $0.objectValue?["tag"]?.stringValue == "nekopilot-local-api"
              }),
              var api = services[apiIndex].objectValue else {
            throw NekoPilotError.processFailed(CoreL10n.text(
                "候选配置缺少本地控制服务",
                "The candidate configuration has no local control service"
            ))
        }
        api["listen"] = .string(apiEndpoint.host)
        api["listen_port"] = .number(Double(apiEndpoint.port))
        api["secret"] = .string(apiEndpoint.secret)
        services[apiIndex] = .object(api)
        config["services"] = .array(services)

        guard var inbounds = config["inbounds"]?.arrayValue,
              let mixedIndex = inbounds.firstIndex(where: {
                  $0.objectValue?["type"]?.stringValue == "mixed"
                      && $0.objectValue?["tag"]?.stringValue == "mixed"
              }),
              var mixed = inbounds[mixedIndex].objectValue,
              let healthIndex = inbounds.firstIndex(where: {
                  $0.objectValue?["type"]?.stringValue == "mixed"
                      && $0.objectValue?["tag"]?.stringValue == ProxyHealthEndpoint.inboundTag
              }),
              var health = inbounds[healthIndex].objectValue else {
            throw NekoPilotError.processFailed(CoreL10n.text(
                "候选配置缺少隔离预检监听器",
                "The candidate configuration is missing a reload-preflight listener"
            ))
        }
        mixed["listen"] = .string("127.0.0.1")
        mixed["listen_port"] = .number(Double(proxyPort))
        inbounds[mixedIndex] = .object(mixed)
        health["listen"] = .string("127.0.0.1")
        health["listen_port"] = .number(Double(healthProbePort))
        inbounds[healthIndex] = .object(health)
        config["inbounds"] = .array(inbounds)

        let runtimeDirectory = paths.runtimeConfig.deletingLastPathComponent()
        let token = UUID().uuidString.lowercased()
        let cacheURL = runtimeDirectory.appendingPathComponent(
            ".reload-preflight-\(RuntimeCandidateOwnership.currentProcessToken).\(token).db"
        )
        guard var experimental = config["experimental"]?.objectValue,
              var cache = experimental["cache_file"]?.objectValue else {
            throw NekoPilotError.processFailed(CoreL10n.text(
                "候选配置缺少缓存设置",
                "The candidate configuration has no cache settings"
            ))
        }
        cache["path"] = .string(cacheURL.path)
        experimental["cache_file"] = .object(cache)
        config["experimental"] = .object(experimental)
        let candidateURL = runtimeDirectory.appendingPathComponent(
            ".runtime.json.\(RuntimeCandidateOwnership.currentProcessToken).\(token).candidate"
        )
        try AtomicFile.write(try JSONValue.encodeObject(config, pretty: true), to: candidateURL)
        return RuntimeConfigurationCandidate(
            configurationURL: candidateURL,
            liveConfigurationURL: paths.runtimeConfig,
            cleanupURLs: [
                cacheURL,
                URL(fileURLWithPath: cacheURL.path + "-shm"),
                URL(fileURLWithPath: cacheURL.path + "-wal"),
            ]
        )
    }

    public func makeOfflineTestConfiguration(
        selectedNode: String?,
        apiEndpoint: LocalAPIEndpoint
    ) async throws -> URL {
        try await makeOfflineTestConfiguration(
            selectedNodes: selectedNode.map { [$0] } ?? [],
            apiEndpoint: apiEndpoint
        )
    }

    /// Creates an isolated, inbound-free configuration for one URL Test worker.
    /// The worker's selector is restricted to `selectedNodes`, so callers can
    /// run several bounded workers without sharing a cache or a test queue.
    public func makeOfflineTestConfiguration(
        selectedNodes: [String],
        apiEndpoint: LocalAPIEndpoint
    ) async throws -> URL {
        let configurations = try await makeOfflineTestConfigurations(
            selectedNodeGroups: [selectedNodes],
            apiEndpoints: [apiEndpoint]
        )
        guard let configuration = configurations.first else {
            throw NekoPilotError.processFailed(CoreL10n.text(
                "测速配置未生成",
                "The speed-test configuration was not generated"
            ))
        }
        return configuration
    }

    /// Builds all temporary worker configurations from one compiled base.  A
    /// multi-node test may need several workers, but repeatedly reading every
    /// subscription and validating the same binary rule sets used to put that
    /// setup work on the critical path once per worker.
    public func makeOfflineTestConfigurations(
        selectedNodeGroups: [[String]],
        apiEndpoints: [LocalAPIEndpoint]
    ) async throws -> [URL] {
        guard selectedNodeGroups.count == apiEndpoints.count,
              let selectedNode = selectedNodeGroups.first?.first else {
            throw NekoPilotError.processFailed(CoreL10n.text(
                "测速节点不能为空",
                "At least one speed-test node is required"
            ))
        }
        // Do not call compile here. An offline URL Test must not overwrite the
        // live runtime configuration with its short-lived API credentials or
        // race a subsequent Connect request.
        let baseConfig = try await makeConfiguration(
            selectedNode: selectedNode,
            apiEndpoint: apiEndpoints[0],
            healthProbePort: nil,
            runtimeSettings: await settings.runtimeConfiguration()
        )
        var configurations: [URL] = []
        do {
            for (selectedNodes, endpoint) in zip(selectedNodeGroups, apiEndpoints) {
                var config = baseConfig
                configureAPIService(config: &config, endpoint: endpoint)
                try restrictExitGateway(to: selectedNodes, in: &config)
                configurations.append(try makeIsolatedOfflineTestConfiguration(from: config))
            }
            return configurations
        } catch {
            for config in configurations {
                try? FileManager.default.removeItem(at: config.deletingLastPathComponent())
            }
            throw error
        }
    }

    /// Builds disposable workers that expose only a loopback proxy inbound.
    /// Each worker owns one selector subset and one private cache, so callers
    /// can inspect node egress without switching the live core or its users.
    public func makeLocationProbeConfigurations(
        selectedNodeGroups: [[String]],
        apiEndpoints: [LocalAPIEndpoint],
        proxyPorts: [Int]
    ) async throws -> [URL] {
        guard selectedNodeGroups.count == apiEndpoints.count,
              selectedNodeGroups.count == proxyPorts.count,
              !selectedNodeGroups.isEmpty,
              selectedNodeGroups.allSatisfy({ !$0.isEmpty }),
              proxyPorts.allSatisfy({ (1 ... 65_535).contains($0) }),
              Set(proxyPorts).count == proxyPorts.count,
              Set(apiEndpoints.map(\.port)).isDisjoint(with: proxyPorts),
              let selectedNode = selectedNodeGroups.first?.first else {
            throw NekoPilotError.processFailed(CoreL10n.text(
                "位置探测配置无效",
                "The location-probe configuration is invalid"
            ))
        }

        // Like URL Test, location discovery must never overwrite the live
        // runtime configuration with disposable ports or API credentials.
        let baseConfig = try await makeConfiguration(
            selectedNode: selectedNode,
            apiEndpoint: apiEndpoints[0],
            healthProbePort: nil,
            runtimeSettings: await settings.runtimeConfiguration()
        )
        var configurations: [URL] = []
        do {
            for index in selectedNodeGroups.indices {
                var config = baseConfig
                configureAPIService(config: &config, endpoint: apiEndpoints[index])
                try restrictExitGateway(to: selectedNodeGroups[index], in: &config)
                configurations.append(try makeIsolatedLocationProbeConfiguration(
                    from: config,
                    proxyPort: proxyPorts[index]
                ))
            }
            return configurations
        } catch {
            for config in configurations {
                try? FileManager.default.removeItem(at: config.deletingLastPathComponent())
            }
            throw error
        }
    }

    private func makeIsolatedOfflineTestConfiguration(
        from baseConfig: [String: JSONValue]
    ) throws -> URL {
        var config = baseConfig
        config.removeValue(forKey: "inbounds")
        return try writeIsolatedConfiguration(config, directoryPrefix: "NekoPilot-URLTest")
    }

    private func makeIsolatedLocationProbeConfiguration(
        from baseConfig: [String: JSONValue],
        proxyPort: Int
    ) throws -> URL {
        var config = baseConfig
        config["inbounds"] = .array([.object([
            "tag": .string(NodeLocationProbeEndpoint.inboundTag),
            "type": .string("mixed"),
            "listen": .string("127.0.0.1"),
            "listen_port": .number(Double(proxyPort)),
        ])])
        try forceLocationProbeThroughExitGateway(in: &config)
        return try writeIsolatedConfiguration(config, directoryPrefix: "NekoPilot-LocationProbe")
    }

    private func writeIsolatedConfiguration(
        _ baseConfig: [String: JSONValue],
        directoryPrefix: String
    ) throws -> URL {
        var config = baseConfig
        if var log = config["log"]?.objectValue {
            log["disabled"] = .bool(true)
            config["log"] = .object(log)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(directoryPrefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if var experimental = config["experimental"]?.objectValue,
           var cacheFile = experimental["cache_file"]?.objectValue {
            // Isolated workers may run while the primary core is connected.
            // Never let them contend for its SQLite cache file.
            cacheFile["path"] = .string(directory.appendingPathComponent("sing-box-cache.sqlite3").path)
            experimental["cache_file"] = .object(cacheFile)
            config["experimental"] = .object(experimental)
        }
        let file = directory.appendingPathComponent("config.json")
        try AtomicFile.write(try JSONValue.encodeObject(config), to: file)
        return file
    }

    private func forceLocationProbeThroughExitGateway(
        in config: inout [String: JSONValue]
    ) throws {
        guard var route = config["route"]?.objectValue,
              var routeRules = route["rules"]?.arrayValue,
              var dns = config["dns"]?.objectValue,
              var dnsRules = dns["rules"]?.arrayValue else {
            throw NekoPilotError.processFailed(CoreL10n.text(
                "位置探测配置缺少路由",
                "The location-probe configuration has no routing rules"
            ))
        }

        // This must precede custom direct rules, private-IP rules and the
        // China rule sets. A failed node therefore fails closed instead of
        // revealing the Mac's own egress location.
        routeRules.insert(.object([
            "inbound": .array([.string(NodeLocationProbeEndpoint.inboundTag)]),
            "outbound": .string("ExitGateway"),
        ]), at: 0)
        route["rules"] = .array(routeRules)
        config["route"] = .object(route)

        dnsRules.insert(.object([
            "inbound": .array([.string(NodeLocationProbeEndpoint.inboundTag)]),
            "action": .string("route"),
            "server": .string("dns_proxy"),
        ]), at: 0)
        dns["rules"] = .array(dnsRules)
        config["dns"] = .object(dns)
    }

    private func makeConfiguration(
        selectedNode: String?,
        apiEndpoint: LocalAPIEndpoint?,
        healthProbePort: Int?,
        runtimeSettings: RuntimeConfigurationSettings
    ) async throws -> [String: JSONValue] {
        var config = try Self.loadTemplate()
        try installRuleSetBaseline()
        configureRuntime(
            config: &config,
            proxyPort: runtimeSettings.proxyPort,
            allowLAN: runtimeSettings.allowLAN,
            directDNS: runtimeSettings.directDNS,
            apiEndpoint: apiEndpoint,
            healthProbePort: healthProbePort
        )
        injectRules(runtimeSettings.rules, healthProbeEnabled: healthProbePort != nil, into: &config)
        let sources = try await repository.configObjects()
        try merge(sources: sources, selectedNode: selectedNode, into: &config)
        return config
    }

    private func restrictExitGateway(
        to selectedNodes: [String],
        in config: inout [String: JSONValue]
    ) throws {
        let requested = Set(selectedNodes)
        guard var outbounds = config["outbounds"]?.arrayValue,
              let selectorIndex = outbounds.indices.first(where: {
                  $0 < outbounds.count
                      && outbounds[$0].objectValue?["tag"]?.stringValue == "ExitGateway"
                      && outbounds[$0].objectValue?["type"]?.stringValue == "selector"
              }),
              var selector = outbounds[selectorIndex].objectValue else {
            throw NekoPilotError.processFailed(CoreL10n.text(
                "测速配置缺少节点选择器",
                "The speed-test configuration has no node selector"
            ))
        }
        let existing = selector["outbounds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let included = existing.filter { requested.contains($0) }
        guard Set(included) == requested else {
            throw NekoPilotError.processFailed(CoreL10n.text(
                "测速节点未写入运行配置",
                "A speed-test node is missing from the runtime configuration"
            ))
        }
        selector["outbounds"] = .array(included.map(JSONValue.string))
        outbounds[selectorIndex] = .object(selector)

        // Disposable workers must not carry credentials for unrelated nodes.
        // Preserve each selected node's recursive detour chain plus the two
        // built-in outbounds needed by routing and DNS.
        let outboundByTag = Dictionary(
            uniqueKeysWithValues: outbounds.compactMap { value -> (String, [String: JSONValue])? in
                guard let outbound = value.objectValue,
                      let tag = outbound["tag"]?.stringValue else { return nil }
                return (tag, outbound)
            }
        )
        var requiredTags = Set(included)
        var pendingTags = included
        while let tag = pendingTags.popLast() {
            guard let detour = outboundByTag[tag]?["detour"]?.stringValue,
                  requiredTags.insert(detour).inserted else { continue }
            pendingTags.append(detour)
        }
        requiredTags.formUnion(["direct", "ExitGateway"])
        outbounds = outbounds.filter { value in
            guard let tag = value.objectValue?["tag"]?.stringValue else { return false }
            return requiredTags.contains(tag)
        }
        config["outbounds"] = .array(outbounds)
    }

    private static func loadTemplate() throws -> [String: JSONValue] {
        guard let url = resourceURL(name: "base-config", extension: "json") else {
            throw NekoPilotError.processFailed(CoreL10n.text(
                "缺少内置配置模板",
                "The bundled configuration template is missing"
            ))
        }
        return try JSONValue.decodeObject(from: Data(contentsOf: url))
    }

    private func configureRuntime(
        config: inout [String: JSONValue],
        proxyPort: Int,
        allowLAN: Bool,
        directDNS: String,
        apiEndpoint: LocalAPIEndpoint?,
        healthProbePort: Int?
    ) {
        config["log"] = .object([
            // Connection-level INFO output is extremely chatty and duplicates
            // the app's own lifecycle diagnostics. Keep production logs useful
            // without writing every proxied socket to disk.
            "disabled": .bool(false), "level": .string("warn"), "timestamp": .bool(true),
        ])
        var experimental = config["experimental"]?.objectValue ?? [:]
        experimental["cache_file"] = .object([
            "enabled": .bool(true),
            "store_fakeip": .bool(true),
            "store_dns": .bool(true),
            "path": .string(paths.cacheDatabase.path),
        ])
        config["experimental"] = .object(experimental)

        if let apiEndpoint {
            configureAPIService(config: &config, endpoint: apiEndpoint)
        } else {
            config.removeValue(forKey: "services")
        }

        if var inbounds = config["inbounds"]?.arrayValue {
            inbounds = inbounds.map { value in
                guard var inbound = value.objectValue,
                      inbound["type"]?.stringValue == "mixed",
                      inbound["tag"]?.stringValue == "mixed" else { return value }
                inbound["listen"] = .string(allowLAN ? "0.0.0.0" : "127.0.0.1")
                inbound["listen_port"] = .number(Double(proxyPort))
                return .object(inbound)
            }
            if let healthProbePort {
                inbounds.append(.object([
                    "tag": .string(ProxyHealthEndpoint.inboundTag),
                    "type": .string("mixed"),
                    "listen": .string("127.0.0.1"),
                    "listen_port": .number(Double(healthProbePort)),
                ]))
            }
            config["inbounds"] = .array(inbounds)
        }

        if var dns = config["dns"]?.objectValue,
           var servers = dns["servers"]?.arrayValue {
            servers = servers.map { value in
                guard var server = value.objectValue,
                      server["tag"]?.stringValue == "system" else { return value }
                server["type"] = .string("udp")
                server["server"] = .string(Self.validIPAddress(directDNS) ? directDNS : DNSResolverDetector.fallback)
                server["server_port"] = .number(53)
                return .object(server)
            }
            dns["servers"] = .array(servers)
            config["dns"] = .object(dns)
        }

        if var route = config["route"]?.objectValue,
           var ruleSets = route["rule_set"]?.arrayValue {
            ruleSets = ruleSets.map { value in
                guard var ruleSet = value.objectValue,
                      ruleSet["type"]?.stringValue == "local",
                      let tag = ruleSet["tag"]?.stringValue else { return value }
                let file: URL?
                switch tag {
                case "geoip-cn": file = RuleSetUpdater.activeRuleSetURL(in: paths.ruleSets, name: "geoip-cn")
                case "geosite-cn": file = RuleSetUpdater.activeRuleSetURL(in: paths.ruleSets, name: "geosite-cn")
                default: file = nil
                }
                guard let file else { return value }
                // The template already declares standard local binary rule
                // sets. Only the per-install absolute asset path is dynamic.
                ruleSet["path"] = .string(file.path)
                return .object(ruleSet)
            }
            route["rule_set"] = .array(ruleSets)
            config["route"] = .object(route)
        }
    }

    private func configureAPIService(
        config: inout [String: JSONValue],
        endpoint: LocalAPIEndpoint
    ) {
        // No dashboard, remote API, HTTP controller, or Clash service is
        // configured. Swift connects directly to the official sing-box gRPC
        // API over an ephemeral loopback endpoint for this process.
        config["services"] = .array([.object([
            "type": .string("api"),
            "tag": .string("nekopilot-local-api"),
            "listen": .string(endpoint.host),
            "listen_port": .number(Double(endpoint.port)),
            "secret": .string(endpoint.secret),
        ])])
    }

    private func injectRules(
        _ rules: [RoutingRule],
        healthProbeEnabled: Bool,
        into config: inout [String: JSONValue]
    ) {
        guard var route = config["route"]?.objectValue,
              var routeRules = route["rules"]?.arrayValue else { return }
        routeRules.removeAll { value in
            value.objectValue?["domain"]?.arrayValue?.contains(.string("reject-tag.nekopilot.invalid")) == true
        }
        for action in RuleAction.allCases {
            let anchor = action == .direct ? "direct-tag.nekopilot.invalid" : "proxy-tag.nekopilot.invalid"
            guard let index = routeRules.firstIndex(where: {
                $0.objectValue?["domain"]?.arrayValue?.contains(.string(anchor)) == true
            }), var target = routeRules[index].objectValue else { continue }
            for kind in RuleKind.allCases {
                let values = rules
                    .filter { $0.action == action && $0.kind == kind }
                    .map { $0.value }
                guard !values.isEmpty else { continue }
                var existing = target[kind.rawValue]?.arrayValue ?? []
                existing.append(contentsOf: values.map(JSONValue.string))
                let unique = Array(Set(existing.compactMap(\.stringValue))).sorted()
                target[kind.rawValue] = .array(unique.map(JSONValue.string))
            }
            routeRules[index] = .object(target)
        }
        // The failover probe enters through its own loopback-only inbound, so
        // this route exercises ExitGateway without changing how the same
        // destination behaves for normal user traffic.
        if healthProbeEnabled {
            let healthRouteRule: JSONValue = .object([
                "inbound": .array([.string(ProxyHealthEndpoint.inboundTag)]),
                "outbound": .string("ExitGateway"),
            ])
            let healthRouteIndex = routeRules.firstIndex {
                $0.objectValue?["outbound"]?.stringValue != nil
            } ?? routeRules.endIndex
            routeRules.insert(healthRouteRule, at: healthRouteIndex)
        }
        route["rules"] = .array(routeRules)
        config["route"] = .object(route)

        // A user-facing Direct/Proxy rule describes the complete path, not
        // only the post-resolution TCP/UDP route. Mirror domain rules into the
        // DNS router so a custom direct domain does not leak through the proxy
        // resolver, and a custom proxy domain still overrides the China direct
        // rule set. IP CIDR rules have no request-domain equivalent here.
        guard var dns = config["dns"]?.objectValue,
              let existingDNSRules = dns["rules"]?.arrayValue else { return }
        var customDNSRules: [JSONValue] = []
        for action in RuleAction.allCases {
            for kind in [RuleKind.domain, .domainSuffix] {
                let values = rules
                    .filter { $0.action == action && $0.kind == kind }
                    .map(\.value)
                guard !values.isEmpty else { continue }
                customDNSRules.append(.object([
                    kind.rawValue: .array(Array(Set(values)).sorted().map(JSONValue.string)),
                    "action": .string("route"),
                    "server": .string(action == .direct ? "system" : "dns_proxy"),
                ]))
            }
        }
        if healthProbeEnabled {
            let healthDNSRule: JSONValue = .object([
                "inbound": .array([.string(ProxyHealthEndpoint.inboundTag)]),
                "action": .string("route"),
                "server": .string("dns_proxy"),
            ])
            customDNSRules.insert(healthDNSRule, at: 0)
        }
        dns["rules"] = .array(customDNSRules + existingDNSRules)
        config["dns"] = .object(dns)
    }

    private func merge(
        sources: [(identifier: String, config: [String: JSONValue])],
        selectedNode: String?,
        into config: inout [String: JSONValue]
    ) throws {
        var nodes: [[String: JSONValue]] = []
        let ignored = Set(["selector", "urltest", "direct", "block", "dns"])
        for source in sources {
            let sourceOutbounds = source.config["outbounds"]?.arrayValue ?? []
            var tagMap: [String: String] = [:]
            for outbound in sourceOutbounds.compactMap(\.objectValue) {
                guard let type = outbound["type"]?.stringValue,
                      !ignored.contains(type),
                      let tag = outbound["tag"]?.stringValue,
                      !tag.isEmpty else { continue }
                tagMap[tag] = "@np:\(source.identifier):\(tag)"
            }
            var seen = Set<String>()
            for value in sourceOutbounds {
                guard var outbound = value.objectValue,
                      let original = outbound["tag"]?.stringValue,
                      let runtime = tagMap[original],
                      seen.insert(original).inserted else { continue }
                outbound["tag"] = .string(runtime)
                if let detour = outbound["detour"]?.stringValue,
                   let mapped = tagMap[detour] {
                    outbound["detour"] = .string(mapped)
                }
                outbound["domain_resolver"] = .string("system")
                // Prefer the currently usable Apple interface while keeping
                // the other address family as a bounded fallback when Wi-Fi,
                // Ethernet, or a VPN changes underneath sing-box.
                outbound["network_strategy"] = .string("hybrid")
                outbound["fallback_delay"] = .string("300ms")
                nodes.append(outbound)
            }
        }
        guard !nodes.isEmpty else { throw NekoPilotError.noNodes }
        nodes.sort { lhs, rhs in
            if lhs["tag"]?.stringValue == selectedNode { return true }
            if rhs["tag"]?.stringValue == selectedNode { return false }
            return (lhs["tag"]?.stringValue ?? "") < (rhs["tag"]?.stringValue ?? "")
        }
        guard var outbounds = config["outbounds"]?.arrayValue,
              let selectorIndex = outbounds.firstIndex(where: {
                  $0.objectValue?["type"]?.stringValue == "selector" &&
                      $0.objectValue?["tag"]?.stringValue == "ExitGateway"
              }), var selector = outbounds[selectorIndex].objectValue else {
            throw NekoPilotError.processFailed(CoreL10n.text(
                "内置配置缺少节点选择器",
                "The bundled configuration has no node selector"
            ))
        }
        selector["outbounds"] = .array(nodes.compactMap { $0["tag"]?.stringValue }.map(JSONValue.string))
        // Selector changes apply to newly created connections. Existing
        // WebSocket, SSE, and long-lived TCP streams retain their established
        // outbound until they end naturally.
        selector["interrupt_exist_connections"] = .bool(false)
        outbounds[selectorIndex] = .object(selector)
        outbounds.append(contentsOf: nodes.map(JSONValue.object))
        config["outbounds"] = .array(outbounds)
    }

    private func installRuleSetBaseline() throws {
        var bundledFiles: [(String, Data)] = []
        for name in ["geoip-cn", "geosite-cn"] {
            guard let source = Self.resourceURL(name: name, extension: "srs", subdirectory: "rules")
                ?? Self.resourceURL(name: name, extension: "srs") else {
                throw NekoPilotError.processFailed(CoreL10n.text(
                    "缺少内置中国规则库",
                    "A bundled China rule set is missing"
                ))
            }
            let bundledData = try Data(contentsOf: source)
            guard RuleSetUpdater.isValidRuleSet(bundledData) else {
                throw NekoPilotError.processFailed(CoreL10n.text(
                    "内置中国规则库无效",
                    "A bundled China rule set is invalid"
                ))
            }
            bundledFiles.append((name, bundledData))
        }
        try RuleSetUpdater.installBundledBaseline(in: paths.ruleSets, files: bundledFiles)
    }

    private static func validIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return value.withCString {
            inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1
        }
    }

    private static func resourceURL(
        name: String,
        extension fileExtension: String,
        subdirectory: String? = nil
    ) -> URL? {
        if let bundled = Bundle.main.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: subdirectory
        ) {
            return bundled
        }
        let fileManager = FileManager.default
        let current = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let relative = "Sources/NekoPilotCore/Resources/" +
            (subdirectory.map { "\($0)/" } ?? "") + "\(name).\(fileExtension)"
        let candidates = [
            current.appendingPathComponent(relative),
            current.appendingPathComponent("native/\(relative)"),
            current.appendingPathComponent("../native/\(relative)"),
        ]
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }
}

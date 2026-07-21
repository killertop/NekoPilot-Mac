import Foundation
import Darwin

public actor ConfigurationCompiler {
    private let paths: AppPaths
    private let settings: SettingsStore
    private let repository: SubscriptionRepository

    public init(paths: AppPaths, settings: SettingsStore, repository: SubscriptionRepository) {
        self.paths = paths
        self.settings = settings
        self.repository = repository
    }

    @discardableResult
    public func compile(
        selectedNode: String?,
        apiEndpoint: LocalAPIEndpoint? = nil
    ) async throws -> URL {
        let config = try await makeConfiguration(
            selectedNode: selectedNode,
            apiEndpoint: apiEndpoint
        )
        try AtomicFile.write(try JSONValue.encodeObject(config, pretty: true), to: paths.runtimeConfig)
        return paths.runtimeConfig
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
            throw NekoPilotError.processFailed("测速配置未生成")
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
            throw NekoPilotError.processFailed("测速节点不能为空")
        }
        // Do not call compile here. An offline URL Test must not overwrite the
        // live runtime configuration with its short-lived API credentials or
        // race a subsequent Connect request.
        let baseConfig = try await makeConfiguration(
            selectedNode: selectedNode,
            apiEndpoint: apiEndpoints[0]
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

    private func makeIsolatedOfflineTestConfiguration(
        from baseConfig: [String: JSONValue]
    ) throws -> URL {
        var config = baseConfig
        config.removeValue(forKey: "inbounds")
        if var log = config["log"]?.objectValue {
            log["disabled"] = .bool(true)
            config["log"] = .object(log)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-URLTest-\(UUID().uuidString)", isDirectory: true)
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

    private func makeConfiguration(
        selectedNode: String?,
        apiEndpoint: LocalAPIEndpoint?
    ) async throws -> [String: JSONValue] {
        var config = try Self.loadTemplate()
        let port = await settings.proxyPort()
        let allowLAN = await settings.bool(SettingsStore.Key.allowLAN)
        let dns = await settings.string(SettingsStore.Key.directDNS, default: DNSResolverDetector.fallback)
        let rules = await settings.rules()
        try installRuleSetBaseline()
        configureRuntime(
            config: &config,
            proxyPort: port,
            allowLAN: allowLAN,
            directDNS: dns,
            apiEndpoint: apiEndpoint
        )
        injectRules(rules, into: &config)
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
            throw NekoPilotError.processFailed("测速配置缺少节点选择器")
        }
        let existing = selector["outbounds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let included = existing.filter { requested.contains($0) }
        guard Set(included) == requested else {
            throw NekoPilotError.processFailed("测速节点未写入运行配置")
        }
        selector["outbounds"] = .array(included.map(JSONValue.string))
        outbounds[selectorIndex] = .object(selector)
        config["outbounds"] = .array(outbounds)
    }

    private static func loadTemplate() throws -> [String: JSONValue] {
        guard let url = resourceURL(name: "base-config", extension: "json") else {
            throw NekoPilotError.processFailed("缺少内置配置模板")
        }
        return try JSONValue.decodeObject(from: Data(contentsOf: url))
    }

    private func configureRuntime(
        config: inout [String: JSONValue],
        proxyPort: Int,
        allowLAN: Bool,
        directDNS: String,
        apiEndpoint: LocalAPIEndpoint?
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

    private func injectRules(_ rules: [RoutingRule], into config: inout [String: JSONValue]) {
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
        route["rules"] = .array(routeRules)
        config["route"] = .object(route)
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
            throw NekoPilotError.processFailed("内置配置缺少节点选择器")
        }
        selector["outbounds"] = .array(nodes.compactMap { $0["tag"]?.stringValue }.map(JSONValue.string))
        // Keep established sessions on their existing path when automatic
        // selection picks a faster node; only new connections use it.
        selector.removeValue(forKey: "interrupt_exist_connections")
        outbounds[selectorIndex] = .object(selector)
        outbounds.append(contentsOf: nodes.map(JSONValue.object))
        config["outbounds"] = .array(outbounds)
    }

    private func installRuleSetBaseline() throws {
        var bundledFiles: [(String, Data)] = []
        for name in ["geoip-cn", "geosite-cn"] {
            guard let source = Self.resourceURL(name: name, extension: "srs", subdirectory: "rules")
                ?? Self.resourceURL(name: name, extension: "srs") else {
                throw NekoPilotError.processFailed("缺少内置中国规则库")
            }
            let bundledData = try Data(contentsOf: source)
            guard RuleSetUpdater.isValidRuleSet(bundledData) else {
                throw NekoPilotError.processFailed("内置中国规则库无效")
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

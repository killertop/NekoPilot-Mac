import Foundation
import NekoPilotCore

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure(description: message) }
}

var checks: [(String, () async throws -> Void)] = []

checks.append(("defaults", {
    try expect(SettingsStore.defaultProxyPort == 16_789, "unexpected default proxy port")
}))

checks.append(("VLESS parser", {
    let config = try ProxyLinkParser.parse(
        "vless://00000000-0000-0000-0000-000000000001@example.com:443?security=reality&pbk=test&sni=example.com#Tokyo"
    )
    let outbound = config["outbounds"]?.arrayValue?.first?.objectValue
    try expect(outbound?["type"]?.stringValue == "vless", "VLESS type was not parsed")
    try expect(outbound?["server"]?.stringValue == "example.com", "VLESS host was not parsed")
    try expect(outbound?["tag"]?.stringValue?.contains("Tokyo") == true, "VLESS label was not parsed")
}))

checks.append(("AnyTLS parser", {
    let config = try ProxyLinkParser.parse(
        "anytls://password@example.com:443?insecure=1#Home"
    )
    let outbound = config["outbounds"]?.arrayValue?.first?.objectValue
    try expect(outbound?["type"]?.stringValue == "anytls", "AnyTLS type was not parsed")
    try expect(outbound?["tls"]?.objectValue?["enabled"]?.boolValue == true, "AnyTLS did not enable TLS")
}))

checks.append(("base64 subscription", {
    let plain = "vless://00000000-0000-0000-0000-000000000001@example.com:443?security=tls#One\n"
    let payload = Data(plain.utf8).base64EncodedData()
    let config = try SubscriptionImporter.parsePayload(payload)
    try expect(config["outbounds"]?.arrayValue?.count == 1, "base64 subscription did not produce one node")
}))

checks.append(("settings persistence", {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("NekoPilot-Settings-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("preferences.json")
    let settings = try SettingsStore(fileURL: file)
    try await settings.set(.number(17_777), for: SettingsStore.Key.proxyPort)
    try await settings.set(.bool(true), for: SettingsStore.Key.showProtocol)
    try await settings.replaceRules([
        RoutingRule(action: .direct, kind: .domainSuffix, value: ".example.local"),
    ])
    let reopened = try SettingsStore(fileURL: file)
    let reopenedPort = await reopened.proxyPort()
    let reopenedProtocol = await reopened.bool(SettingsStore.Key.showProtocol)
    let reopenedRules = await reopened.rules()
    try expect(reopenedPort == 17_777, "proxy port did not persist")
    try expect(reopenedProtocol, "protocol setting did not persist")
    try expect(
        reopenedRules.contains { $0.action == .direct && $0.kind == .domainSuffix && $0.value == ".example.local" },
        "routing rules did not persist"
    )
}))

checks.append(("repository and config compiler", {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("NekoPilot-Compiler-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = AppPaths(applicationSupport: directory, logs: directory.appendingPathComponent("logs"))
    let settings = try SettingsStore(fileURL: paths.settings)
    try await settings.set(.number(17_777), for: SettingsStore.Key.proxyPort)
    try await settings.replaceRules([
        RoutingRule(action: .direct, kind: .domain, value: "direct.example"),
        RoutingRule(action: .proxy, kind: .domainSuffix, value: ".proxy.example"),
    ])
    let repository = try SubscriptionRepository(databaseURL: paths.database)
    let history = ["@np:source:node": DelayRecord(delay: 88, measuredAt: Date(timeIntervalSince1970: 1_000))]
    try await repository.replaceDelayHistory(history)
    let reopenedRepository = try SubscriptionRepository(databaseURL: paths.database)
    let reopenedHistory = try await reopenedRepository.delayHistory()
    try expect(reopenedHistory["@np:source:node"]?.delay == 88, "delay history did not persist in SQLite")
    let imported = try ProxyLinkParser.parse(
        "vless://00000000-0000-0000-0000-000000000001@example.com:443?security=tls#Native"
    )
    let identifier = try await repository.upsert(
        url: nil,
        name: "Local",
        sourceType: .localLink,
        config: imported,
        identifier: "source-a"
    )
    try expect(identifier == "source-a", "repository changed requested identifier")
    let nodes = try await repository.nodes()
    try expect(nodes.count == 1, "repository did not list imported node")
    try expect(nodes[0].runtimeTag == "@np:source-a:VLESS · Native", "stable runtime tag changed")
    let compiler = ConfigurationCompiler(paths: paths, settings: settings, repository: repository)
    let output = try await compiler.compile(selectedNode: nodes[0].runtimeTag)
    let config = try JSONValue.decodeObject(from: Data(contentsOf: output))
    let inboundPort = config["inbounds"]?.arrayValue?.first?.objectValue?["listen_port"]?.numberValue
    try expect(inboundPort == 17_777, "compiler did not inject proxy port")
    let selector = config["outbounds"]?.arrayValue?
        .compactMap(\.objectValue)
        .first { $0["tag"]?.stringValue == "ExitGateway" }
    try expect(
        selector?["outbounds"]?.arrayValue?.first?.stringValue == nodes[0].runtimeTag,
        "compiler did not select stable runtime node"
    )
    let dnsRules = config["dns"]?.objectValue?["rules"]?.arrayValue?.compactMap(\.objectValue) ?? []
    let directDNSRule = dnsRules.first { rule in
        rule["domain"]?.arrayValue?.contains(.string("direct.example")) == true
    }
    try expect(
        directDNSRule?["server"]?.stringValue == "system",
        "custom direct domain did not receive highest-priority direct DNS routing"
    )
    let proxyDNSRule = dnsRules.first { rule in
        rule["domain_suffix"]?.arrayValue?.contains(.string(".proxy.example")) == true
    }
    try expect(
        proxyDNSRule?["server"]?.stringValue == "dns_proxy",
        "custom proxy domain did not override the China direct DNS rule set"
    )
    try await SingBoxValidator.validate(configuration: output)
    let runtimeConfigurationBeforeOfflineTest = try Data(contentsOf: output)
    let offlineAPI = try LocalAPIEndpoint.make()
    let offlineConfigURL = try await compiler.makeOfflineTestConfiguration(
        selectedNode: nodes[0].runtimeTag,
        apiEndpoint: offlineAPI
    )
    defer { try? FileManager.default.removeItem(at: offlineConfigURL.deletingLastPathComponent()) }
    let offlineConfig = try JSONValue.decodeObject(from: Data(contentsOf: offlineConfigURL))
    try expect(offlineConfig["inbounds"] == nil, "offline URL Test config unexpectedly exposed a proxy inbound")
    try expect(
        offlineConfig["services"]?.arrayValue?.first?.objectValue?["listen_port"]?.numberValue == Double(offlineAPI.port),
        "offline URL Test config did not expose the local sing-box API"
    )
    let offlineSelectorNodes = offlineConfig["outbounds"]?.arrayValue?
        .compactMap(\.objectValue)
        .first { $0["tag"]?.stringValue == "ExitGateway" }?["outbounds"]?.arrayValue?.compactMap(\.stringValue)
    try expect(offlineSelectorNodes == [nodes[0].runtimeTag], "offline URL Test did not isolate its node batch")
    let offlineCachePath = offlineConfig["experimental"]?.objectValue?["cache_file"]?.objectValue?["path"]?.stringValue
    try expect(offlineCachePath != paths.cacheDatabase.path, "offline URL Test reused the live cache database")
    let experimentalKeys = Set(offlineConfig["experimental"]?.objectValue.map { Array($0.keys) } ?? [])
    try expect(experimentalKeys == Set(["cache_file"]), "offline URL Test config contains an unexpected experimental service")
    let runtimeConfigurationAfterOfflineTest = try Data(contentsOf: output)
    try expect(
        runtimeConfigurationAfterOfflineTest == runtimeConfigurationBeforeOfflineTest,
        "offline URL Test unexpectedly modified the live runtime configuration"
    )
}))

func importedTestNode(repository: SubscriptionRepository, requiresExternalNode: Bool = false) async throws -> ProxyNode {
    let configuredURL = ProcessInfo.processInfo.environment["NEKOPILOT_TEST_NODE_URL"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let raw: String
    if let configuredURL, !configuredURL.isEmpty {
        raw = configuredURL
    } else if requiresExternalNode {
        throw CheckFailure(description: "NEKOPILOT_TEST_NODE_URL is required for real egress validation")
    } else {
        // Lifecycle validation must not depend on a third-party endpoint. The
        // test node is never dialled; it only exercises config/start/select/reload/stop.
        raw = "vless://00000000-0000-4000-8000-000000000000@127.0.0.1:1?encryption=none&type=tcp#Lifecycle%20Test"
    }
    let importer = SubscriptionImporter(repository: repository)
    let identifier = try await importer.importInput(raw, name: "Runtime Test")
    guard let node = try await repository.nodes().first(where: { $0.sourceIdentifier == identifier }) else {
        throw CheckFailure(description: "the supplied test source produced no usable node")
    }
    return node
}

func importedStoredTestNode(repository: SubscriptionRepository) async throws -> ProxyNode {
    guard let databasePath = ProcessInfo.processInfo.environment["NEKOPILOT_TEST_APP_DATABASE"],
          !databasePath.isEmpty else {
        throw CheckFailure(description: "NEKOPILOT_TEST_APP_DATABASE is required for stored-node validation")
    }
    let sourceRepository = try SubscriptionRepository(databaseURL: URL(fileURLWithPath: databasePath))
    let sourceHistory = try await sourceRepository.delayHistory()
    guard let sourceNode = try await sourceRepository.nodes().sorted(by: { lhs, rhs in
        let leftDelay = sourceHistory[lhs.runtimeTag]?.delay
        let rightDelay = sourceHistory[rhs.runtimeTag]?.delay
        switch (leftDelay, rightDelay) {
        case let (left?, right?): return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return lhs.runtimeTag.localizedStandardCompare(rhs.runtimeTag) == .orderedAscending
        }
    }).first else {
        throw CheckFailure(description: "the selected application database has no usable nodes")
    }
    let identifier = try await repository.upsert(
        url: nil,
        name: "Stored Runtime Test",
        sourceType: .localLink,
        config: ["outbounds": .array([.object(sourceNode.outbound)])]
    )
    guard let imported = try await repository.nodes().first(where: { $0.sourceIdentifier == identifier }) else {
        throw CheckFailure(description: "could not prepare a stored-node validation configuration")
    }
    return imported
}

func importedStoredTestNodes(repository: SubscriptionRepository, limit: Int) async throws -> [ProxyNode] {
    guard let databasePath = ProcessInfo.processInfo.environment["NEKOPILOT_TEST_APP_DATABASE"],
          !databasePath.isEmpty else {
        throw CheckFailure(description: "NEKOPILOT_TEST_APP_DATABASE is required for stored-node validation")
    }
    let sourceRepository = try SubscriptionRepository(databaseURL: URL(fileURLWithPath: databasePath))
    let sourceHistory = try await sourceRepository.delayHistory()
    let candidates = try await sourceRepository.nodes().sorted(by: { lhs, rhs in
        let leftDelay = sourceHistory[lhs.runtimeTag]?.delay
        let rightDelay = sourceHistory[rhs.runtimeTag]?.delay
        switch (leftDelay, rightDelay) {
        case let (left?, right?): return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return lhs.runtimeTag.localizedStandardCompare(rhs.runtimeTag) == .orderedAscending
        }
    })
    let selected = Array(candidates.prefix(max(1, limit)))
    guard !selected.isEmpty else {
        throw CheckFailure(description: "the selected application database has no usable nodes")
    }
    var imported: [ProxyNode] = []
    for (index, sourceNode) in selected.enumerated() {
        let identifier = try await repository.upsert(
            url: nil,
            name: "Stored URL Test \(index + 1)",
            sourceType: .localLink,
            config: ["outbounds": .array([.object(sourceNode.outbound)])],
            identifier: "stored-url-test-\(index + 1)"
        )
        guard let node = try await repository.nodes().first(where: { $0.sourceIdentifier == identifier }) else {
            throw CheckFailure(description: "could not prepare stored URL Test node \(index + 1)")
        }
        imported.append(node)
    }
    return imported
}

if ProcessInfo.processInfo.environment["NEKOPILOT_VALIDATE_REAL_EGRESS"] == "1" {
    checks.append(("offline URL Test reaches the internet", {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Egress-\(UUID().uuidString)", isDirectory: true)
        defer {
            if ProcessInfo.processInfo.environment["NEKOPILOT_KEEP_VALIDATION"] != "1" {
                try? FileManager.default.removeItem(at: directory)
            } else {
                print("kept validation directory: \(directory.path)")
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let paths = AppPaths(applicationSupport: directory, logs: directory.appendingPathComponent("logs"))
        AppLogger.shared.configure(destination: paths.logFile)
        let settings = try SettingsStore(fileURL: paths.settings)
        let repository = try SubscriptionRepository(databaseURL: paths.database)
        let compiler = ConfigurationCompiler(paths: paths, settings: settings, repository: repository)
        let tester = URLTester(compiler: compiler)
        let node: ProxyNode
        if ProcessInfo.processInfo.environment["NEKOPILOT_TEST_APP_DATABASE"] != nil {
            node = try await importedStoredTestNode(repository: repository)
        } else {
            node = try await importedTestNode(repository: repository, requiresExternalNode: true)
        }
        let result = await tester.test(nodes: [node])
        let delay = result[node.runtimeTag]?.delay
        try expect(
            delay != nil,
            "offline URL Test failed for the supplied node (records=\(result.count), has_delay=\(delay != nil))"
        )
}))
}

if ProcessInfo.processInfo.environment["NEKOPILOT_VALIDATE_MULTI_NODE_URL_TEST"] == "1" {
    checks.append(("bounded parallel URL Test reaches multiple real nodes", {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-MultiURLTest-\(UUID().uuidString)", isDirectory: true)
        defer {
            if ProcessInfo.processInfo.environment["NEKOPILOT_KEEP_VALIDATION"] != "1" {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let paths = AppPaths(applicationSupport: directory, logs: directory.appendingPathComponent("logs"))
        AppLogger.shared.configure(destination: paths.logFile)
        let settings = try SettingsStore(fileURL: paths.settings)
        let repository = try SubscriptionRepository(databaseURL: paths.database)
        let compiler = ConfigurationCompiler(paths: paths, settings: settings, repository: repository)
        let tester = URLTester(compiler: compiler)
        let nodes = try await importedStoredTestNodes(repository: repository, limit: 24)
        let startedAt = Date()
        let results = await tester.test(nodes: nodes)
        let elapsed = Date().timeIntervalSince(startedAt)
        try expect(results.count == nodes.count, "parallel URL Test did not return every node result")
        try expect(results.values.contains(where: { $0.delay != nil }), "parallel URL Test did not reach any real node")
        try expect(elapsed < 25, "parallel URL Test exceeded its bounded completion time (\(elapsed)s)")
        print("parallel URL Test: \(nodes.count) nodes in \(String(format: "%.1f", elapsed))s")
    }))
}

if ProcessInfo.processInfo.environment["NEKOPILOT_SKIP_ENGINE_VALIDATION"] != "1" {
    checks.append(("native supervisor starts and stops sing-box", {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Engine-\(UUID().uuidString)", isDirectory: true)
        defer {
            if ProcessInfo.processInfo.environment["NEKOPILOT_KEEP_VALIDATION"] != "1" {
                try? FileManager.default.removeItem(at: directory)
            } else {
                print("kept validation directory: \(directory.path)")
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let paths = AppPaths(applicationSupport: directory, logs: directory.appendingPathComponent("logs"))
        AppLogger.shared.configure(destination: paths.logFile)
        let settings = try SettingsStore(fileURL: paths.settings)
        try await settings.set(.bool(true), for: SettingsStore.Key.skipSystemProxy)
        try await settings.set(.number(17_689), for: SettingsStore.Key.proxyPort)
        let repository = try SubscriptionRepository(databaseURL: paths.database)
        let compiler = ConfigurationCompiler(paths: paths, settings: settings, repository: repository)
        let nativeAPI = NativeControlClient()
        let proxy = SystemProxyManager(markerURL: paths.proxyOwnership)
        let engine = EngineSupervisor(settings: settings, compiler: compiler, systemProxy: proxy, nativeAPI: nativeAPI)
        let node: ProxyNode
        if ProcessInfo.processInfo.environment["NEKOPILOT_TEST_APP_DATABASE"] != nil {
            node = try await importedStoredTestNode(repository: repository)
        } else {
            node = try await importedTestNode(repository: repository)
        }
        let selected = node.runtimeTag
        do {
            try await engine.start(selectedNode: selected)
            let runningStatus = await engine.currentStatus()
            try expect(runningStatus.isRunning, "engine did not reach running state")
            let selector = try await nativeAPI.selector(knownNodes: [selected])
            try expect(selector.nodes.contains(selected), "native selector did not expose selected node")
            let trafficStream = try await nativeAPI.nodeTrafficStream(nodes: [selected], interval: 0.1)
            var trafficIterator = trafficStream.makeAsyncIterator()
            guard let idleTraffic = try await trafficIterator.next() else {
                throw CheckFailure(description: "native connection traffic stream ended before its first sample")
            }
            try expect(
                idleTraffic[selected] == nil,
                "an idle node unexpectedly reported connection traffic"
            )
            try await settings.replaceRules([
                RoutingRule(action: .direct, kind: .domainSuffix, value: ".nekopilot-live-reload.invalid"),
            ])
            try await engine.reload(selectedNode: selected)
            let reloadedSelector = try await nativeAPI.selector(knownNodes: [selected])
            try expect(reloadedSelector.nodes.contains(selected), "selector disappeared after live reload")
            await engine.stop()
            let stoppedStatus = await engine.currentStatus()
            try expect(stoppedStatus == .stopped, "engine did not stop")
        } catch {
            await engine.shutdown()
            throw error
        }
    }))
}

var failures = 0
for (name, check) in checks {
    do {
        try await check()
        print("✓ \(name)")
    } catch {
        failures += 1
        fputs("✗ \(name): \(error)\n", stderr)
    }
}

if failures > 0 {
    exit(1)
}
print("\(checks.count) native core checks passed")

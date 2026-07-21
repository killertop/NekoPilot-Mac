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
    try expect(SettingsStore.clashAPIPort == 19_191, "unexpected Clash API port")
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
    let history = ["@np:source:node": DelayRecord(delay: 88, measuredAt: Date(timeIntervalSince1970: 1_000))]
    try await settings.replaceDelayHistory(history)
    try await settings.replaceRules([
        RoutingRule(action: .direct, kind: .domainSuffix, value: ".example.local"),
    ])
    let reopened = try SettingsStore(fileURL: file)
    let reopenedPort = await reopened.proxyPort()
    let reopenedProtocol = await reopened.bool(SettingsStore.Key.showProtocol)
    let reopenedHistory = await reopened.delayHistory()
    let reopenedRules = await reopened.rules()
    try expect(reopenedPort == 17_777, "proxy port did not persist")
    try expect(reopenedProtocol, "protocol setting did not persist")
    try expect(reopenedHistory["@np:source:node"]?.delay == 88, "delay history did not persist")
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
    let repository = try SubscriptionRepository(databaseURL: paths.database)
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
}))

func importedTestNode(repository: SubscriptionRepository) async throws -> ProxyNode {
    guard let raw = ProcessInfo.processInfo.environment["NEKOPILOT_TEST_NODE_URL"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !raw.isEmpty else {
        throw CheckFailure(description: "NEKOPILOT_TEST_NODE_URL is required for live validation")
    }
    let importer = SubscriptionImporter(repository: repository)
    let identifier = try await importer.importInput(raw, name: "Runtime Test")
    guard let node = try await repository.nodes().first(where: { $0.sourceIdentifier == identifier }) else {
        throw CheckFailure(description: "the supplied test source produced no usable node")
    }
    return node
}

if ProcessInfo.processInfo.environment["NEKOPILOT_VALIDATE_REAL_EGRESS"] == "1" {
    checks.append(("offline URL Test reaches the internet", {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Egress-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let paths = AppPaths(applicationSupport: directory, logs: directory.appendingPathComponent("logs"))
        let settings = try SettingsStore(fileURL: paths.settings)
        let repository = try SubscriptionRepository(databaseURL: paths.database)
        let compiler = ConfigurationCompiler(paths: paths, settings: settings, repository: repository)
        let clash = ClashAPIClient(settings: settings)
        let tester = URLTester(compiler: compiler, clashAPI: clash)
        let node = try await importedTestNode(repository: repository)
        let result = await tester.test(nodes: [node], engineRunning: false)
        try expect(result[node.runtimeTag]?.delay != nil, "offline URL Test failed for the supplied node")
    }))
}

if ProcessInfo.processInfo.environment["NEKOPILOT_VALIDATE_ENGINE"] == "1" {
    checks.append(("native supervisor starts and stops sing-box", {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Engine-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let paths = AppPaths(applicationSupport: directory, logs: directory.appendingPathComponent("logs"))
        AppLogger.shared.configure(destination: paths.logFile)
        let settings = try SettingsStore(fileURL: paths.settings)
        try await settings.set(.bool(true), for: SettingsStore.Key.skipSystemProxy)
        try await settings.set(.number(17_689), for: SettingsStore.Key.proxyPort)
        let repository = try SubscriptionRepository(databaseURL: paths.database)
        let compiler = ConfigurationCompiler(paths: paths, settings: settings, repository: repository)
        let clash = ClashAPIClient(settings: settings)
        let proxy = SystemProxyManager(markerURL: paths.proxyOwnership)
        let engine = EngineSupervisor(settings: settings, compiler: compiler, systemProxy: proxy, clashAPI: clash)
        let selected = try await importedTestNode(repository: repository).runtimeTag
        do {
            try await engine.start(selectedNode: selected)
            let runningStatus = await engine.currentStatus()
            try expect(runningStatus.isRunning, "engine did not reach running state")
            let selector = try await clash.selector()
            try expect(selector.nodes.contains(selected), "Clash selector did not expose selected node")
            let previousSecret = try await settings.clashSecret()
            try await settings.replaceRules([
                RoutingRule(action: .direct, kind: .domainSuffix, value: ".nekopilot-live-reload.invalid"),
            ])
            try await engine.reload(selectedNode: selected)
            let reloadedSecret = try await settings.clashSecret()
            try expect(reloadedSecret != previousSecret, "reload did not cross the new Clash API ownership boundary")
            let reloadedSelector = try await clash.selector()
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

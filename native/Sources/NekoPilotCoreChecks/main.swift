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

checks.append(("legacy settings compatibility", {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("NekoPilot-Settings-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("settings.json")
    let settings = try SettingsStore(fileURL: file)
    try await settings.set(.number(17_777), for: SettingsStore.Key.proxyPort)
    try await settings.set(.bool(true), for: SettingsStore.Key.showProtocol)
    let history = ["@np:source:node": DelayRecord(delay: 88, measuredAt: Date(timeIntervalSince1970: 1_000))]
    try await settings.replaceDelayHistory(history)
    let reopened = try SettingsStore(fileURL: file)
    let reopenedPort = await reopened.proxyPort()
    let reopenedProtocol = await reopened.bool(SettingsStore.Key.showProtocol)
    let reopenedHistory = await reopened.delayHistory()
    try expect(reopenedPort == 17_777, "proxy port did not persist")
    try expect(reopenedProtocol, "protocol setting did not persist")
    try expect(reopenedHistory["@np:source:node"]?.delay == 88, "delay history did not persist")
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

checks.append(("selection source identifier", {
    try expect(
        NodeSelectionCoordinator.sourceIdentifier(from: "@np:source-a:node") == "source-a",
        "selection source identifier parsing changed"
    )
    try expect(
        NodeSelectionCoordinator.sourceIdentifier(from: "plain-node") == nil,
        "plain node unexpectedly produced a source identifier"
    )
}))

if ProcessInfo.processInfo.environment["NEKOPILOT_VALIDATE_EXISTING_DATA"] == "1" {
    checks.append(("existing user data compiles with native core", {
        let sourceRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/dev.nekopilot.desktop", isDirectory: true)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Existing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["data.db", "settings.json"] {
            let source = sourceRoot.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
            }
        }
        let paths = AppPaths(applicationSupport: directory, logs: directory.appendingPathComponent("logs"))
        let settings = try SettingsStore(fileURL: paths.settings)
        let repository = try SubscriptionRepository(databaseURL: paths.database)
        let nodes = try await repository.nodes()
        try expect(!nodes.isEmpty, "existing database has no usable nodes")
        let selected = (await settings.string(SettingsStore.Key.selectedNode)).isEmpty
            ? nodes.first?.runtimeTag
            : await settings.string(SettingsStore.Key.selectedNode)
        let compiler = ConfigurationCompiler(paths: paths, settings: settings, repository: repository)
        let configuration = try await compiler.compile(selectedNode: selected)
        try await SingBoxValidator.validate(configuration: configuration)
    }))
}

if ProcessInfo.processInfo.environment["NEKOPILOT_VALIDATE_REAL_EGRESS"] == "1" {
    checks.append(("offline URL Test reaches the internet", {
        let sourceRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/dev.nekopilot.desktop", isDirectory: true)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Egress-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["data.db", "settings.json"] {
            try FileManager.default.copyItem(
                at: sourceRoot.appendingPathComponent(name),
                to: directory.appendingPathComponent(name)
            )
        }
        let paths = AppPaths(applicationSupport: directory, logs: directory.appendingPathComponent("logs"))
        let settings = try SettingsStore(fileURL: paths.settings)
        let repository = try SubscriptionRepository(databaseURL: paths.database)
        let compiler = ConfigurationCompiler(paths: paths, settings: settings, repository: repository)
        let clash = ClashAPIClient(settings: settings)
        let tester = URLTester(compiler: compiler, clashAPI: clash)
        let nodes = try await repository.nodes()
        guard let node = nodes.first else { throw CheckFailure(description: "no node available for URL Test") }
        let result = await tester.test(nodes: [node], engineRunning: false)
        try expect(result[node.runtimeTag]?.delay != nil, "offline URL Test failed for the first stored node")
    }))
}

if ProcessInfo.processInfo.environment["NEKOPILOT_VALIDATE_ENGINE"] == "1" {
    checks.append(("native supervisor starts and stops sing-box", {
        let sourceRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/dev.nekopilot.desktop", isDirectory: true)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Engine-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["data.db", "settings.json"] {
            try FileManager.default.copyItem(
                at: sourceRoot.appendingPathComponent(name),
                to: directory.appendingPathComponent(name)
            )
        }
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
        let nodes = try await repository.nodes()
        guard let selected = nodes.first?.runtimeTag else { throw CheckFailure(description: "no node available") }
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

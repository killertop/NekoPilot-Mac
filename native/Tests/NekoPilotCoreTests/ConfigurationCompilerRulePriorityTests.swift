import Foundation
import Testing
@testable import NekoPilotCore

private actor RuntimeCandidateValidationGate {
    private let rejectSecondValidation: Bool
    private let rejectFirstAfterRelease: Bool
    private var invocationCount = 0
    private var firstValidationStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRelease: CheckedContinuation<Void, Never>?

    init(
        rejectSecondValidation: Bool = false,
        rejectFirstAfterRelease: Bool = false
    ) {
        self.rejectSecondValidation = rejectSecondValidation
        self.rejectFirstAfterRelease = rejectFirstAfterRelease
    }

    func validate(_ configuration: URL) async throws {
        _ = configuration
        invocationCount += 1
        guard invocationCount == 1 else {
            if rejectSecondValidation {
                throw NekoPilotError.processFailed("newer candidate rejected")
            }
            return
        }
        firstValidationStarted = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            firstRelease = continuation
        }
        if rejectFirstAfterRelease {
            throw NekoPilotError.processFailed("older candidate rejected")
        }
    }

    func waitUntilFirstValidationStarts() async {
        if firstValidationStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstValidation() {
        firstRelease?.resume()
        firstRelease = nil
    }
}

@Suite("Configuration compiler rule priority", .serialized)
struct ConfigurationCompilerRulePriorityTests {
    @Test("Runtime candidates are isolated until their atomic commit")
    func runtimeCandidatesAreIsolatedUntilCommit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Candidate-Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let logs = root.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let paths = AppPaths(applicationSupport: support, logs: logs)
        let settings = try SettingsStore(fileURL: paths.settings)
        let repository = try SubscriptionRepository(databaseURL: paths.database)
        let identifier = try await repository.upsert(
            url: nil,
            name: "Candidates",
            sourceType: .localLink,
            config: [
                "outbounds": .array([
                    .object([
                        "type": .string("vless"),
                        "tag": .string("first"),
                        "server": .string("first.example.com"),
                        "server_port": .number(443),
                        "uuid": .string("00000000-0000-4000-8000-000000000001"),
                    ]),
                    .object([
                        "type": .string("vless"),
                        "tag": .string("second"),
                        "server": .string("second.example.com"),
                        "server_port": .number(443),
                        "uuid": .string("00000000-0000-4000-8000-000000000002"),
                    ]),
                ]),
            ]
        )
        let compiler = ConfigurationCompiler(paths: paths, settings: settings, repository: repository)
        let sentinel = Data("validated-live-configuration".utf8)
        try AtomicFile.write(sentinel, to: paths.runtimeConfig)

        async let firstCandidate = compiler.makeRuntimeConfigurationCandidate(
            selectedNode: "@np:\(identifier):first"
        )
        async let secondCandidate = compiler.makeRuntimeConfigurationCandidate(
            selectedNode: "@np:\(identifier):second"
        )
        let (first, second) = try await (firstCandidate, secondCandidate)
        defer {
            first.discard()
            second.discard()
        }

        #expect(first.configurationURL != second.configurationURL)
        #expect(try Data(contentsOf: paths.runtimeConfig) == sentinel)
        let firstData = try Data(contentsOf: first.configurationURL)
        let secondData = try Data(contentsOf: second.configurationURL)
        #expect(firstData != secondData)

        await compiler.removeAbandonedRuntimeCandidates()
        #expect(FileManager.default.fileExists(atPath: first.configurationURL.path))
        #expect(FileManager.default.fileExists(atPath: second.configurationURL.path))

        let committedURL = try first.commit()
        #expect(committedURL == paths.runtimeConfig)
        #expect(try Data(contentsOf: paths.runtimeConfig) == firstData)
        #expect(!FileManager.default.fileExists(atPath: first.configurationURL.path))
        #expect(FileManager.default.fileExists(atPath: second.configurationURL.path))

        _ = try second.commit()
        #expect(try Data(contentsOf: paths.runtimeConfig) == secondData)
        #expect(!FileManager.default.fileExists(atPath: second.configurationURL.path))
    }

    @Test("Startup recovery removes only abandoned runtime candidates")
    func startupRecoveryRemovesOnlyAbandonedCandidates() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Candidate-Cleanup-Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let logs = root.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let paths = AppPaths(applicationSupport: support, logs: logs)
        let settings = try SettingsStore(fileURL: paths.settings)
        let repository = try SubscriptionRepository(databaseURL: paths.database)
        let compiler = ConfigurationCompiler(paths: paths, settings: settings, repository: repository)
        let abandoned = support.appendingPathComponent(".runtime.json.crashed.candidate")
        let unrelated = support.appendingPathComponent("keep.candidate")
        let live = paths.runtimeConfig
        try AtomicFile.write(Data("secret".utf8), to: abandoned)
        try AtomicFile.write(Data("keep".utf8), to: unrelated)
        try AtomicFile.write(Data("live".utf8), to: live)

        await compiler.removeAbandonedRuntimeCandidates()

        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(try Data(contentsOf: live) == Data("live".utf8))
    }

    @Test("Candidate validation failure publishes a configuration failure")
    func candidateValidationFailureIsTyped() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Configuration-Failure-Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let logs = root.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let paths = AppPaths(applicationSupport: support, logs: logs)
        let settings = try SettingsStore(fileURL: paths.settings)
        let repository = try SubscriptionRepository(databaseURL: paths.database)
        let identifier = try await repository.upsert(
            url: nil,
            name: "Invalid candidate",
            sourceType: .localLink,
            config: [
                "outbounds": .array([.object([
                    "type": .string("vless"),
                    "tag": .string("node"),
                    "server": .string("example.com"),
                    "server_port": .number(443),
                    "uuid": .string("00000000-0000-4000-8000-000000000001"),
                ])]),
            ]
        )
        let compiler = ConfigurationCompiler(paths: paths, settings: settings, repository: repository)
        let engine = EngineSupervisor(
            settings: settings,
            compiler: compiler,
            systemProxy: SystemProxyManager(markerURL: paths.proxyOwnership),
            nativeAPI: NativeControlClient(),
            configurationValidator: { _ in
                throw NekoPilotError.processFailed("validator rejected candidate")
            }
        )

        do {
            try await engine.start(selectedNode: "@np:\(identifier):node")
            Issue.record("Engine started with a rejected candidate")
        } catch let failure as EngineFailure {
            #expect(failure.kind == .configuration)
            #expect(failure.message == "validator rejected candidate")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        guard case let .failed(failure) = await engine.currentStatus() else {
            Issue.record("Engine did not publish a failure state")
            return
        }
        #expect(failure == "validator rejected candidate")
    }

    @Test("A newer preparation cannot be overwritten by an older validation")
    func newerPreparationWins() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Preparation-Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let logs = root.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let paths = AppPaths(applicationSupport: support, logs: logs)
        let settings = try SettingsStore(fileURL: paths.settings)
        let repository = try SubscriptionRepository(databaseURL: paths.database)
        let identifier = try await repository.upsert(
            url: nil,
            name: "Newest wins",
            sourceType: .localLink,
            config: [
                "outbounds": .array([
                    .object([
                        "type": .string("vless"),
                        "tag": .string("older"),
                        "server": .string("older.example.com"),
                        "server_port": .number(443),
                        "uuid": .string("00000000-0000-4000-8000-000000000001"),
                    ]),
                    .object([
                        "type": .string("vless"),
                        "tag": .string("newer"),
                        "server": .string("newer.example.com"),
                        "server_port": .number(443),
                        "uuid": .string("00000000-0000-4000-8000-000000000002"),
                    ]),
                ]),
            ]
        )
        let compiler = ConfigurationCompiler(paths: paths, settings: settings, repository: repository)
        let gate = RuntimeCandidateValidationGate()
        let engine = EngineSupervisor(
            settings: settings,
            compiler: compiler,
            systemProxy: SystemProxyManager(markerURL: paths.proxyOwnership),
            nativeAPI: NativeControlClient(),
            configurationValidator: { try await gate.validate($0) }
        )
        let olderNode = "@np:\(identifier):older"
        let newerNode = "@np:\(identifier):newer"

        let olderPreparation = Task {
            try await engine.prepareConfiguration(selectedNode: olderNode)
        }
        await gate.waitUntilFirstValidationStarts()
        let newerPreparation = Task {
            try await engine.prepareConfiguration(selectedNode: newerNode)
        }
        try await newerPreparation.value
        await gate.releaseFirstValidation()
        do {
            try await olderPreparation.value
            Issue.record("Superseded preparation reported success")
        } catch is CancellationError {
            // Explicit supersession is the expected observable result.
        } catch {
            Issue.record("Unexpected older preparation error: \(error)")
        }

        let liveConfiguration = try JSONValue.decodeObject(from: Data(contentsOf: paths.runtimeConfig))
        let selector = try #require(liveConfiguration["outbounds"]?.arrayValue?.first(where: {
            $0.objectValue?["tag"]?.stringValue == "ExitGateway"
        })?.objectValue)
        #expect(selector["outbounds"]?.arrayValue?.first?.stringValue == newerNode)
    }

    @Test("An older preparation cannot report success when its replacement fails")
    func failedNewerPreparationStillSupersedesOlderRequest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Failed-Newer-Preparation-Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let logs = root.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let paths = AppPaths(applicationSupport: support, logs: logs)
        let settings = try SettingsStore(fileURL: paths.settings)
        let repository = try SubscriptionRepository(databaseURL: paths.database)
        let identifier = try await repository.upsert(
            url: nil,
            name: "Failed newest",
            sourceType: .localLink,
            config: [
                "outbounds": .array([
                    .object([
                        "type": .string("vless"),
                        "tag": .string("older"),
                        "server": .string("older.example.com"),
                        "server_port": .number(443),
                        "uuid": .string("00000000-0000-4000-8000-000000000001"),
                    ]),
                    .object([
                        "type": .string("vless"),
                        "tag": .string("newer"),
                        "server": .string("newer.example.com"),
                        "server_port": .number(443),
                        "uuid": .string("00000000-0000-4000-8000-000000000002"),
                    ]),
                ]),
            ]
        )
        let compiler = ConfigurationCompiler(paths: paths, settings: settings, repository: repository)
        let sentinel = Data("last-known-good".utf8)
        try AtomicFile.write(sentinel, to: paths.runtimeConfig)
        let gate = RuntimeCandidateValidationGate(rejectSecondValidation: true)
        let engine = EngineSupervisor(
            settings: settings,
            compiler: compiler,
            systemProxy: SystemProxyManager(markerURL: paths.proxyOwnership),
            nativeAPI: NativeControlClient(),
            configurationValidator: { try await gate.validate($0) }
        )

        let olderPreparation = Task {
            try await engine.prepareConfiguration(selectedNode: "@np:\(identifier):older")
        }
        await gate.waitUntilFirstValidationStarts()
        do {
            try await engine.prepareConfiguration(selectedNode: "@np:\(identifier):newer")
            Issue.record("Rejected newer preparation reported success")
        } catch let failure as EngineFailure {
            #expect(failure.kind == .configuration)
            #expect(failure.message == "newer candidate rejected")
        } catch {
            Issue.record("Unexpected newer preparation error: \(error)")
        }
        await gate.releaseFirstValidation()
        do {
            try await olderPreparation.value
            Issue.record("Superseded older preparation reported success")
        } catch is CancellationError {
            // The caller can now distinguish supersession from persistence.
        } catch {
            Issue.record("Unexpected older preparation error: \(error)")
        }
        #expect(try Data(contentsOf: paths.runtimeConfig) == sentinel)
    }

    @Test("A stale validation error cannot replace a newer successful preparation")
    func failedOlderPreparationIsReportedAsSuperseded() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Failed-Older-Preparation-Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let logs = root.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let paths = AppPaths(applicationSupport: support, logs: logs)
        let settings = try SettingsStore(fileURL: paths.settings)
        let repository = try SubscriptionRepository(databaseURL: paths.database)
        let identifier = try await repository.upsert(
            url: nil,
            name: "Failed older",
            sourceType: .localLink,
            config: [
                "outbounds": .array([
                    .object([
                        "type": .string("vless"),
                        "tag": .string("older"),
                        "server": .string("older.example.com"),
                        "server_port": .number(443),
                        "uuid": .string("00000000-0000-4000-8000-000000000001"),
                    ]),
                    .object([
                        "type": .string("vless"),
                        "tag": .string("newer"),
                        "server": .string("newer.example.com"),
                        "server_port": .number(443),
                        "uuid": .string("00000000-0000-4000-8000-000000000002"),
                    ]),
                ]),
            ]
        )
        let compiler = ConfigurationCompiler(paths: paths, settings: settings, repository: repository)
        let gate = RuntimeCandidateValidationGate(rejectFirstAfterRelease: true)
        let engine = EngineSupervisor(
            settings: settings,
            compiler: compiler,
            systemProxy: SystemProxyManager(markerURL: paths.proxyOwnership),
            nativeAPI: NativeControlClient(),
            configurationValidator: { try await gate.validate($0) }
        )

        let olderPreparation = Task {
            try await engine.prepareConfiguration(selectedNode: "@np:\(identifier):older")
        }
        await gate.waitUntilFirstValidationStarts()
        try await engine.prepareConfiguration(selectedNode: "@np:\(identifier):newer")
        await gate.releaseFirstValidation()

        do {
            try await olderPreparation.value
            Issue.record("Stale validation failure was reported as current")
        } catch is CancellationError {
            // The newer successful preparation owns the observable result.
        } catch {
            Issue.record("Unexpected stale preparation error: \(error)")
        }

        let liveConfiguration = try JSONValue.decodeObject(from: Data(contentsOf: paths.runtimeConfig))
        let selector = try #require(liveConfiguration["outbounds"]?.arrayValue?.first(where: {
            $0.objectValue?["tag"]?.stringValue == "ExitGateway"
        })?.objectValue)
        #expect(selector["outbounds"]?.arrayValue?.first?.stringValue == "@np:\(identifier):newer")
    }

    @Test("Candidate validation preserves actionable typed errors")
    func candidateValidationPreservesTypedErrors() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Typed-Validator-Error-Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let logs = root.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let paths = AppPaths(applicationSupport: support, logs: logs)
        let settings = try SettingsStore(fileURL: paths.settings)
        let repository = try SubscriptionRepository(databaseURL: paths.database)
        let identifier = try await repository.upsert(
            url: nil,
            name: "Typed validator error",
            sourceType: .localLink,
            config: [
                "outbounds": .array([.object([
                    "type": .string("vless"),
                    "tag": .string("node"),
                    "server": .string("example.com"),
                    "server_port": .number(443),
                    "uuid": .string("00000000-0000-4000-8000-000000000001"),
                ])]),
            ]
        )
        let compiler = ConfigurationCompiler(paths: paths, settings: settings, repository: repository)
        let engine = EngineSupervisor(
            settings: settings,
            compiler: compiler,
            systemProxy: SystemProxyManager(markerURL: paths.proxyOwnership),
            nativeAPI: NativeControlClient(),
            configurationValidator: { _ in throw NekoPilotError.singBoxMissing }
        )

        do {
            try await engine.prepareConfiguration(selectedNode: "@np:\(identifier):node")
            Issue.record("Missing sing-box error was swallowed")
        } catch let error as NekoPilotError {
            #expect(error == .singBoxMissing)
        } catch {
            Issue.record("Unexpected validator error: \(error)")
        }

        let controlFailure = EngineFailure(kind: .control, message: "validator transport unavailable")
        let typedEngine = EngineSupervisor(
            settings: settings,
            compiler: compiler,
            systemProxy: SystemProxyManager(markerURL: paths.proxyOwnership),
            nativeAPI: NativeControlClient(),
            configurationValidator: { _ in throw controlFailure }
        )
        do {
            try await typedEngine.prepareConfiguration(selectedNode: "@np:\(identifier):node")
            Issue.record("Typed validator error was swallowed")
        } catch let failure as EngineFailure {
            #expect(failure == controlFailure)
        } catch {
            Issue.record("Unexpected typed validator error: \(error)")
        }
    }

    @Test("Health probe routing is inbound-scoped, optional, and highest priority")
    func healthProbeRoutingIsInboundScopedAndOptional() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Compiler-Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let logs = root.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let paths = AppPaths(applicationSupport: support, logs: logs)
        let settings = try SettingsStore(fileURL: paths.settings)
        let repository = try SubscriptionRepository(databaseURL: paths.database)
        var rules = try await settings.rulesInstallingDefaultsIfNeeded()
        rules.append(RoutingRule(
            action: .direct,
            kind: .domain,
            value: ProxyHealthEndpoint.host
        ))
        try await settings.replaceRules(rules)
        try await settings.set(.number(20_808), for: SettingsStore.Key.proxyPort)
        let sourceIdentifier = try await repository.upsert(
            url: nil,
            name: "Test",
            sourceType: .localLink,
            config: [
                "outbounds": .array([.object([
                    "type": .string("vless"),
                    "tag": .string("node"),
                    "server": .string("example.com"),
                    "server_port": .number(443),
                    "uuid": .string("00000000-0000-4000-8000-000000000000"),
                ])]),
            ]
        )
        let compiler = ConfigurationCompiler(paths: paths, settings: settings, repository: repository)
        let selectedNode = "@np:\(sourceIdentifier):node"
        let healthProbePort = 39_876
        let runtimeSettings = await settings.runtimeConfiguration()
        // A later UI write must not change only one field of an in-flight
        // engine start. The compiler consumes the snapshot captured above.
        try await settings.set(.number(30_303), for: SettingsStore.Key.proxyPort)
        let configURL = try await compiler.compile(
            selectedNode: selectedNode,
            healthProbePort: healthProbePort,
            runtimeSettings: runtimeSettings
        )
        let config = try JSONValue.decodeObject(from: Data(contentsOf: configURL))

        let inbounds = config["inbounds"]?.arrayValue ?? []
        #expect(inbounds.contains(where: {
            $0.objectValue?["listen_port"]?.numberValue == 20_808
        }))
        #expect(!inbounds.contains(where: {
            $0.objectValue?["listen_port"]?.numberValue == 30_303
        }))
        let healthInbound = try #require(inbounds.first(where: {
            $0.objectValue?["tag"]?.stringValue == ProxyHealthEndpoint.inboundTag
        })?.objectValue)
        #expect(Set(healthInbound.keys) == ["tag", "type", "listen", "listen_port"])
        #expect(healthInbound["type"]?.stringValue == "mixed")
        #expect(healthInbound["listen"]?.stringValue == "127.0.0.1")
        #expect(healthInbound["listen_port"]?.numberValue == Double(healthProbePort))

        let routeRules = config["route"]?.objectValue?["rules"]?.arrayValue ?? []
        let proxyRouteIndex = try #require(routeRules.firstIndex(where: { value in
            let rule = value.objectValue
            let suffixes: Set<String> = Set(rule?["domain_suffix"]?.arrayValue?.compactMap { $0.stringValue } ?? [])
            return rule?["outbound"]?.stringValue == "ExitGateway"
                && Set(SettingsStore.defaultProxyDomainSuffixes).isSubset(of: suffixes)
        }))
        let chinaRouteIndex = try #require(routeRules.firstIndex(where: { value in
            let ruleSets: Set<String> = Set(value.objectValue?["rule_set"]?.arrayValue?.compactMap { $0.stringValue } ?? [])
            return ruleSets.contains("geosite-cn") || ruleSets.contains("geoip-cn")
        }))
        #expect(proxyRouteIndex < chinaRouteIndex)
        let healthRouteIndex = try #require(routeRules.firstIndex(where: { value in
            let rule = value.objectValue
            return rule?["outbound"]?.stringValue == "ExitGateway"
                && rule?["inbound"]?.arrayValue?.compactMap(\.stringValue) == [ProxyHealthEndpoint.inboundTag]
        }))
        let healthRouteRule = try #require(routeRules[healthRouteIndex].objectValue)
        #expect(Set(healthRouteRule.keys) == ["inbound", "outbound"])
        let customDirectRouteIndex = try #require(routeRules.firstIndex(where: { value in
            let rule = value.objectValue
            let domains = rule?["domain"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return rule?["outbound"]?.stringValue == "direct"
                && domains.contains(ProxyHealthEndpoint.host)
        }))
        #expect(healthRouteIndex < customDirectRouteIndex)
        #expect(routeRules[customDirectRouteIndex].objectValue?["inbound"] == nil)

        let dnsRules = config["dns"]?.objectValue?["rules"]?.arrayValue ?? []
        let proxyDNSIndex = try #require(dnsRules.firstIndex(where: { value in
            let rule = value.objectValue
            let suffixes: Set<String> = Set(rule?["domain_suffix"]?.arrayValue?.compactMap { $0.stringValue } ?? [])
            return rule?["server"]?.stringValue == "dns_proxy"
                && Set(SettingsStore.defaultProxyDomainSuffixes).isSubset(of: suffixes)
        }))
        let chinaDNSIndex = try #require(dnsRules.firstIndex(where: { value in
            let ruleSets: Set<String> = Set(value.objectValue?["rule_set"]?.arrayValue?.compactMap { $0.stringValue } ?? [])
            return ruleSets.contains("geosite-cn") || ruleSets.contains("geoip-cn")
        }))
        #expect(proxyDNSIndex < chinaDNSIndex)
        let healthDNSIndex = try #require(dnsRules.firstIndex(where: { value in
            let rule = value.objectValue
            return rule?["server"]?.stringValue == "dns_proxy"
                && rule?["inbound"]?.arrayValue?.compactMap(\.stringValue) == [ProxyHealthEndpoint.inboundTag]
        }))
        let healthDNSRule = try #require(dnsRules[healthDNSIndex].objectValue)
        #expect(Set(healthDNSRule.keys) == ["inbound", "action", "server"])
        let customDirectDNSIndex = try #require(dnsRules.firstIndex(where: { value in
            let rule = value.objectValue
            let domains = rule?["domain"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return rule?["server"]?.stringValue == "system"
                && domains.contains(ProxyHealthEndpoint.host)
        }))
        #expect(healthDNSIndex < customDirectDNSIndex)
        #expect(dnsRules[customDirectDNSIndex].objectValue?["inbound"] == nil)

        let selector = try #require(config["outbounds"]?.arrayValue?.first(where: { value in
            let outbound = value.objectValue
            return outbound?["type"]?.stringValue == "selector"
                && outbound?["tag"]?.stringValue == "ExitGateway"
        })?.objectValue)
        #expect(selector["interrupt_exist_connections"]?.boolValue == true)

        let disabledURL = try await compiler.compile(selectedNode: selectedNode)
        let disabledConfig = try JSONValue.decodeObject(from: Data(contentsOf: disabledURL))
        let disabledInbounds = disabledConfig["inbounds"]?.arrayValue ?? []
        #expect(!disabledInbounds.contains(where: {
            $0.objectValue?["tag"]?.stringValue == ProxyHealthEndpoint.inboundTag
        }))
        let disabledRouteRules = disabledConfig["route"]?.objectValue?["rules"]?.arrayValue ?? []
        #expect(!disabledRouteRules.contains(where: { value in
            value.objectValue?["inbound"]?.arrayValue?.compactMap(\.stringValue)
                .contains(ProxyHealthEndpoint.inboundTag) == true
        }))
        let disabledDNSRules = disabledConfig["dns"]?.objectValue?["rules"]?.arrayValue ?? []
        #expect(!disabledDNSRules.contains(where: { value in
            value.objectValue?["inbound"]?.arrayValue?.compactMap(\.stringValue)
                .contains(ProxyHealthEndpoint.inboundTag) == true
        }))
        #expect(disabledRouteRules.contains(where: { value in
            let rule = value.objectValue
            return rule?["outbound"]?.stringValue == "direct"
                && rule?["domain"]?.arrayValue?.compactMap(\.stringValue)
                    .contains(ProxyHealthEndpoint.host) == true
        }))
        #expect(disabledDNSRules.contains(where: { value in
            let rule = value.objectValue
            return rule?["server"]?.stringValue == "system"
                && rule?["domain"]?.arrayValue?.compactMap(\.stringValue)
                    .contains(ProxyHealthEndpoint.host) == true
        }))
    }

    @Test("Location probe worker is isolated and cannot bypass its selector")
    func locationProbeWorkerIsIsolated() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Location-Compiler-Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let logs = root.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let paths = AppPaths(applicationSupport: support, logs: logs)
        let settings = try SettingsStore(fileURL: paths.settings)
        try await settings.replaceRules([
            RoutingRule(action: .direct, kind: .domain, value: "speed.cloudflare.com"),
            RoutingRule(action: .direct, kind: .domain, value: "www.cloudflare.com"),
        ])
        let repository = try SubscriptionRepository(databaseURL: paths.database)
        let identifier = try await repository.upsert(
            url: nil,
            name: "Location Test",
            sourceType: .localLink,
            config: [
                "outbounds": .array([
                    .object([
                        "type": .string("vless"),
                        "tag": .string("included"),
                        "server": .string("included.example.com"),
                        "server_port": .number(443),
                        "uuid": .string("00000000-0000-4000-8000-000000000001"),
                        "detour": .string("relay"),
                    ]),
                    .object([
                        "type": .string("vless"),
                        "tag": .string("excluded"),
                        "server": .string("excluded.example.com"),
                        "server_port": .number(443),
                        "uuid": .string("00000000-0000-4000-8000-000000000002"),
                    ]),
                    .object([
                        "type": .string("vless"),
                        "tag": .string("relay"),
                        "server": .string("relay.example.com"),
                        "server_port": .number(443),
                        "uuid": .string("00000000-0000-4000-8000-000000000003"),
                    ]),
                ]),
            ]
        )
        let selectedNode = "@np:\(identifier):included"
        let sentinel = Data("live-config-must-not-change".utf8)
        try sentinel.write(to: paths.runtimeConfig, options: .atomic)

        let compiler = ConfigurationCompiler(paths: paths, settings: settings, repository: repository)
        let apiEndpoint = LocalAPIEndpoint(port: 39_880, secret: "location-test-secret")
        let proxyPort = 39_881
        let generated = try await compiler.makeLocationProbeConfigurations(
            selectedNodeGroups: [[selectedNode]],
            apiEndpoints: [apiEndpoint],
            proxyPorts: [proxyPort]
        )
        let configURL = try #require(generated.first)
        defer { try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent()) }
        try await SingBoxValidator.validate(configuration: configURL)
        let config = try JSONValue.decodeObject(from: Data(contentsOf: configURL))

        #expect(try Data(contentsOf: paths.runtimeConfig) == sentinel)
        let inbounds = config["inbounds"]?.arrayValue ?? []
        #expect(inbounds.count == 1)
        let inbound = try #require(inbounds.first?.objectValue)
        #expect(Set(inbound.keys) == ["tag", "type", "listen", "listen_port"])
        #expect(inbound["tag"]?.stringValue == NodeLocationProbeEndpoint.inboundTag)
        #expect(inbound["type"]?.stringValue == "mixed")
        #expect(inbound["listen"]?.stringValue == "127.0.0.1")
        #expect(inbound["listen_port"]?.numberValue == Double(proxyPort))

        let routeRules = config["route"]?.objectValue?["rules"]?.arrayValue ?? []
        let locationRoute = try #require(routeRules.first?.objectValue)
        #expect(Set(locationRoute.keys) == ["inbound", "outbound"])
        #expect(locationRoute["inbound"]?.arrayValue?.compactMap(\.stringValue) == [NodeLocationProbeEndpoint.inboundTag])
        #expect(locationRoute["outbound"]?.stringValue == "ExitGateway")
        let customDirectIndex = try #require(routeRules.firstIndex(where: { value in
            let domains = value.objectValue?["domain"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return value.objectValue?["outbound"]?.stringValue == "direct"
                && domains.contains("speed.cloudflare.com")
        }))
        #expect(customDirectIndex > 0)

        let dnsRules = config["dns"]?.objectValue?["rules"]?.arrayValue ?? []
        let locationDNS = try #require(dnsRules.first?.objectValue)
        #expect(Set(locationDNS.keys) == ["inbound", "action", "server"])
        #expect(locationDNS["inbound"]?.arrayValue?.compactMap(\.stringValue) == [NodeLocationProbeEndpoint.inboundTag])
        #expect(locationDNS["action"]?.stringValue == "route")
        #expect(locationDNS["server"]?.stringValue == "dns_proxy")
        let customDirectDNSIndex = try #require(dnsRules.firstIndex(where: { value in
            let domains = value.objectValue?["domain"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return value.objectValue?["server"]?.stringValue == "system"
                && domains.contains("speed.cloudflare.com")
        }))
        #expect(customDirectDNSIndex > 0)

        let selector = try #require(config["outbounds"]?.arrayValue?.first(where: { value in
            value.objectValue?["tag"]?.stringValue == "ExitGateway"
        })?.objectValue)
        #expect(selector["outbounds"]?.arrayValue?.compactMap(\.stringValue) == [selectedNode])
        #expect(selector["interrupt_exist_connections"]?.boolValue == true)
        let workerOutboundTags = Set(
            config["outbounds"]?.arrayValue?.compactMap {
                $0.objectValue?["tag"]?.stringValue
            } ?? []
        )
        #expect(workerOutboundTags.contains(selectedNode))
        #expect(workerOutboundTags.contains("@np:\(identifier):relay"))
        #expect(!workerOutboundTags.contains("@np:\(identifier):excluded"))
        let cachePath = try #require(config["experimental"]?.objectValue?["cache_file"]?.objectValue?["path"]?.stringValue)
        #expect(cachePath.hasPrefix(configURL.deletingLastPathComponent().path))
        #expect(cachePath != paths.cacheDatabase.path)
        #expect(config["log"]?.objectValue?["disabled"]?.boolValue == true)
    }
}

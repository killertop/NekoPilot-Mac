import Foundation
import Testing
@testable import NekoPilotCore

@Suite("Configuration compiler rule priority", .serialized)
struct ConfigurationCompilerRulePriorityTests {
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
        let configURL = try await compiler.compile(
            selectedNode: selectedNode,
            healthProbePort: healthProbePort
        )
        let config = try JSONValue.decodeObject(from: Data(contentsOf: configURL))

        let inbounds = config["inbounds"]?.arrayValue ?? []
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
}

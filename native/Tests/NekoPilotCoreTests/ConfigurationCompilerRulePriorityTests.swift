import Foundation
import Testing
@testable import NekoPilotCore

@Suite("Configuration compiler rule priority", .serialized)
struct ConfigurationCompilerRulePriorityTests {
    @Test("Visible default proxy suffixes precede China rule sets in route and DNS")
    func defaultProxySuffixesPrecedeChinaRuleSets() async throws {
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
        _ = try await settings.rulesInstallingDefaultsIfNeeded()
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
        let configURL = try await compiler.compile(selectedNode: "@np:\(sourceIdentifier):node")
        let config = try JSONValue.decodeObject(from: Data(contentsOf: configURL))

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
    }
}

import Foundation
import Testing
@testable import NekoPilotCore

@Suite("Settings store", .serialized)
struct SettingsStoreTests {
    @Test("Server location display defaults off and persists only booleans")
    func serverLocationDisplaySetting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Settings-Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("preferences.json")
        let settings = try SettingsStore(fileURL: file)

        #expect(await settings.bool(SettingsStore.Key.showServerLocation) == false)
        try await settings.set(.bool(true), for: SettingsStore.Key.showServerLocation)
        #expect(await settings.bool(SettingsStore.Key.showServerLocation) == true)
        let reopened = try SettingsStore(fileURL: file)
        #expect(await reopened.bool(SettingsStore.Key.showServerLocation) == true)

        do {
            try await reopened.set(.string("true"), for: SettingsStore.Key.showServerLocation)
            Issue.record("Expected the non-boolean location setting to be rejected")
        } catch {
            #expect(error as? NekoPilotError == .invalidSetting(SettingsStore.Key.showServerLocation))
        }
    }

    @Test("Legacy delay history migrates once and is removed from preferences")
    func legacyDelayHistoryMigratesOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Settings-Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("preferences.json")
        let settings = try SettingsStore(fileURL: file)
        let record = DelayRecord(delay: 73, measuredAt: Date(timeIntervalSince1970: 1_234))

        try await settings.replaceDelayHistory(["node": record])
        let migrated = try await settings.takeLegacyDelayHistory()
        #expect(migrated["node"] == record)

        let reopened = try SettingsStore(fileURL: file)
        #expect(await reopened.delayHistory().isEmpty)
        #expect(try await reopened.takeLegacyDelayHistory().isEmpty)
    }

    @Test("Runtime configuration is captured as one typed snapshot")
    func runtimeConfigurationSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Settings-Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = try SettingsStore(fileURL: directory.appendingPathComponent("preferences.json"))
        let rule = RoutingRule(action: .direct, kind: .domainSuffix, value: "example.com")
        try await settings.set(.number(20_808), for: SettingsStore.Key.proxyPort)
        try await settings.set(.bool(true), for: SettingsStore.Key.allowLAN)
        try await settings.set(.bool(true), for: SettingsStore.Key.skipSystemProxy)
        try await settings.set(.string("1.1.1.1"), for: SettingsStore.Key.directDNS)
        try await settings.replaceRules([rule])

        let snapshot = await settings.runtimeConfiguration()
        try await settings.set(.number(30_303), for: SettingsStore.Key.proxyPort)
        try await settings.set(.bool(false), for: SettingsStore.Key.allowLAN)

        #expect(snapshot.proxyPort == 20_808)
        #expect(snapshot.allowLAN)
        #expect(snapshot.skipSystemProxy)
        #expect(snapshot.directDNS == "1.1.1.1")
        #expect(snapshot.rules.count == 1)
        #expect(snapshot.rules.first?.action == rule.action)
        #expect(snapshot.rules.first?.kind == rule.kind)
        #expect(snapshot.rules.first?.value == rule.value)
        #expect(await settings.runtimeConfiguration().proxyPort == 30_303)
    }

    @Test("Default proxy suffixes are visible once and stay deleted")
    func defaultProxySuffixesSeedOnlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Settings-Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("preferences.json")
        let settings = try SettingsStore(fileURL: file)

        let seeded = try await settings.rulesInstallingDefaultsIfNeeded()
        let visibleDefaults = seeded.filter { rule in
            rule.action == .proxy && rule.kind == .domainSuffix
                && SettingsStore.defaultProxyDomainSuffixes.contains(rule.value)
        }
        #expect(visibleDefaults.count == SettingsStore.defaultProxyDomainSuffixes.count)

        try await settings.replaceRules([])
        let reopened = try SettingsStore(fileURL: file)
        #expect(try await reopened.rulesInstallingDefaultsIfNeeded().isEmpty)
    }

    @Test("Default proxy seeding respects an existing user decision")
    func defaultProxySuffixesPreserveExistingAction() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Settings-Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = try SettingsStore(fileURL: directory.appendingPathComponent("preferences.json"))
        let direct = RoutingRule(action: .direct, kind: .domainSuffix, value: "googleapis.com")
        try await settings.replaceRules([direct])

        let seeded = try await settings.rulesInstallingDefaultsIfNeeded()
        let preservesDirect = seeded.contains(where: {
            $0.action == .direct && $0.kind == .domainSuffix && $0.value == "googleapis.com"
        })
        let addsConflictingProxy = seeded.contains(where: {
            $0.action == .proxy && $0.kind == .domainSuffix && $0.value == "googleapis.com"
        })
        let addsOtherDefault = seeded.contains(where: {
            $0.action == .proxy && $0.kind == .domainSuffix && $0.value == "gstatic.com"
        })
        #expect(preservesDirect)
        #expect(!addsConflictingProxy)
        #expect(addsOtherDefault)
    }
}

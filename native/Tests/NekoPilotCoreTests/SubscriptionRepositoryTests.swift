import Foundation
import Testing
@testable import NekoPilotCore

@Suite("Subscription repository", .serialized)
struct SubscriptionRepositoryTests {
    @Test("Legacy migration deduplicates rows and adds source type")
    func legacyMigrationDeduplicatesAndAddsSourceType() async throws {
        let location = try temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try createLegacyDatabase(at: location.database)

        let repository = try SubscriptionRepository(databaseURL: location.database)
        let subscriptions = try await repository.subscriptions()
        let migratedNodes = try await repository.nodes()
        #expect(subscriptions.map(\.identifier) == ["new"])
        #expect(subscriptions.first?.sourceType == .subscription)
        #expect(subscriptions.first?.lastUpdateTime.timeIntervalSince1970 == 1_784_554_018)
        #expect(migratedNodes.map(\.originalTag) == ["new-node"])

        let inspection = try SQLiteDatabase(url: location.database)
        let sourceTypeColumns = try inspection.query("PRAGMA table_info(subscriptions)") {
            SQLiteDatabase.text($0, 1) ?? ""
        }
        #expect(sourceTypeColumns.contains("source_type"))
        #expect(try count(in: inspection, table: "subscriptions") == 1)
        #expect(try count(in: inspection, table: "subscription_configs") == 1)
        let storedTimestamp = try inspection.query(
            "SELECT last_update_time FROM subscriptions WHERE identifier = 'new'"
        ) { SQLiteDatabase.integer($0, 0) }.first
        #expect(storedTimestamp == 1_784_554_018_889)
        let indexNames = try inspection.query(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name IN ('subscriptions_url_unique', 'subscription_configs_identifier_unique')"
        ) { SQLiteDatabase.text($0, 0) ?? "" }
        #expect(Set(indexNames) == Set(["subscriptions_url_unique", "subscription_configs_identifier_unique"]))

        try await repository.delete(identifier: "new")
        #expect(try count(in: inspection, table: "subscriptions") == 0)
        #expect(try count(in: inspection, table: "subscription_configs") == 0)
    }

    @Test("Upsert rolls back metadata when config write fails")
    func upsertRollsBackMetadataWhenConfigWriteFails() async throws {
        let location = try temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let repository = try SubscriptionRepository(databaseURL: location.database)
        let identifier = try await repository.upsert(
            url: "https://example.com/sub",
            name: "Before",
            sourceType: .subscription,
            config: configuration(tag: "original")
        )

        let inspection = try SQLiteDatabase(url: location.database)
        let storedTimestamp = try inspection.query(
            "SELECT last_update_time FROM subscriptions WHERE identifier = ?",
            bindings: [.text(identifier)]
        ) { SQLiteDatabase.integer($0, 0) }.first
        #expect(storedTimestamp.map { $0 >= SubscriptionRepository.millisecondEpochThreshold } == true)
        try inspection.execute(
            "CREATE TRIGGER reject_config_update BEFORE UPDATE ON subscription_configs BEGIN SELECT RAISE(ABORT, 'test failure'); END"
        )
        do {
            _ = try await repository.upsert(
                url: "https://example.com/sub",
                name: "After",
                sourceType: .subscription,
                config: configuration(tag: "replacement"),
                identifier: identifier
            )
            Issue.record("Expected the trigger to reject the config update")
        } catch {
            // Expected: both writes in the repository transaction roll back.
        }

        let subscription = try await repository.subscription(identifier: identifier)
        let nodes = try await repository.nodes()
        #expect(subscription?.name == "Before")
        #expect(nodes.map(\.originalTag) == ["original"])
    }

    private func createLegacyDatabase(at url: URL) throws {
        let database = try SQLiteDatabase(url: url)
        try database.execute(
            "CREATE TABLE subscriptions (id INTEGER PRIMARY KEY AUTOINCREMENT, identifier TEXT NOT NULL UNIQUE, name TEXT, used_traffic INTEGER DEFAULT 0, total_traffic INTEGER DEFAULT 0, subscription_url TEXT, official_website TEXT, expire_time INTEGER DEFAULT 0, last_update_time INTEGER DEFAULT 0)"
        )
        try database.execute(
            "CREATE TABLE subscription_configs (id INTEGER PRIMARY KEY AUTOINCREMENT, identifier TEXT NOT NULL, config_content TEXT)"
        )
        try database.execute(
            "INSERT INTO subscriptions(identifier, name, subscription_url, last_update_time) VALUES ('old', 'Old', 'https://example.com/sub', 1784554000000), ('new', 'New', 'https://example.com/sub', 1784554018889)"
        )
        try database.execute(
            "INSERT INTO subscription_configs(identifier, config_content) VALUES ('old', ?), ('new', ?), ('new', ?), ('orphan', '{}')",
            bindings: [
                .text(try configurationText(tag: "old-node")),
                .text(try configurationText(tag: "stale-new-node")),
                .text(try configurationText(tag: "new-node")),
            ]
        )
    }

    private func configuration(tag: String) -> [String: JSONValue] {
        [
            "outbounds": .array([.object([
                "type": .string("vless"),
                "tag": .string(tag),
                "server": .string("example.com"),
                "server_port": .number(443),
                "uuid": .string("uuid"),
            ])]),
        ]
    }

    private func configurationText(tag: String) throws -> String {
        let data = try JSONValue.encodeObject(configuration(tag: tag))
        guard let text = String(data: data, encoding: .utf8) else {
            throw NekoPilotError.invalidSubscription
        }
        return text
    }

    private func temporaryDatabaseLocation() throws -> (directory: URL, database: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilotCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("subscriptions.db"))
    }

    private func count(in database: SQLiteDatabase, table: String) throws -> Int64 {
        try database.query("SELECT COUNT(*) FROM \(table)") {
            SQLiteDatabase.integer($0, 0)
        }.first ?? 0
    }
}

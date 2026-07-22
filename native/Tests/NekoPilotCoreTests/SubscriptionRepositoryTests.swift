import Foundation
import Testing
@testable import NekoPilotCore

@Suite("Subscription repository", .serialized)
struct SubscriptionRepositoryTests {
    @Test("Fresh schema keeps only current subscription fields and cascades deletes")
    func freshSchemaUsesCurrentConstraints() async throws {
        let location = try temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let repository = try SubscriptionRepository(databaseURL: location.database)
        let identifier = try await repository.upsert(
            url: "https://example.com/sub",
            name: "Current",
            sourceType: .subscription,
            config: configuration(tag: "node")
        )
        let subscriptions = try await repository.subscriptions()
        let nodes = try await repository.nodes()
        #expect(subscriptions.map(\.identifier) == [identifier])
        #expect(subscriptions.first?.sourceType == .subscription)
        #expect(nodes.map(\.originalTag) == ["node"])

        let inspection = try SQLiteDatabase(url: location.database)
        let columns = try inspection.query("PRAGMA table_info(subscriptions)") {
            SQLiteDatabase.text($0, 1) ?? ""
        }
        #expect(columns == ["id", "identifier", "name", "subscription_url", "last_update_time", "source_type"])
        #expect(try count(in: inspection, table: "subscriptions") == 1)
        #expect(try count(in: inspection, table: "subscription_configs") == 1)

        try await repository.delete(identifier: identifier)
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
        #expect(storedTimestamp.map { $0 > 0 && $0 < 100_000_000_000 } == true)
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

    @Test("Editing never overwrites another source that owns the requested URL")
    func editingDoesNotOverwriteAnotherSource() async throws {
        let location = try temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let repository = try SubscriptionRepository(databaseURL: location.database)
        let first = try await repository.upsert(
            url: "https://one.example/sub",
            name: "One",
            sourceType: .subscription,
            config: configuration(tag: "one")
        )
        let second = try await repository.upsert(
            url: "https://two.example/sub",
            name: "Two",
            sourceType: .subscription,
            config: configuration(tag: "two")
        )

        do {
            _ = try await repository.upsert(
                url: "https://one.example/sub",
                name: "Changed",
                sourceType: .subscription,
                config: configuration(tag: "changed"),
                identifier: second
            )
            Issue.record("An edit overwrote another source")
        } catch {
            // Expected: the unique source URL constraint aborts the transaction.
        }

        let sources = try await repository.subscriptions()
        #expect(sources.count == 2)
        #expect(try await repository.subscription(identifier: first)?.name == "One")
        #expect(try await repository.subscription(identifier: second)?.name == "Two")
        #expect(Set(try await repository.nodes().map(\.originalTag)) == Set(["one", "two"]))
    }

    @Test("Delay history persists independently in SQLite")
    func delayHistoryPersistsInSQLite() async throws {
        let location = try temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let repository = try SubscriptionRepository(databaseURL: location.database)
        try await repository.replaceDelayHistory([
            "fast": DelayRecord(delay: 72, measuredAt: Date(timeIntervalSince1970: 1_800_000_000)),
            "timeout": DelayRecord(delay: nil, measuredAt: Date(timeIntervalSince1970: 1_800_001_000)),
        ])

        let reopened = try SubscriptionRepository(databaseURL: location.database)
        let history = try await reopened.delayHistory()
        #expect(history["fast"]?.delay == 72)
        #expect(history["timeout"]?.delay == nil)
        #expect(history["timeout"] != nil)
    }

    @Test("Delay merges keep newer measurements and prune removed nodes")
    func delayHistoryMergeIsTimestampOrdered() async throws {
        let location = try temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let repository = try SubscriptionRepository(databaseURL: location.database)
        try await repository.replaceDelayHistory([
            "current": DelayRecord(delay: 80, measuredAt: Date(timeIntervalSince1970: 1_800_000_000.900)),
            "removed": DelayRecord(delay: 50, measuredAt: Date(timeIntervalSince1970: 1_800_000_000)),
        ])

        let merged = try await repository.mergeDelayHistory([
            // Same-second completion is the real race between an explicit test
            // and an older automatic cycle, so sub-second ordering must survive
            // a database round trip.
            "current": DelayRecord(delay: 200, measuredAt: Date(timeIntervalSince1970: 1_800_000_000.100)),
            "new": DelayRecord(delay: 90, measuredAt: Date(timeIntervalSince1970: 1_800_001_000)),
        ], retaining: Set(["current", "new"]))

        #expect(merged["current"]?.delay == 80)
        #expect(merged["new"]?.delay == 90)
        #expect(merged["removed"] == nil)
        let persisted = try await repository.delayHistory()
        #expect(persisted["current"]?.delay == 80)
        #expect(persisted["new"]?.delay == 90)
        #expect(persisted["removed"] == nil)
        #expect(abs((persisted["current"]?.measuredAt.timeIntervalSince1970 ?? 0) - 1_800_000_000.900) < 0.001)
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

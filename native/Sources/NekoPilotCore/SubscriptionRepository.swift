import Foundation
import SQLite3

public actor SubscriptionRepository {
    private let database: SQLiteDatabase

    public init(databaseURL: URL) throws {
        database = try SQLiteDatabase(url: databaseURL)
        try Self.createSchema(database)
    }

    public func subscriptions() throws -> [Subscription] {
        try database.query(
            """
            SELECT id, identifier, COALESCE(name, ''), subscription_url,
                   last_update_time, source_type
            FROM subscriptions ORDER BY id DESC
            """
        ) { row in
            let source = SQLiteDatabase.text(row, 5) ?? "subscription"
            return Subscription(
                id: SQLiteDatabase.integer(row, 0),
                identifier: SQLiteDatabase.text(row, 1) ?? "",
                name: SQLiteDatabase.text(row, 2) ?? "",
                subscriptionURL: SQLiteDatabase.text(row, 3),
                lastUpdateTime: Date(timeIntervalSince1970: TimeInterval(SQLiteDatabase.integer(row, 4))),
                sourceType: Subscription.SourceType(rawValue: source) ?? .subscription
            )
        }
    }

    public func nodes() throws -> [ProxyNode] {
        let rows: [(String, String, Data)] = try database.query(
            """
            SELECT s.identifier, COALESCE(NULLIF(s.name, ''), s.identifier), c.config_content
            FROM subscriptions s
            JOIN subscription_configs c ON c.identifier = s.identifier
            ORDER BY s.id DESC
            """
        ) { row in
            let identifier = SQLiteDatabase.text(row, 0) ?? ""
            let name = SQLiteDatabase.text(row, 1) ?? identifier
            let config = Data((SQLiteDatabase.text(row, 2) ?? "{}").utf8)
            return (identifier, name, config)
        }
        return rows.flatMap { identifier, sourceName, data in
            (try? Self.nodes(in: data, identifier: identifier, sourceName: sourceName)) ?? []
        }
    }

    public func configObjects() throws -> [(identifier: String, config: [String: JSONValue])] {
        try database.query(
            """
            SELECT s.identifier, c.config_content
            FROM subscriptions s
            JOIN subscription_configs c ON c.identifier = s.identifier
            ORDER BY s.id DESC
            """
        ) { row in
            let identifier = SQLiteDatabase.text(row, 0) ?? ""
            let data = Data((SQLiteDatabase.text(row, 1) ?? "{}").utf8)
            return (identifier, try JSONValue.decodeObject(from: data))
        }
    }

    public func delayHistory() throws -> [String: DelayRecord] {
        let rows: [(String, Int?, Int64)] = try database.query(
            "SELECT runtime_tag, delay_ms, measured_at FROM node_delay_history ORDER BY measured_at DESC LIMIT 2000"
        ) { row in
            let delay = sqlite3_column_type(row, 1) == SQLITE_NULL
                ? nil
                : Int(SQLiteDatabase.integer(row, 1))
            return (
                SQLiteDatabase.text(row, 0) ?? "",
                delay,
                SQLiteDatabase.integer(row, 2)
            )
        }
        return Dictionary(uniqueKeysWithValues: rows.map { tag, delay, measuredAt in
            (tag, DelayRecord(delay: delay, measuredAt: Self.decodeMeasurementTime(measuredAt)))
        })
    }

    public func replaceDelayHistory(_ history: [String: DelayRecord]) throws {
        try database.transaction {
            try database.execute("DELETE FROM node_delay_history")
            for (tag, record) in history.prefix(2_000) {
                try database.execute(
                    "INSERT INTO node_delay_history(runtime_tag, delay_ms, measured_at) VALUES (?, ?, ?)",
                    bindings: [
                        .text(tag),
                        record.delay.map { .integer(Int64($0)) } ?? .null,
                        .integer(Self.encodeMeasurementTime(record.measuredAt)),
                    ]
                )
            }
        }
    }

    /// Merges concurrently produced URL Test results without allowing an older
    /// automatic cycle to overwrite a newer explicit test. Entries belonging
    /// to removed nodes are pruned in the same transaction snapshot.
    @discardableResult
    public func mergeDelayHistory(
        _ updates: [String: DelayRecord],
        retaining validTags: Set<String>
    ) throws -> [String: DelayRecord] {
        var merged = try delayHistory().filter { validTags.contains($0.key) }
        for (tag, update) in updates where validTags.contains(tag) {
            if let current = merged[tag], current.measuredAt > update.measuredAt { continue }
            merged[tag] = update
        }
        try replaceDelayHistory(merged)
        return merged
    }

    @discardableResult
    public func pruneDelayHistory(retaining validTags: Set<String>) throws -> [String: DelayRecord] {
        let retained = try delayHistory().filter { validTags.contains($0.key) }
        try replaceDelayHistory(retained)
        return retained
    }

    private static func encodeMeasurementTime(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func decodeMeasurementTime(_ storedValue: Int64) -> Date {
        // Values written before millisecond precision used Unix seconds.
        let seconds = storedValue >= 10_000_000_000
            ? TimeInterval(storedValue) / 1_000
            : TimeInterval(storedValue)
        return Date(timeIntervalSince1970: seconds)
    }

    public func upsert(
        url: String?,
        name: String,
        sourceType: Subscription.SourceType,
        config: [String: JSONValue],
        identifier requestedIdentifier: String? = nil
    ) throws -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.utf8.count <= 512 else {
            throw NekoPilotError.invalidSetting("name")
        }
        let identifier = try requestedIdentifier ?? existingIdentifier(for: url) ?? UUID().uuidString.lowercased()
        let now = Int64(Date().timeIntervalSince1970)
        let configData = try JSONValue.encodeObject(config)
        guard let configText = String(data: configData, encoding: .utf8) else {
            throw NekoPilotError.invalidSubscription
        }
        try database.transaction {
            try database.execute(
                """
                INSERT INTO subscriptions (
                    identifier, name, subscription_url, last_update_time, source_type
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(identifier) DO UPDATE SET
                    name = excluded.name,
                    subscription_url = excluded.subscription_url,
                    last_update_time = excluded.last_update_time,
                    source_type = excluded.source_type
                """,
                bindings: [
                    .text(identifier), .text(trimmedName), url.map(SQLiteDatabase.Binding.text) ?? .null,
                    .integer(now), .text(sourceType.rawValue),
                ]
            )
            try database.execute(
                """
                INSERT INTO subscription_configs(identifier, config_content)
                VALUES (?, ?)
                ON CONFLICT(identifier) DO UPDATE SET config_content = excluded.config_content
                """,
                bindings: [.text(identifier), .text(configText)]
            )
        }
        return identifier
    }

    public func delete(identifier: String) throws {
        try database.execute(
            "DELETE FROM subscriptions WHERE identifier = ?",
            bindings: [.text(identifier)]
        )
    }

    public func rename(identifier: String, name: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.utf8.count <= 512 else {
            throw NekoPilotError.invalidSetting("name")
        }
        try database.execute(
            "UPDATE subscriptions SET name = ? WHERE identifier = ?",
            bindings: [.text(trimmedName), .text(identifier)]
        )
    }

    public func subscription(identifier: String) throws -> Subscription? {
        try database.query(
            """
            SELECT id, identifier, COALESCE(name, ''), subscription_url,
                   last_update_time, source_type
            FROM subscriptions WHERE identifier = ? LIMIT 1
            """,
            bindings: [.text(identifier)]
        ) { row in
            Subscription(
                id: SQLiteDatabase.integer(row, 0),
                identifier: SQLiteDatabase.text(row, 1) ?? "",
                name: SQLiteDatabase.text(row, 2) ?? "",
                subscriptionURL: SQLiteDatabase.text(row, 3),
                lastUpdateTime: Date(timeIntervalSince1970: TimeInterval(SQLiteDatabase.integer(row, 4))),
                sourceType: Subscription.SourceType(rawValue: SQLiteDatabase.text(row, 5) ?? "") ?? .subscription
            )
        }.first
    }

    private func existingIdentifier(for url: String?) throws -> String? {
        guard let url else { return nil }
        return try database.query(
            "SELECT identifier FROM subscriptions WHERE subscription_url = ? LIMIT 1",
            bindings: [.text(url)]
        ) { SQLiteDatabase.text($0, 0) ?? "" }.first
    }

    private static func nodes(
        in data: Data,
        identifier: String,
        sourceName: String
    ) throws -> [ProxyNode] {
        let config = try JSONValue.decodeObject(from: data)
        let outbounds = config["outbounds"]?.arrayValue ?? []
        let ignored = Set(["selector", "urltest", "direct", "block", "dns"])
        var seen = Set<String>()
        return outbounds.compactMap { value in
            guard var outbound = value.objectValue,
                  let type = outbound["type"]?.stringValue,
                  !ignored.contains(type),
                  let original = outbound["tag"]?.stringValue,
                  !original.isEmpty,
                  seen.insert(original).inserted else { return nil }
            let runtime = "@np:\(identifier):\(original)"
            outbound["tag"] = .string(runtime)
            outbound["domain_resolver"] = .string("system")
            return ProxyNode(
                sourceIdentifier: identifier,
                sourceName: sourceName,
                originalTag: original,
                runtimeTag: runtime,
                protocolName: type,
                outbound: outbound
            )
        }
    }

    private static func createSchema(_ database: SQLiteDatabase) throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS subscriptions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                identifier TEXT NOT NULL UNIQUE,
                name TEXT NOT NULL,
                subscription_url TEXT UNIQUE,
                last_update_time INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                source_type TEXT NOT NULL CHECK(source_type IN ('subscription', 'local_link'))
            )
            """
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS subscription_configs (
                identifier TEXT PRIMARY KEY,
                config_content TEXT NOT NULL,
                FOREIGN KEY (identifier) REFERENCES subscriptions(identifier) ON DELETE CASCADE
            )
            """
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS node_delay_history (
                runtime_tag TEXT PRIMARY KEY,
                delay_ms INTEGER,
                measured_at INTEGER NOT NULL
            )
            """
        )
    }
}

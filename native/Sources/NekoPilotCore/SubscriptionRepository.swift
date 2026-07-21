import Foundation

public actor SubscriptionRepository {
    // Epoch seconds stay below this value until year 5138, while normal modern
    // millisecond timestamps are already above it. The upper bound is year
    // 3000 in milliseconds, preventing arbitrary corrupt integers from being
    // silently reinterpreted as valid dates.
    static let millisecondEpochThreshold: Int64 = 100_000_000_000
    static let maximumReasonableMillisecondEpoch: Int64 = 32_503_680_000_000
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
                lastUpdateTime: Date(
                    timeIntervalSince1970: Self.normalizedEpochSeconds(SQLiteDatabase.integer(row, 4))
                ),
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

    public func upsert(
        url: String?,
        name: String,
        sourceType: Subscription.SourceType,
        config: [String: JSONValue],
        identifier requestedIdentifier: String? = nil
    ) throws -> String {
        let identifier = try existingIdentifier(for: url) ?? requestedIdentifier ?? UUID().uuidString.lowercased()
        // Keep timestamps in milliseconds for compatibility with existing
        // NekoPilot installations that already use this database contract.
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let configData = try JSONValue.encodeObject(config)
        guard let configText = String(data: configData, encoding: .utf8) else {
            throw NekoPilotError.invalidSubscription
        }
        try database.transaction {
            try database.execute(
                """
                INSERT INTO subscriptions (
                    identifier, name, used_traffic, total_traffic, subscription_url,
                    official_website, expire_time, last_update_time, source_type
                ) VALUES (?, ?, 0, 0, ?, NULL, 0, ?, ?)
                ON CONFLICT(identifier) DO UPDATE SET
                    name = excluded.name,
                    subscription_url = excluded.subscription_url,
                    last_update_time = excluded.last_update_time,
                    source_type = excluded.source_type
                """,
                bindings: [
                    .text(identifier), .text(name), url.map(SQLiteDatabase.Binding.text) ?? .null,
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

    public func rename(identifier: String, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 512 else { throw NekoPilotError.invalidSetting("name") }
        try database.execute(
            "UPDATE subscriptions SET name = ? WHERE identifier = ?",
            bindings: [.text(trimmed), .text(identifier)]
        )
    }

    public func delete(identifier: String) throws {
        // Legacy databases may have been created without an enforceable
        // foreign-key constraint. Delete both rows explicitly so those users
        // do not accumulate hidden configuration records.
        try database.transaction {
            try database.execute(
                "DELETE FROM subscription_configs WHERE identifier = ?",
                bindings: [.text(identifier)]
            )
            try database.execute(
                "DELETE FROM subscriptions WHERE identifier = ?",
                bindings: [.text(identifier)]
            )
        }
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
                lastUpdateTime: Date(
                    timeIntervalSince1970: Self.normalizedEpochSeconds(SQLiteDatabase.integer(row, 4))
                ),
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

    static func normalizedEpochSeconds(_ rawValue: Int64) -> TimeInterval {
        let seconds: Int64
        if (millisecondEpochThreshold ... maximumReasonableMillisecondEpoch).contains(rawValue) {
            seconds = rawValue / 1_000
        } else {
            seconds = rawValue
        }
        return TimeInterval(seconds)
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
                name TEXT,
                used_traffic INTEGER DEFAULT 0,
                total_traffic INTEGER DEFAULT 0,
                subscription_url TEXT,
                official_website TEXT,
                expire_time INTEGER DEFAULT 0,
                last_update_time INTEGER DEFAULT (strftime('%s', 'now') * 1000),
                source_type TEXT NOT NULL DEFAULT 'subscription'
            )
            """
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS subscription_configs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                identifier TEXT NOT NULL,
                config_content TEXT,
                FOREIGN KEY (identifier) REFERENCES subscriptions(identifier) ON DELETE CASCADE
            )
            """
        )
        // OneBox databases created before the transactional repository could
        // contain repeated subscription URLs, repeated config rows, or orphaned
        // config rows. Normalize those rows before adding the invariants used by
        // the native upsert path. The whole migration is atomic so an interrupted
        // first launch never leaves a partially-migrated database behind.
        try database.transaction {
            let columns = try database.query("PRAGMA table_info(subscriptions)") {
                SQLiteDatabase.text($0, 1) ?? ""
            }
            if !columns.contains("source_type") {
                try database.execute(
                    "ALTER TABLE subscriptions ADD COLUMN source_type TEXT NOT NULL DEFAULT 'subscription'"
                )
            }
            try database.execute(
                "DELETE FROM subscriptions WHERE subscription_url IS NOT NULL AND id NOT IN (SELECT MAX(id) FROM subscriptions WHERE subscription_url IS NOT NULL GROUP BY subscription_url)"
            )
            try database.execute(
                "DELETE FROM subscription_configs WHERE identifier NOT IN (SELECT identifier FROM subscriptions)"
            )
            try database.execute(
                "DELETE FROM subscription_configs WHERE id NOT IN (SELECT MAX(id) FROM subscription_configs GROUP BY identifier)"
            )
            try database.execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS subscriptions_url_unique ON subscriptions(subscription_url) WHERE subscription_url IS NOT NULL"
            )
            try database.execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS subscription_configs_identifier_unique ON subscription_configs(identifier)"
            )
        }
    }
}

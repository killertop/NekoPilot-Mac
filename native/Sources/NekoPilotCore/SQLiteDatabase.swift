import Foundation
import SQLite3

final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &connection, flags, nil) == SQLITE_OK else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
            if let connection { sqlite3_close(connection) }
            throw NekoPilotError.processFailed(CoreL10n.text(
                "无法打开节点数据库：\(message)",
                "Could not open the node database: \(message)"
            ))
        }
        handle = connection
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        sqlite3_busy_timeout(connection, 5_000)
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func execute(_ sql: String, bindings: [Binding] = []) throws {
        try withStatement(sql, bindings: bindings) { statement in
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW: continue
                case SQLITE_DONE: return
                default: throw databaseError()
                }
            }
        }
    }

    func query<T>(_ sql: String, bindings: [Binding] = [], row: (OpaquePointer) throws -> T) throws -> [T] {
        try withStatement(sql, bindings: bindings) { statement in
            var output: [T] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    output.append(try row(statement))
                case SQLITE_DONE:
                    return output
                default:
                    throw databaseError()
                }
            }
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try executeUnlocked("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try executeUnlocked("COMMIT")
            return result
        } catch {
            try? executeUnlocked("ROLLBACK")
            throw error
        }
    }

    private func withStatement<T>(
        _ sql: String,
        bindings: [Binding],
        body: (OpaquePointer) throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try withStatementUnlocked(sql, bindings: bindings, body: body)
    }

    private func withStatementUnlocked<T>(
        _ sql: String,
        bindings: [Binding],
        body: (OpaquePointer) throws -> T
    ) throws -> T {
        guard let handle else {
            throw NekoPilotError.processFailed(CoreL10n.text("节点数据库已关闭", "The node database is closed"))
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }
        for (index, binding) in bindings.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch binding {
            case .null:
                result = sqlite3_bind_null(statement, position)
            case let .integer(value):
                result = sqlite3_bind_int64(statement, position, value)
            case let .text(value):
                result = sqlite3_bind_text(statement, position, value, -1, Self.transient)
            case let .data(value):
                result = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, position, bytes.baseAddress, Int32(bytes.count), Self.transient)
                }
            }
            guard result == SQLITE_OK else { throw databaseError() }
        }
        return try body(statement)
    }

    private func executeUnlocked(_ sql: String) throws {
        try withStatementUnlocked(sql, bindings: []) { statement in
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW: continue
                case SQLITE_DONE: return
                default: throw databaseError()
                }
            }
        }
    }

    private func databaseError() -> Error {
        guard let handle else {
            return NekoPilotError.processFailed(CoreL10n.text("节点数据库已关闭", "The node database is closed"))
        }
        let detail = String(cString: sqlite3_errmsg(handle))
        return NekoPilotError.processFailed(CoreL10n.text(
            "节点数据库操作失败：\(detail)",
            "The node database operation failed: \(detail)"
        ))
    }

    enum Binding: Sendable {
        case null
        case integer(Int64)
        case text(String)
        case data(Data)
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    static func integer(_ statement: OpaquePointer, _ column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }
}

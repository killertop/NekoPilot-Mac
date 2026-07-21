import Foundation

public struct AppPaths: Sendable {
    public static let bundleIdentifier = "dev.nekopilot.desktop"

    public let applicationSupport: URL
    public let logs: URL

    public init(applicationSupport: URL, logs: URL) {
        self.applicationSupport = applicationSupport
        self.logs = logs
    }

    public static func live(fileManager: FileManager = .default) throws -> AppPaths {
        let supportRoot = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let logRoot = try fileManager.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Logs", isDirectory: true)
        let support = supportRoot.appendingPathComponent(bundleIdentifier, isDirectory: true)
        let logs = logRoot.appendingPathComponent(bundleIdentifier, isDirectory: true)
        try secureDirectory(support, fileManager: fileManager)
        try secureDirectory(logs, fileManager: fileManager)
        return AppPaths(applicationSupport: support, logs: logs)
    }

    public var database: URL { applicationSupport.appendingPathComponent("data.db") }
    public var settings: URL { applicationSupport.appendingPathComponent("settings.json") }
    public var runtimeConfig: URL { applicationSupport.appendingPathComponent("config.json") }
    public var cacheDatabase: URL { applicationSupport.appendingPathComponent("mixed-cache-rule-v2.db") }
    public var proxyOwnership: URL { applicationSupport.appendingPathComponent("system-proxy-owner.json") }
    public var engineOwnership: URL { applicationSupport.appendingPathComponent("sing-box-owner.json") }
    public var ruleSets: URL { applicationSupport.appendingPathComponent("rule-sets", isDirectory: true) }
    public var logFile: URL { logs.appendingPathComponent("NekoPilot.log") }

    private static func secureDirectory(_ url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

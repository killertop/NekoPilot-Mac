import Foundation
import Darwin

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

    public var database: URL { applicationSupport.appendingPathComponent("nekopilot.sqlite3") }
    public var settings: URL { applicationSupport.appendingPathComponent("preferences.json") }
    public var runtimeConfig: URL { applicationSupport.appendingPathComponent("runtime.json") }
    public var cacheDatabase: URL { applicationSupport.appendingPathComponent("sing-box-cache.sqlite3") }
    public var proxyOwnership: URL { applicationSupport.appendingPathComponent("system-proxy-owner.json") }
    public var engineOwnership: URL { applicationSupport.appendingPathComponent("sing-box-owner.json") }
    // Darwin limits Unix-domain socket paths to 104 bytes. Application Support
    // and especially test paths can exceed it, so keep the private control
    // socket short while the Go core enforces mode 0600 on creation.
    public var nativeAPISocket: URL { URL(fileURLWithPath: "/tmp/nekopilot-\(getuid()).sock") }
    public var ruleSets: URL { applicationSupport.appendingPathComponent("rule-sets", isDirectory: true) }
    public var logFile: URL { logs.appendingPathComponent("NekoPilot.log") }

    private static func secureDirectory(_ url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

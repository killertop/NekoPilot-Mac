import Darwin
import CryptoKit
import Foundation

public enum RuleSetRefreshResult: Sendable, Equatable {
    case updated
    case notDue(delay: TimeInterval)
    case failed(retryDelay: TimeInterval)

    public var didUpdate: Bool {
        if case .updated = self { return true }
        return false
    }

    public var nextCheckDelay: TimeInterval {
        switch self {
        case .updated: return RuleSetUpdater.refreshInterval
        case let .notDue(delay): return max(1, delay)
        case let .failed(retryDelay): return retryDelay
        }
    }
}

public actor RuleSetUpdater {
    public static let refreshInterval: TimeInterval = 7 * 24 * 60 * 60
    public static let retryInterval: TimeInterval = 60 * 60
    private static let maximumBytes = 64 * 1024 * 1024
    private let paths: AppPaths
    private var isRefreshing = false

    public init(paths: AppPaths) {
        self.paths = paths
    }

    /// Refreshes both managed rule sets together, or tells the caller exactly
    /// when the next due/retry check should happen.
    public func refreshIfDue(now: Date = Date()) async -> RuleSetRefreshResult {
        guard !isRefreshing else { return .notDue(delay: Self.retryInterval) }
        let dueDelay = delayUntilRefresh(now: now)
        guard dueDelay <= 0 else { return .notDue(delay: dueDelay) }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let sources = Self.sources
            var downloads: [(String, Data)] = []
            downloads.reserveCapacity(sources.count)
            for source in sources {
                let data = try await download(source)
                guard Self.isValidRuleSet(data) else {
                    throw NekoPilotError.processFailed("下载的中国规则库无效")
                }
                let candidate = paths.ruleSets.appendingPathComponent(".\(source.fileName).\(UUID().uuidString).candidate")
                defer { try? FileManager.default.removeItem(at: candidate) }
                try AtomicFile.write(data, to: candidate)
                try await SingBoxValidator.validate(ruleSet: candidate, tag: source.tag)
                downloads.append((source.fileName, data))
            }
            try Self.installGeneration(in: paths.ruleSets, files: downloads, label: "remote")
            try AtomicFile.write(Data(String(now.timeIntervalSince1970).utf8), to: timestampURL)
            AppLogger.shared.info("refreshed managed SagerNet China rule sets")
            return .updated
        } catch {
            AppLogger.shared.info("managed rule-set refresh deferred: \(error.localizedDescription)")
            return .failed(retryDelay: Self.retryInterval)
        }
    }

    public static func isValidRuleSet(_ data: Data) -> Bool {
        data.count >= 32 && data.starts(with: Data("SRS".utf8))
    }

    public static func activeRuleSetURL(in root: URL, name: String) -> URL {
        root.appendingPathComponent("active", isDirectory: true).appendingPathComponent("\(name).srs")
    }

    /// Seeds the first complete generation from bundled assets. Once an active
    /// generation exists, it is preserved until a fully validated replacement
    /// has been promoted through the active symlink.
    public static func installBundledBaseline(
        in root: URL,
        files: [(String, Data)]
    ) throws {
        let active = root.appendingPathComponent("active", isDirectory: true)
        if files.allSatisfy({ name, _ in
            guard let existing = try? Data(contentsOf: active.appendingPathComponent("\(name).srs")) else { return false }
            return isValidRuleSet(existing)
        }) {
            return
        }
        try installGeneration(in: root, files: files, label: "bundled")
    }

    private static func installGeneration(
        in root: URL,
        files: [(String, Data)],
        label: String
    ) throws {
        let fileManager = FileManager.default
        let generations = root.appendingPathComponent("generations", isDirectory: true)
        try fileManager.createDirectory(at: generations, withIntermediateDirectories: true)
        let identifier = "\(label)-\(UUID().uuidString.lowercased())"
        let candidate = generations.appendingPathComponent(".\(identifier).candidate", isDirectory: true)
        let destination = generations.appendingPathComponent(identifier, isDirectory: true)
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
        do {
            for (name, data) in files {
                guard isValidRuleSet(data) else { throw NekoPilotError.processFailed("规则库候选无效") }
                try AtomicFile.write(data, to: candidate.appendingPathComponent("\(name).srs"))
            }
            try fileManager.moveItem(at: candidate, to: destination)
            try activateGeneration(destination, in: root)
        } catch {
            try? fileManager.removeItem(at: candidate)
            throw error
        }
    }

    private static func activateGeneration(_ generation: URL, in root: URL) throws {
        let fileManager = FileManager.default
        let active = root.appendingPathComponent("active", isDirectory: true)
        let pending = root.appendingPathComponent(".active-\(UUID().uuidString).pending")
        try fileManager.createSymbolicLink(at: pending, withDestinationURL: generation)
        guard rename(pending.path, active.path) == 0 else {
            let message = String(cString: strerror(errno))
            try? fileManager.removeItem(at: pending)
            throw NekoPilotError.processFailed("无法切换规则库版本：\(message)")
        }
    }

    private func delayUntilRefresh(now: Date) -> TimeInterval {
        guard let raw = try? String(contentsOf: timestampURL, encoding: .utf8),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 0
        }
        let last = Date(timeIntervalSince1970: seconds)
        if last > now { return 0 }
        return max(0, Self.refreshInterval - now.timeIntervalSince(last))
    }

    private func download(_ source: Source) async throws -> Data {
        let commit = try await resolveBranchCommit(for: source)
        let expectedBlob = try await resolveBlobSHA(for: source, commit: commit)
        let rawURL = try Self.url("https://raw.githubusercontent.com/\(source.repository)/\(commit)/\(source.fileName)")
        let data = try await fetch(rawURL, maximumBytes: Self.maximumBytes)
        guard Self.gitBlobSHA1(data) == expectedBlob else {
            throw NekoPilotError.processFailed("规则库内容校验失败")
        }
        return data
    }

    private func resolveBranchCommit(for source: Source) async throws -> String {
        let url = try Self.url("https://api.github.com/repos/\(source.repository)/git/ref/heads/rule-set")
        let data = try await fetch(url, maximumBytes: 64 * 1024)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reference = object["object"] as? [String: Any],
              let commit = reference["sha"] as? String,
              Self.isGitSHA(commit) else {
            throw NekoPilotError.processFailed("规则库版本信息无效")
        }
        return commit
    }

    private func resolveBlobSHA(for source: Source, commit: String) async throws -> String {
        let url = try Self.url("https://api.github.com/repos/\(source.repository)/contents/\(source.fileName)?ref=\(commit)")
        let data = try await fetch(url, maximumBytes: 64 * 1024)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blob = object["sha"] as? String,
              Self.isGitSHA(blob) else {
            throw NekoPilotError.processFailed("规则库内容摘要无效")
        }
        return blob
    }

    private func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        let allowedHosts: Set<String> = ["api.github.com", "raw.githubusercontent.com"]
        let delegate = RuleSetRedirectDelegate(allowedHosts: allowedHosts)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("NekoPilot/1.2 rule-set updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              (200 ... 299).contains(http.statusCode),
              let finalURL = http.url,
              finalURL.scheme?.lowercased() == "https",
              allowedHosts.contains(finalURL.host?.lowercased() ?? "") else {
            throw NekoPilotError.processFailed("规则库下载失败")
        }
        if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           length > maximumBytes {
            throw NekoPilotError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(
            http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init) ?? 0,
            maximumBytes
        ))
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw NekoPilotError.responseTooLarge }
            data.append(byte)
        }
        return data
    }

    private var timestampURL: URL {
        paths.ruleSets.appendingPathComponent("cn-rule-sets-updated-at")
    }

    private struct Source {
        let tag: String
        let fileName: String
        let repository: String
    }

    private static let sources = [
        Source(
            tag: "geoip-cn",
            fileName: "geoip-cn.srs",
            repository: "SagerNet/sing-geoip"
        ),
        Source(
            tag: "geosite-cn",
            fileName: "geosite-cn.srs",
            repository: "SagerNet/sing-geosite"
        ),
    ]

    private static func url(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.scheme == "https" else {
            throw NekoPilotError.processFailed("规则库地址无效")
        }
        return url
    }

    private static func isGitSHA(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    private static func gitBlobSHA1(_ data: Data) -> String {
        var payload = Data("blob \(data.count)\u{0}".utf8)
        payload.append(data)
        return Insecure.SHA1.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }
}

private final class RuleSetRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowedHosts: Set<String>

    init(allowedHosts: Set<String>) {
        self.allowedHosts = allowedHosts
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              allowedHosts.contains(url.host?.lowercased() ?? "") else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

import Foundation

public actor RuleSetUpdater {
    public static let refreshInterval: TimeInterval = 7 * 24 * 60 * 60
    private static let maximumBytes = 64 * 1024 * 1024
    private let paths: AppPaths
    private var isRefreshing = false

    public init(paths: AppPaths) {
        self.paths = paths
    }

    /// Returns true only when both managed rule sets were atomically replaced.
    public func refreshIfDue(now: Date = Date()) async -> Bool {
        guard !isRefreshing, refreshIsDue(now: now) else { return false }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let sources = Self.sources
            var downloads: [(URL, Data)] = []
            downloads.reserveCapacity(sources.count)
            for source in sources {
                let data = try await download(source.remoteURL)
                guard Self.isValidRuleSet(data) else {
                    throw NekoPilotError.processFailed("下载的中国规则库无效")
                }
                let destination = paths.ruleSets.appendingPathComponent(source.fileName)
                let candidate = paths.ruleSets.appendingPathComponent(".\(source.fileName).\(UUID().uuidString).candidate")
                defer { try? FileManager.default.removeItem(at: candidate) }
                try AtomicFile.write(data, to: candidate)
                try await SingBoxValidator.validate(ruleSet: candidate, tag: source.tag)
                downloads.append((destination, data))
            }
            for (destination, data) in downloads {
                try AtomicFile.write(data, to: destination)
            }
            try AtomicFile.write(Data(String(now.timeIntervalSince1970).utf8), to: timestampURL)
            AppLogger.shared.info("refreshed managed SagerNet China rule sets")
            return true
        } catch {
            AppLogger.shared.info("managed rule-set refresh deferred: \(error.localizedDescription)")
            return false
        }
    }

    public static func isValidRuleSet(_ data: Data) -> Bool {
        data.count >= 32 && data.starts(with: Data("SRS".utf8))
    }

    private func refreshIsDue(now: Date) -> Bool {
        guard let raw = try? String(contentsOf: timestampURL, encoding: .utf8),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return true
        }
        let last = Date(timeIntervalSince1970: seconds)
        return last > now || now.timeIntervalSince(last) >= Self.refreshInterval
    }

    private func download(_ url: URL) async throws -> Data {
        let allowedHosts = Set(Self.sources.compactMap { $0.remoteURL.host?.lowercased() })
        let delegate = RuleSetRedirectDelegate(allowedHosts: allowedHosts)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("NekoPilot rule-set updater", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              (200 ... 299).contains(http.statusCode),
              let finalURL = http.url,
              finalURL.scheme?.lowercased() == "https",
              allowedHosts.contains(finalURL.host?.lowercased() ?? "") else {
            throw NekoPilotError.processFailed("规则库下载失败")
        }
        if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           length > Self.maximumBytes {
            throw NekoPilotError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(
            http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init) ?? 0,
            Self.maximumBytes
        ))
        for try await byte in bytes {
            guard data.count < Self.maximumBytes else { throw NekoPilotError.responseTooLarge }
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
        let remoteURL: URL
    }

    private static let sources = [
        Source(
            tag: "geoip-cn",
            fileName: "geoip-cn.srs",
            remoteURL: URL(string: "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs")!
        ),
        Source(
            tag: "geosite-cn",
            fileName: "geosite-cn.srs",
            remoteURL: URL(string: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs")!
        ),
    ]
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

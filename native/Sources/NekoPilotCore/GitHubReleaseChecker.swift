import Foundation

public struct GitHubReleaseUpdate: Identifiable, Equatable, Sendable {
    public let version: String
    public let url: URL

    public var id: String { version }

    public init(version: String, url: URL) {
        self.version = version
        self.url = url
    }
}

public actor GitHubReleaseChecker {
    public static let interval: TimeInterval = 24 * 60 * 60
    public static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/killertop/NekoPilot-Mac/releases/latest"
    )!

    private let settings: SettingsStore
    private let session: URLSession

    public init(settings: SettingsStore, session: URLSession? = nil) {
        self.settings = settings
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 15
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    public func checkIfDue(currentVersion: String, now: Date = Date()) async -> GitHubReleaseUpdate? {
        let stored = await settings.value(SettingsStore.Key.lastUpdateCheck)?.numberValue
        guard Self.isCheckDue(lastCheck: stored, now: now) else { return nil }

        // Record attempts before networking so an offline launch cannot retry
        // continuously while the user is working.
        do {
            try await settings.set(.number(now.timeIntervalSince1970), for: SettingsStore.Key.lastUpdateCheck)
        } catch {
            AppLogger.shared.warning("update-check timestamp could not be saved: \(error.localizedDescription)")
            return nil
        }

        do {
            var request = URLRequest(url: Self.latestReleaseURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("NekoPilot for macOS", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard data.count <= 256 * 1024,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  Self.isCanonicalAPIURL(http.url) else { return nil }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard !release.draft, !release.prerelease,
                  Self.isVersionNewer(release.tagName, than: currentVersion),
                  let url = Self.safeReleaseURL(release.htmlURL) else { return nil }
            return GitHubReleaseUpdate(version: release.tagName, url: url)
        } catch is CancellationError {
            return nil
        } catch {
            AppLogger.shared.info("GitHub update check skipped: \(error.localizedDescription)")
            return nil
        }
    }

    public static func isCheckDue(lastCheck: Double?, now: Date) -> Bool {
        guard let lastCheck, lastCheck.isFinite else { return true }
        let elapsed = now.timeIntervalSince1970 - lastCheck
        return elapsed < 0 || elapsed >= interval
    }

    public static func isVersionNewer(_ published: String, than current: String) -> Bool {
        guard let remote = semanticVersion(published),
              let local = semanticVersion(current) else { return false }
        return remote.lexicographicallyPrecedes(local) == false && remote != local
    }

    public static func safeReleaseURL(_ rawValue: String) -> URL? {
        guard let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.lowercased().hasPrefix("/killertop/nekopilot-mac/releases/") else { return nil }
        return components.url
    }

    private static func semanticVersion(_ value: String) -> [Int]? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingPrefix("v")
            .split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        let fields = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 3).contains(fields.count), fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        let components = fields.compactMap { Int($0) }
        guard components.count == fields.count else { return nil }
        return components + Array(repeating: 0, count: 3 - fields.count)
    }

    private static func isCanonicalAPIURL(_ url: URL?) -> Bool {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https" &&
            components.host?.lowercased() == "api.github.com" &&
            components.user == nil && components.password == nil && components.port == nil &&
            components.query == nil && components.fragment == nil &&
            components.path.lowercased() == "/repos/killertop/nekopilot-mac/releases/latest"
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
        }
    }
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}

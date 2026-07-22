import Foundation

enum ProxyHealthProbeResult: Equatable, Sendable {
    case reachable(delay: Int)
    case unreachable
    case indeterminate
}

enum ProxyHealthEndpoint {
    static let inboundTag = "nekopilot-health"
    static let host = "connectivitycheck.gstatic.com"
    static let url = URL(string: "https://\(host)/generate_204")!
}

/// Performs a small end-to-end request through a dedicated loopback-only
/// health inbound. Unlike a URL Test worker, this exercises the live core and
/// its current ExitGateway without changing selector state, user routes, or
/// delay history.
actor ProxyHealthProbe {
    private static let timeout: TimeInterval = 8

    func check(port: Int?) async -> ProxyHealthProbeResult {
        guard !Task.isCancelled else { return .indeterminate }
        guard let port, (1 ... 65_535).contains(port) else { return .indeterminate }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.connectionProxyDictionary = [
            "HTTPEnable": true,
            "HTTPProxy": "127.0.0.1",
            "HTTPPort": port,
            "HTTPSEnable": true,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": port,
        ]

        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: ProxyHealthEndpoint.url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = Self.timeout
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let startedAt = Date()
        do {
            let (_, response) = try await session.data(for: request)
            guard !Task.isCancelled else { return .indeterminate }
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 204 else { return .unreachable }
            let milliseconds = max(1, Int(Date().timeIntervalSince(startedAt) * 1_000))
            return .reachable(delay: milliseconds)
        } catch {
            return Task.isCancelled ? .indeterminate : .unreachable
        }
    }
}

import Foundation

enum ProxyHealthProbeResult: Equatable, Sendable {
    case reachable(delay: Int)
    case unreachable
    case indeterminate
}

struct ProxyHealthTarget: Equatable, Sendable {
    let url: URL
    let acceptableStatusCodes: Set<Int>

    var host: String { url.host ?? "" }
}

enum ProxyHealthEndpoint {
    static let inboundTag = "nekopilot-health"
    static let targets: [ProxyHealthTarget] = [
        ProxyHealthTarget(
            url: URL(string: "https://connectivitycheck.gstatic.com/generate_204")!,
            acceptableStatusCodes: [204]
        ),
        ProxyHealthTarget(
            url: URL(string: "https://cp.cloudflare.com/generate_204")!,
            acceptableStatusCodes: [204]
        ),
        ProxyHealthTarget(
            url: URL(string: "https://www.apple.com/library/test/success.html")!,
            acceptableStatusCodes: [200]
        ),
    ]
    static let quorum = 2
    static let host = targets[0].host
    static let url = targets[0].url
}

/// Performs a small end-to-end request through a dedicated loopback-only
/// health inbound. Unlike a URL Test worker, this exercises the live core and
/// its current ExitGateway without changing selector state, user routes, or
/// delay history.
actor ProxyHealthProbe {
    private static let timeout: TimeInterval = 8
    private let targets: [ProxyHealthTarget]
    private let requiredReachableTargets: Int
    private let requestTarget: @Sendable (ProxyHealthTarget, Int) async -> ProxyHealthProbeResult

    init(
        targets: [ProxyHealthTarget] = ProxyHealthEndpoint.targets,
        requiredReachableTargets: Int = ProxyHealthEndpoint.quorum,
        request: (@Sendable (ProxyHealthTarget, Int) async -> ProxyHealthProbeResult)? = nil
    ) {
        self.targets = targets
        self.requiredReachableTargets = max(1, min(requiredReachableTargets, targets.count))
        self.requestTarget = request ?? { target, port in
            await Self.request(target: target, port: port)
        }
    }

    func check(port: Int?) async -> ProxyHealthProbeResult {
        guard !Task.isCancelled else { return .indeterminate }
        guard let port, (1 ... 65_535).contains(port) else { return .indeterminate }
        guard !targets.isEmpty else { return .indeterminate }
        let targets = self.targets
        let requestTarget = self.requestTarget
        let requiredReachableTargets = self.requiredReachableTargets
        return await withTaskGroup(
            of: ProxyHealthProbeResult.self,
            returning: ProxyHealthProbeResult.self
        ) { group in
            for target in targets {
                group.addTask {
                    await requestTarget(target, port)
                }
            }
            var results: [ProxyHealthProbeResult] = []
            var reachableCount = 0
            var remainingCount = targets.count
            for await result in group {
                results.append(result)
                remainingCount -= 1
                if case .reachable = result {
                    reachableCount += 1
                }
                if reachableCount >= requiredReachableTargets
                    || reachableCount + remainingCount < requiredReachableTargets {
                    group.cancelAll()
                    return Self.aggregate(
                        results: results,
                        requiredReachableTargets: requiredReachableTargets
                    )
                }
            }
            return Self.aggregate(
                results: results,
                requiredReachableTargets: requiredReachableTargets
            )
        }
    }

    static func aggregate(
        results: [ProxyHealthProbeResult],
        requiredReachableTargets: Int
    ) -> ProxyHealthProbeResult {
        let reachable = results.compactMap { result -> Int? in
            guard case let .reachable(delay) = result else { return nil }
            return delay
        }
        guard reachable.count >= max(1, requiredReachableTargets) else {
            return results.contains(.indeterminate) ? .indeterminate : .unreachable
        }
        let sorted = reachable.sorted()
        return .reachable(delay: sorted[sorted.count / 2])
    }

    private static func request(target: ProxyHealthTarget, port: Int) async -> ProxyHealthProbeResult {
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
        var request = URLRequest(url: target.url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = Self.timeout
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("NekoPilot/health", forHTTPHeaderField: "User-Agent")
        let startedAt = Date()
        do {
            let (_, response) = try await session.data(for: request)
            guard !Task.isCancelled else { return .indeterminate }
            guard let response = response as? HTTPURLResponse,
                  target.acceptableStatusCodes.contains(response.statusCode) else { return .unreachable }
            let milliseconds = max(1, Int(Date().timeIntervalSince(startedAt) * 1_000))
            return .reachable(delay: milliseconds)
        } catch {
            return Task.isCancelled ? .indeterminate : .unreachable
        }
    }
}

import Darwin
import Foundation

public typealias NodeLocationProgressHandler = @Sendable (String, NodeLocationRecord) async -> Void

enum NodeLocationProbeEndpoint {
    static let inboundTag = "nekopilot-location"
    static let primary = URL(string: "https://speed.cloudflare.com/cdn-cgi/trace")!
    static let fallback = URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!
}

/// Discovers the country of each node's real proxy egress without touching the
/// live selector. Disposable sing-box workers are bounded to two processes;
/// each worker changes its private selector and probes nodes sequentially.
public actor NodeLocationProbe {
    static let maximumResponseBytes = 8 * 1_024
    private static let nodesPerWorker = 12
    private static let endpointTimeout: TimeInterval = 3.5
    private static let validCountryCodes = Set(Locale.Region.isoRegions.map(\.identifier))
    private static let excludedCountryCodes = Set(["XX", "T1", "A1", "A2"])
    private let compiler: ConfigurationCompiler
    private var didRecoverAbandonedWorkers = false

    public init(compiler: ConfigurationCompiler) {
        self.compiler = compiler
    }

    public func probe(
        nodes: [ProxyNode],
        onResult: NodeLocationProgressHandler? = nil
    ) async -> [String: NodeLocationRecord] {
        if !didRecoverAbandonedWorkers {
            didRecoverAbandonedWorkers = true
            await Self.recoverAbandonedWorkers(in: FileManager.default.temporaryDirectory)
        }
        var seen = Set<String>()
        let uniqueNodes = nodes.filter { seen.insert($0.runtimeTag).inserted }
        guard !uniqueNodes.isEmpty, !Task.isCancelled else { return [:] }
        guard let executable = try? SingBoxLocator.executable() else {
            return await Self.unavailable(uniqueNodes, onResult: onResult)
        }

        let count = Self.workerCount(for: uniqueNodes.count)
        let groups = Self.workerGroups(uniqueNodes, count: count)
        guard let endpoints = try? Self.makeWorkerEndpoints(count: groups.count),
              let configurations = try? await compiler.makeLocationProbeConfigurations(
                  selectedNodeGroups: groups.map { $0.map(\.runtimeTag) },
                  apiEndpoints: endpoints.map(\.api),
                  proxyPorts: endpoints.map(\.proxyPort)
              ),
              configurations.count == groups.count else {
            return await Self.unavailable(uniqueNodes, onResult: onResult)
        }

        let jobs = groups.indices.map { index in
            LocationProbeJob(
                nodes: groups[index],
                apiEndpoint: endpoints[index].api,
                proxyPort: endpoints[index].proxyPort,
                config: configurations[index],
                executable: executable
            )
        }
        var merged: [String: NodeLocationRecord] = [:]
        await withTaskGroup(of: [String: NodeLocationRecord].self) { group in
            for job in jobs {
                group.addTask {
                    await Self.run(job: job, onResult: onResult)
                }
            }
            for await result in group {
                merged.merge(result, uniquingKeysWith: { _, newer in newer })
            }
        }
        return merged
    }

    static func workerCount(for nodeCount: Int) -> Int {
        guard nodeCount > 0 else { return 0 }
        return nodeCount <= nodesPerWorker ? 1 : 2
    }

    static func parseCountryCode(from data: Data) -> String? {
        guard data.count <= maximumResponseBytes,
              let text = String(data: data, encoding: .utf8) else { return nil }
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let parts = rawLine.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "loc" else { continue }
            let code = parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard code.utf8.count == 2,
                  code.utf8.allSatisfy({ (65 ... 90).contains($0) }),
                  !excludedCountryCodes.contains(code),
                  validCountryCodes.contains(code) else { return nil }
            return code
        }
        return nil
    }

    private static func workerGroups(_ nodes: [ProxyNode], count: Int) -> [[ProxyNode]] {
        guard count > 0 else { return [] }
        var groups = Array(repeating: [ProxyNode](), count: count)
        for (index, node) in nodes.enumerated() {
            groups[index % count].append(node)
        }
        return groups.filter { !$0.isEmpty }
    }

    private static func makeWorkerEndpoints(count: Int) throws -> [LocationWorkerEndpoint] {
        var endpoints: [LocationWorkerEndpoint] = []
        var usedPorts = Set<Int>()
        for _ in 0 ..< count {
            let api = try makeUniqueAPIEndpoint(excluding: usedPorts)
            usedPorts.insert(api.port)
            let proxy = try makeUniquePort(excluding: usedPorts)
            usedPorts.insert(proxy)
            endpoints.append(LocationWorkerEndpoint(api: api, proxyPort: proxy))
        }
        return endpoints
    }

    private static func makeUniqueAPIEndpoint(excluding ports: Set<Int>) throws -> LocalAPIEndpoint {
        for _ in 0 ..< 8 {
            let endpoint = try LocalAPIEndpoint.make()
            if !ports.contains(endpoint.port) { return endpoint }
        }
        throw NekoPilotError.processFailed(CoreL10n.text(
            "无法分配位置探测 API 端口",
            "Could not allocate a location-probe API port"
        ))
    }

    private static func makeUniquePort(excluding ports: Set<Int>) throws -> Int {
        for _ in 0 ..< 8 {
            let port = try LocalAPIEndpoint.make().port
            if !ports.contains(port) { return port }
        }
        throw NekoPilotError.processFailed(CoreL10n.text(
            "无法分配位置探测代理端口",
            "Could not allocate a location-probe proxy port"
        ))
    }

    private static func run(
        job: LocationProbeJob,
        onResult: NodeLocationProgressHandler?
    ) async -> [String: NodeLocationRecord] {
        let temporaryDirectory = job.config.deletingLastPathComponent()
        let client = NativeControlClient(endpoint: job.apiEndpoint)
        let process = Process()
        process.executableURL = job.executable
        process.arguments = ["run", "-c", job.config.path, "--disable-color"]
        process.currentDirectoryURL = temporaryDirectory
        // A diagnostic may contain a server address. Location discovery keeps
        // both streams private and records only the parsed country code.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            _ = setpgid(process.processIdentifier, process.processIdentifier)
            try? writeOwnership(
                process: process,
                executable: job.executable,
                directory: temporaryDirectory
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            return await unavailable(job.nodes, onResult: onResult)
        }

        defer {
            stop(process)
            if ProcessInfo.processInfo.environment["NEKOPILOT_KEEP_VALIDATION"] != "1" {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }
        guard await waitUntilReady(job: job, process: process) else {
            await client.disconnect()
            return await unavailable(job.nodes, onResult: onResult)
        }

        var results: [String: NodeLocationRecord] = [:]
        for node in job.nodes {
            guard !Task.isCancelled else { break }
            let countryCode: String?
            do {
                if job.nodes.count > 1 {
                    try await client.select(node: node.runtimeTag)
                }
                countryCode = await locateCountry(proxyPort: job.proxyPort)
            } catch {
                countryCode = nil
            }
            guard !Task.isCancelled else { break }
            let completedAt = Date()
            let record = NodeLocationRecord(
                countryCode: countryCode,
                fingerprint: node.locationFingerprint,
                locatedAt: countryCode == nil ? nil : completedAt,
                lastAttemptAt: completedAt
            )
            results[node.runtimeTag] = record
            if let onResult { await onResult(node.runtimeTag, record) }
        }
        await client.disconnect()
        return results
    }

    private static func unavailable(
        _ nodes: [ProxyNode],
        onResult: NodeLocationProgressHandler?
    ) async -> [String: NodeLocationRecord] {
        var results: [String: NodeLocationRecord] = [:]
        for node in nodes {
            guard !Task.isCancelled else { break }
            let attemptedAt = Date()
            let record = NodeLocationRecord(
                countryCode: nil,
                fingerprint: node.locationFingerprint,
                locatedAt: nil,
                lastAttemptAt: attemptedAt
            )
            results[node.runtimeTag] = record
            if let onResult { await onResult(node.runtimeTag, record) }
        }
        return results
    }

    private static func locateCountry(proxyPort: Int) async -> String? {
        for endpoint in [NodeLocationProbeEndpoint.primary, NodeLocationProbeEndpoint.fallback] {
            guard !Task.isCancelled else { return nil }
            if let country = await fetchCountry(from: endpoint, proxyPort: proxyPort) {
                return country
            }
        }
        return nil
    }

    private static func fetchCountry(from endpoint: URL, proxyPort: Int) async -> String? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = endpointTimeout
        configuration.timeoutIntervalForResource = endpointTimeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.connectionProxyDictionary = [
            "HTTPEnable": true,
            "HTTPProxy": "127.0.0.1",
            "HTTPPort": proxyPort,
            "HTTPSEnable": true,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": proxyPort,
        ]

        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = endpointTimeout
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("close", forHTTPHeaderField: "Connection")

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard !Task.isCancelled,
                  let response = response as? HTTPURLResponse,
                  response.statusCode == 200 else { return nil }
            var data = Data()
            data.reserveCapacity(512)
            for try await byte in bytes {
                guard data.count < maximumResponseBytes else { return nil }
                data.append(byte)
            }
            return parseCountryCode(from: data)
        } catch {
            return nil
        }
    }

    private static func waitUntilReady(job: LocationProbeJob, process: Process) async -> Bool {
        for _ in 0 ..< 50 {
            guard process.isRunning, !Task.isCancelled else { return false }
            if PortProbe.isListening(job.apiEndpoint.port), PortProbe.isListening(job.proxyPort) {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        if kill(-pid, SIGTERM) != 0 { kill(pid, SIGTERM) }
        for _ in 0 ..< 10 where process.isRunning { usleep(50_000) }
        if process.isRunning, kill(-pid, SIGKILL) != 0 { kill(pid, SIGKILL) }
    }

    private static func writeOwnership(
        process: Process,
        executable: URL,
        directory: URL
    ) throws {
        guard let child = ProcessIdentity.record(
            pid: process.processIdentifier,
            expectedExecutablePath: executable.path
        ) else { return }
        let marker = LocationWorkerOwnership(
            ownerProcess: ProcessIdentity.current(),
            childProcess: child
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try AtomicFile.write(
            try encoder.encode(marker),
            to: directory.appendingPathComponent(LocationWorkerOwnership.filename)
        )
    }

    static func recoverAbandonedWorkers(in root: URL) async {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        guard let directories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        for directory in directories where directory.lastPathComponent.hasPrefix("NekoPilot-LocationProbe-") {
            let markerURL = directory.appendingPathComponent(LocationWorkerOwnership.filename)
            if let data = try? Data(contentsOf: markerURL),
               let marker = try? JSONDecoder().decode(LocationWorkerOwnership.self, from: data) {
                if let owner = marker.ownerProcess, ProcessIdentity.matches(owner) { continue }
                if ProcessIdentity.matches(marker.childProcess) {
                    terminateProcessGroup(pid: marker.childProcess.pid)
                    for _ in 0 ..< 10 where ProcessIdentity.matches(marker.childProcess) {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    if ProcessIdentity.matches(marker.childProcess) {
                        terminateProcessGroup(pid: marker.childProcess.pid, force: true)
                        for _ in 0 ..< 10 where ProcessIdentity.matches(marker.childProcess) {
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        }
                    }
                }
                if !ProcessIdentity.matches(marker.childProcess) {
                    try? fileManager.removeItem(at: directory)
                }
                continue
            }

            // A crash between writing the config and starting the process has
            // no child marker. Avoid racing another live app instance, but
            // eventually remove the credential-bearing directory.
            let values = try? directory.resourceValues(forKeys: keys)
            if let modified = values?.contentModificationDate,
               Date().timeIntervalSince(modified) >= 10 * 60 {
                try? fileManager.removeItem(at: directory)
            }
        }
    }
}

private struct LocationWorkerOwnership: Codable, Sendable {
    static let filename = ".worker-ownership.json"
    let ownerProcess: ProcessIdentityRecord?
    let childProcess: ProcessIdentityRecord
}

private func terminateProcessGroup(pid: Int32, force: Bool = false) {
    guard pid > 1 else { return }
    let signal = force ? SIGKILL : SIGTERM
    if kill(-pid, signal) != 0 { _ = kill(pid, signal) }
}

private struct LocationWorkerEndpoint: Sendable {
    let api: LocalAPIEndpoint
    let proxyPort: Int
}

private struct LocationProbeJob: Sendable {
    let nodes: [ProxyNode]
    let apiEndpoint: LocalAPIEndpoint
    let proxyPort: Int
    let config: URL
    let executable: URL
}

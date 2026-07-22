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
        let process: LocationWorkerProcess
        do {
            process = try launchOwnedWorker(
                executable: job.executable,
                arguments: ["run", "-c", job.config.path, "--disable-color"],
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

    private static func waitUntilReady(
        job: LocationProbeJob,
        process: LocationWorkerProcess
    ) async -> Bool {
        for _ in 0 ..< 50 {
            guard process.isRunning, !Task.isCancelled else { return false }
            if PortProbe.isListening(job.apiEndpoint.port), PortProbe.isListening(job.proxyPort) {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// Starts a worker behind a one-shot stdin gate. The launcher cannot exec
    /// sing-box until its ownership marker has been committed. If this app
    /// exits between `posix_spawn()` and the marker write, EOF closes the gate
    /// and the launcher exits without ever starting the credential-bearing
    /// worker. `POSIX_SPAWN_SETPGROUP` creates its process group atomically,
    /// avoiding macOS's post-exec `setpgid` EACCES race.
    static func launchOwnedWorker(
        executable: URL,
        arguments: [String],
        directory: URL,
        ownershipWriter: ((LocationWorkerProcess, URL, URL, URL) throws -> Void)? = nil
    ) throws -> LocationWorkerProcess {
        let launcher = URL(fileURLWithPath: "/bin/sh")
        let launcherArguments = [
            "-c",
            "cd \"$1\" || exit 1; shift; read -r launch_token || exit 0; " +
                "[ \"$launch_token\" = start ] || exit 0; exec 0<&-; " +
                "trap '' TERM; " +
                "(trap - TERM; exec \"$@\") & worker_pid=$!; " +
                "wait \"$worker_pid\"; worker_status=$?; " +
                "kill -KILL -- \"-$$\"; exit \"$worker_status\"",
            "nekopilot-location-launcher",
            directory.path,
            executable.path,
        ] + arguments
        let launch = try spawnGatedLauncher(
            executable: launcher,
            arguments: launcherArguments
        )
        var gateDescriptor: Int32? = launch.gateDescriptor

        guard let childIdentity = recordLaunchIdentity(
            pid: launch.pid,
            launcher: launcher
        ) else {
            close(launch.gateDescriptor)
            terminateAndReap(pid: launch.pid)
            throw NekoPilotError.processFailed(CoreL10n.text(
                "无法确认位置探测进程身份",
                "Could not verify the location-probe process identity"
            ))
        }
        let process = LocationWorkerProcess(
            pid: launch.pid,
            launchIdentity: childIdentity,
            expectedExecutablePath: executable.path
        )

        do {
            if let ownershipWriter {
                try ownershipWriter(process, launcher, executable, directory)
            } else {
                try writeOwnership(
                    process: process,
                    executable: executable,
                    directory: directory
                )
            }
            try writeAll(Data("start\n".utf8), to: launch.gateDescriptor)
            close(launch.gateDescriptor)
            gateDescriptor = nil
            return process
        } catch {
            // Closing without the token makes a still-waiting launcher exit;
            // stop is the fallback if it failed after consuming the token.
            if let gateDescriptor { close(gateDescriptor) }
            stop(process)
            throw error
        }
    }

    private static func spawnGatedLauncher(
        executable: URL,
        arguments: [String]
    ) throws -> GatedWorkerLaunch {
        try ProcessSpawnGate.withLock {
            try spawnGatedLauncherLocked(
                executable: executable,
                arguments: arguments
            )
        }
    }

    private static func spawnGatedLauncherLocked(
        executable: URL,
        arguments: [String]
    ) throws -> GatedWorkerLaunch {
        var gateDescriptors: [Int32] = [0, 0]
        guard Darwin.pipe(&gateDescriptors) == 0 else { throw posixError(errno) }
        guard setCloseOnExec(gateDescriptors) else {
            gateDescriptors.forEach { close($0) }
            throw posixError(errno)
        }
        guard fcntl(gateDescriptors[1], F_SETNOSIGPIPE, 1) == 0 else {
            gateDescriptors.forEach { close($0) }
            throw posixError(errno)
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var actionsInitialized = false
        var attributesInitialized = false
        defer {
            if actionsInitialized { posix_spawn_file_actions_destroy(&actions) }
            if attributesInitialized { posix_spawnattr_destroy(&attributes) }
        }

        var setupError = posix_spawn_file_actions_init(&actions)
        if setupError == 0 { actionsInitialized = true }
        if setupError == 0 {
            setupError = posix_spawn_file_actions_adddup2(
                &actions,
                gateDescriptors[0],
                STDIN_FILENO
            )
        }
        for descriptor in gateDescriptors where setupError == 0 {
            setupError = posix_spawn_file_actions_addclose(&actions, descriptor)
        }
        if setupError == 0 {
            setupError = "/dev/null".withCString { path in
                posix_spawn_file_actions_addopen(
                    &actions,
                    STDOUT_FILENO,
                    path,
                    O_WRONLY,
                    0
                )
            }
        }
        if setupError == 0 {
            setupError = "/dev/null".withCString { path in
                posix_spawn_file_actions_addopen(
                    &actions,
                    STDERR_FILENO,
                    path,
                    O_WRONLY,
                    0
                )
            }
        }
        if setupError == 0 {
            setupError = posix_spawnattr_init(&attributes)
            if setupError == 0 { attributesInitialized = true }
        }
        if setupError == 0 { setupError = posix_spawnattr_setpgroup(&attributes, 0) }
        if setupError == 0 {
            let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
            setupError = posix_spawnattr_setflags(&attributes, Int16(flags))
        }
        guard setupError == 0 else {
            gateDescriptors.forEach { close($0) }
            throw posixError(setupError)
        }

        let argumentStrings = [executable.path] + arguments
        let environmentStrings = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let spawnError = withCStringArray(argumentStrings) { argumentPointers in
            withCStringArray(environmentStrings) { environmentPointers in
                executable.path.withCString { path in
                    posix_spawn(
                        &pid,
                        path,
                        &actions,
                        &attributes,
                        argumentPointers,
                        environmentPointers
                    )
                }
            }
        }
        close(gateDescriptors[0])
        guard spawnError == 0 else {
            close(gateDescriptors[1])
            throw posixError(spawnError)
        }
        return GatedWorkerLaunch(pid: pid, gateDescriptor: gateDescriptors[1])
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers = strings.map { strdup($0) as UnsafeMutablePointer<CChar>? }
        pointers.append(nil)
        defer { pointers.dropLast().forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }

    private static func setCloseOnExec(_ descriptors: [Int32]) -> Bool {
        for descriptor in descriptors {
            let flags = fcntl(descriptor, F_GETFD)
            if flags < 0 || fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) < 0 {
                return false
            }
        }
        return true
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw posixError(count < 0 ? errno : EIO)
                }
            }
        }
    }

    private static func recordLaunchIdentity(
        pid: pid_t,
        launcher: URL
    ) -> ProcessIdentityRecord? {
        for _ in 0 ..< 20 {
            if let identity = ProcessIdentity.record(
                pid: pid,
                expectedExecutablePath: launcher.path
            ) {
                return identity
            }
            usleep(1_000)
        }
        return nil
    }

    private static func posixError(_ code: Int32) -> NekoPilotError {
        .processFailed(String(cString: strerror(code)))
    }

    private static func stop(_ process: LocationWorkerProcess) {
        process.stop()
    }

    private static func writeOwnership(
        process: LocationWorkerProcess,
        executable: URL,
        directory: URL
    ) throws {
        let marker = LocationWorkerOwnership(
            ownerProcess: ProcessIdentity.current(),
            childProcess: process.launchIdentity,
            expectedExecutablePath: executable.path,
            ownsProcessGroup: true
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
                let identityMatches = workerIdentityMatches(marker)
                let ownsProcessGroup = marker.ownsProcessGroup == true ||
                    (identityMatches && getpgid(marker.childProcess.pid) == marker.childProcess.pid)
                if identityMatches, ownsProcessGroup {
                    _ = kill(-marker.childProcess.pid, SIGTERM)
                    await waitForProcessGroupExit(pid: marker.childProcess.pid)
                    if processGroupExists(pid: marker.childProcess.pid) {
                        _ = kill(-marker.childProcess.pid, SIGKILL)
                        await waitForProcessGroupExit(pid: marker.childProcess.pid)
                    }
                } else if identityMatches {
                    // Compatibility for an old marker whose child never made
                    // it into a dedicated group. Revalidate its full identity
                    // before each exact-PID signal.
                    _ = kill(marker.childProcess.pid, SIGTERM)
                    await waitForWorkerExit(marker)
                    if workerIdentityMatches(marker) {
                        _ = kill(marker.childProcess.pid, SIGKILL)
                        await waitForWorkerExit(marker)
                    }
                }
                let ownedProcessRemains = ownsProcessGroup
                    ? processGroupExists(pid: marker.childProcess.pid)
                    : workerIdentityMatches(marker)
                if !ownedProcessRemains {
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

    static func workerIdentityMatches(_ marker: LocationWorkerOwnership) -> Bool {
        guard let actual = ProcessIdentity.record(pid: marker.childProcess.pid),
              actual.pid == marker.childProcess.pid,
              actual.startSeconds == marker.childProcess.startSeconds,
              actual.startMicroseconds == marker.childProcess.startMicroseconds else {
            return false
        }
        let actualPath = URL(fileURLWithPath: actual.executablePath).standardizedFileURL.path
        let launcherPath = URL(fileURLWithPath: marker.childProcess.executablePath)
            .standardizedFileURL.path
        if actualPath == launcherPath { return true }
        guard let expectedExecutablePath = marker.expectedExecutablePath else { return false }
        return actualPath == URL(fileURLWithPath: expectedExecutablePath).standardizedFileURL.path
    }

    static func processGroupExists(pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        if kill(-pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func waitForProcessGroupExit(pid: pid_t) async {
        for _ in 0 ..< 10 where processGroupExists(pid: pid) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func waitForWorkerExit(_ marker: LocationWorkerOwnership) async {
        for _ in 0 ..< 10 where workerIdentityMatches(marker) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

private struct GatedWorkerLaunch {
    let pid: pid_t
    let gateDescriptor: Int32
}

/// Owns the direct child returned by posix_spawn. Leader exit is observed with
/// WNOWAIT so the PID/PGID cannot be reused before the entire owned group has
/// received its cleanup signal and the leader is explicitly reaped.
final class LocationWorkerProcess: @unchecked Sendable {
    let pid: pid_t
    let launchIdentity: ProcessIdentityRecord
    let expectedExecutablePath: String
    private let lock = NSLock()
    private var reaped = false
    private var groupCleanupAttempted = false

    init(
        pid: pid_t,
        launchIdentity: ProcessIdentityRecord,
        expectedExecutablePath: String
    ) {
        self.pid = pid
        self.launchIdentity = launchIdentity
        self.expectedExecutablePath = expectedExecutablePath
    }

    var processIdentifier: pid_t { pid }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !reaped else { return false }
        var info = siginfo_t()
        while true {
            let result = waitid(
                P_PID,
                id_t(pid),
                &info,
                WEXITED | WNOHANG | WNOWAIT
            )
            if result == 0 { return info.si_pid == 0 }
            if errno == ECHILD {
                reaped = true
                return false
            }
            if errno == EINTR { continue }
            return false
        }
    }

    func waitUntilExit() {
        lock.lock()
        defer { lock.unlock() }
        waitForLeaderExitLocked()
        cleanupGroupLocked()
        reapLocked()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !reaped else { return }
        cleanupGroupLocked()
        reapLocked()
    }

    private func waitForLeaderExitLocked() {
        guard !reaped else { return }
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 {
            if errno == EINTR { continue }
            if errno == ECHILD { reaped = true }
            return
        }
    }

    private func cleanupGroupLocked() {
        guard !groupCleanupAttempted else { return }
        groupCleanupAttempted = true
        // The leader remains waitable until reapLocked, so its PID cannot be
        // reused while this owned PGID is signalled.
        _ = kill(-pid, SIGKILL)
    }

    private func reapLocked() {
        guard !reaped else { return }
        var rawStatus: Int32 = 0
        while waitpid(pid, &rawStatus, 0) == -1 {
            if errno == EINTR { continue }
            if errno == ECHILD { reaped = true }
            return
        }
        reaped = true
    }
}

private func terminateAndReap(pid: pid_t) {
    guard pid > 1 else { return }
    _ = kill(-pid, SIGKILL)
    var rawStatus: Int32 = 0
    while waitpid(pid, &rawStatus, 0) == -1 {
        if errno != EINTR { return }
    }
}

struct LocationWorkerOwnership: Codable, Sendable {
    static let filename = ".worker-ownership.json"
    let ownerProcess: ProcessIdentityRecord?
    let childProcess: ProcessIdentityRecord
    /// Added for gated launches. Older markers decode with nil and continue to
    /// match their child using the executable path recorded in childProcess.
    let expectedExecutablePath: String?
    /// New posix_spawn workers always own an atomic process group. Nil keeps
    /// older markers decodable and routes them through identity-safe fallback.
    let ownsProcessGroup: Bool?
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

import Darwin
import Foundation

public typealias URLTestProgressHandler = @Sendable (String, DelayRecord) async -> Void

public enum URLTestExecution: Sendable {
    /// Uses the running sing-box core when one exists. This is appropriate for
    /// the periodic automatic selector, which must not create extra cores.
    case activeCore
    /// Uses isolated, bounded workers so an explicit user speed test remains
    /// responsive even when the main proxy is connected.
    case isolatedWorkers
}

public actor URLTester {
    private static let nativeBatchSize = 10
    private static let maximumOfflineWorkers = 4
    private static let pollInterval: UInt64 = 200_000_000
    private let compiler: ConfigurationCompiler
    private let nativeAPI: NativeControlClient

    public init(compiler: ConfigurationCompiler, nativeAPI: NativeControlClient) {
        self.compiler = compiler
        self.nativeAPI = nativeAPI
    }

    public func test(
        nodes: [ProxyNode],
        engineRunning: Bool,
        execution: URLTestExecution = .activeCore,
        onResult: URLTestProgressHandler? = nil
    ) async -> [String: DelayRecord] {
        guard !nodes.isEmpty else { return [:] }
        if engineRunning, execution == .activeCore {
            return await Self.test(
                client: nativeAPI,
                nodes: nodes,
                maximumWait: Self.maximumWait(for: nodes.count),
                onResult: onResult
            )
        }
        return await testWithOfflineWorkers(nodes: nodes, onResult: onResult)
    }

    private func testWithOfflineWorkers(
        nodes: [ProxyNode],
        onResult: URLTestProgressHandler?
    ) async -> [String: DelayRecord] {
        guard let executable = try? SingBoxLocator.executable() else {
            return Self.unavailable(nodes)
        }
        let batches = Self.offlineBatches(nodes)
        let endpoints = batches.compactMap { _ in try? LocalAPIEndpoint.make() }
        guard endpoints.count == batches.count,
              let configurations = try? await compiler.makeOfflineTestConfigurations(
                  selectedNodeGroups: batches.map { $0.map(\.runtimeTag) },
                  apiEndpoints: endpoints
              ),
              configurations.count == batches.count else {
            return Self.unavailable(nodes)
        }
        let jobs = zip(zip(batches, endpoints), configurations).map { batchAndEndpoint, config in
            OfflineTestJob(
                nodes: batchAndEndpoint.0,
                endpoint: batchAndEndpoint.1,
                config: config,
                executable: executable
            )
        }

        var nextJobIndex = 0
        var merged: [String: DelayRecord] = [:]
        await withTaskGroup(of: [String: DelayRecord].self) { group in
            while nextJobIndex < min(jobs.count, Self.maximumOfflineWorkers) {
                let job = jobs[nextJobIndex]
                nextJobIndex += 1
                group.addTask {
                    await Self.testOffline(job: job, onResult: onResult)
                }
            }
            while let result = await group.next() {
                merged.merge(result, uniquingKeysWith: { _, newer in newer })
                guard !Task.isCancelled, nextJobIndex < jobs.count else { continue }
                let job = jobs[nextJobIndex]
                nextJobIndex += 1
                group.addTask {
                    await Self.testOffline(job: job, onResult: onResult)
                }
            }
        }
        guard !Task.isCancelled else { return [:] }
        for node in nodes where merged[node.runtimeTag] == nil {
            merged[node.runtimeTag] = DelayRecord(delay: nil)
        }
        return merged
    }

    private static func testOffline(
        job: OfflineTestJob,
        onResult: URLTestProgressHandler?
    ) async -> [String: DelayRecord] {
        let temporaryDirectory = job.config.deletingLastPathComponent()
        let client = NativeControlClient(endpoint: job.endpoint)
        let process = Process()
        process.executableURL = job.executable
        process.arguments = ["run", "-c", job.config.path, "--disable-color"]
        process.currentDirectoryURL = temporaryDirectory
        process.standardOutput = FileHandle.nullDevice
        let standardError = Pipe()
        process.standardError = standardError
        standardError.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            AppLogger.shared.warning("[sing-box URL Test] \(String(decoding: data, as: UTF8.self))")
        }
        do {
            try process.run()
            try? standardError.fileHandleForWriting.close()
            _ = setpgid(process.processIdentifier, process.processIdentifier)
        } catch {
            standardError.fileHandleForReading.readabilityHandler = nil
            try? standardError.fileHandleForReading.close()
            try? FileManager.default.removeItem(at: temporaryDirectory)
            return unavailable(job.nodes)
        }

        defer {
            Self.stop(process)
            standardError.fileHandleForReading.readabilityHandler = nil
            try? standardError.fileHandleForReading.close()
            if ProcessInfo.processInfo.environment["NEKOPILOT_KEEP_VALIDATION"] != "1" {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }
        guard await Self.waitUntilReady(endpoint: job.endpoint, process: process) else {
            AppLogger.shared.warning("offline URL Test core did not become ready")
            await client.disconnect()
            return unavailable(job.nodes)
        }
        let results = await test(
            client: client,
            nodes: job.nodes,
            maximumWait: maximumWait(for: job.nodes.count),
            onResult: onResult
        )
        await client.disconnect()
        return results
    }

    private static func test(
        client: NativeControlClient,
        nodes: [ProxyNode],
        maximumWait: TimeInterval,
        onResult: URLTestProgressHandler?
    ) async -> [String: DelayRecord] {
        guard !Task.isCancelled else { return [:] }
        let startedAt = Date()
        do {
            try await client.runURLTest()
        } catch {
            AppLogger.shared.warning("native URL Test request failed: \(error.localizedDescription)")
            return unavailable(nodes)
        }
        var results: [String: DelayRecord] = [:]
        let deadline = startedAt.addingTimeInterval(maximumWait)
        while Date() < deadline, !Task.isCancelled {
            do {
                let current = try await client.delayResults(nodes: nodes.map(\.runtimeTag))
                for node in nodes {
                    guard let result = current[node.runtimeTag] else { continue }
                    if result.measuredAt >= startedAt.addingTimeInterval(-1), results[node.runtimeTag] != result {
                        results[node.runtimeTag] = result
                        if let onResult { await onResult(node.runtimeTag, result) }
                    }
                }
            } catch {
                AppLogger.shared.warning("native URL Test status read failed: \(error.localizedDescription)")
            }
            if results.count == nodes.count { break }
            try? await Task.sleep(nanoseconds: pollInterval)
        }
        for node in nodes where results[node.runtimeTag] == nil {
            let result = DelayRecord(delay: nil)
            results[node.runtimeTag] = result
            if let onResult { await onResult(node.runtimeTag, result) }
        }
        return results
    }

    private static func unavailable(_ nodes: [ProxyNode]) -> [String: DelayRecord] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.runtimeTag, DelayRecord(delay: nil)) })
    }

    private static func offlineBatches(_ nodes: [ProxyNode]) -> [[ProxyNode]] {
        let workerCount = min(
            maximumOfflineWorkers,
            max(1, Int(ceil(Double(nodes.count) / Double(nativeBatchSize))))
        )
        let nodesPerWorker = Int(ceil(Double(nodes.count) / Double(workerCount)))
        return stride(from: 0, to: nodes.count, by: nodesPerWorker).map {
            Array(nodes[$0 ..< min($0 + nodesPerWorker, nodes.count)])
        }
    }

    private static func maximumWait(for nodeCount: Int) -> TimeInterval {
        let batches = max(1, Int(ceil(Double(nodeCount) / Double(nativeBatchSize))))
        // sing-box gives every batch a native 15 s TCP deadline. Keep a small
        // scheduling allowance without prematurely turning later batches into
        // false timeouts.
        return TimeInterval(batches * 16)
    }

    private static func waitUntilReady(endpoint: LocalAPIEndpoint, process: Process) async -> Bool {
        for _ in 0 ..< 50 {
            guard process.isRunning, !Task.isCancelled else { return false }
            // `SubscribeServiceStatus` is intentionally a long-lived stream.
            // Waiting for its first event can be delayed by the daemon's
            // scheduler even after its loopback API is usable. A TCP probe is
            // enough to gate this disposable worker; API calls below retain
            // their own bounded failure handling.
            if PortProbe.isListening(endpoint.port) { return true }
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
}

private struct OfflineTestJob: Sendable {
    let nodes: [ProxyNode]
    let endpoint: LocalAPIEndpoint
    let config: URL
    let executable: URL
}

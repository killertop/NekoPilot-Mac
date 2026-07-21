import Darwin
import Foundation

public typealias URLTestProgressHandler = @Sendable (String, DelayRecord) async -> Void

public actor URLTester {
    // This is a sing-box URL Test RTT, rather than a TCP handshake time.
    public static let testURL = "https://www.gstatic.com/generate_204"
    private let compiler: ConfigurationCompiler
    private let nativeAPI: NativeControlClient
    private let paths: AppPaths

    public init(compiler: ConfigurationCompiler, nativeAPI: NativeControlClient, paths: AppPaths) {
        self.compiler = compiler
        self.nativeAPI = nativeAPI
        self.paths = paths
    }

    public func test(
        nodes: [ProxyNode],
        engineRunning: Bool,
        onResult: URLTestProgressHandler? = nil
    ) async -> [String: DelayRecord] {
        guard !nodes.isEmpty else { return [:] }
        if engineRunning {
            return await test(client: nativeAPI, nodes: nodes, onResult: onResult)
        }

        guard let endpoint = try? LocalAPIEndpoint.make(),
              let config = try? await compiler.makeOfflineTestConfiguration(
                  selectedNode: nodes.first?.runtimeTag,
                  apiEndpoint: endpoint
              ),
              let executable = try? SingBoxLocator.executable() else {
            return unavailable(nodes)
        }
        let temporaryDirectory = config.deletingLastPathComponent()
        let client = NativeControlClient(endpoint: endpoint)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["run", "-c", config.path, "--disable-color"]
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
            return unavailable(nodes)
        }

        defer {
            Self.stop(process)
            standardError.fileHandleForReading.readabilityHandler = nil
            try? standardError.fileHandleForReading.close()
            if ProcessInfo.processInfo.environment["NEKOPILOT_KEEP_VALIDATION"] != "1" {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }
        guard await Self.waitUntilReady(client: client, process: process) else {
            AppLogger.shared.warning("offline URL Test core did not become ready")
            await client.disconnect()
            return unavailable(nodes)
        }
        let results = await test(client: client, nodes: nodes, onResult: onResult)
        await client.disconnect()
        return results
    }

    private func test(
        client: NativeControlClient,
        nodes: [ProxyNode],
        onResult: URLTestProgressHandler?
    ) async -> [String: DelayRecord] {
        let startedAt = Date()
        do {
            try await client.runURLTest()
        } catch {
            AppLogger.shared.warning("native URL Test request failed: \(error.localizedDescription)")
            return unavailable(nodes)
        }
        var results: [String: DelayRecord] = [:]
        // sing-box's native URL Test has a 10 s TCP timeout; allow DNS and
        // connection teardown to complete before declaring a node timed out.
        for _ in 0 ..< 80 where !Task.isCancelled {
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
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        for node in nodes where results[node.runtimeTag] == nil {
            let result = DelayRecord(delay: nil)
            results[node.runtimeTag] = result
            if let onResult { await onResult(node.runtimeTag, result) }
        }
        return results
    }

    private func unavailable(_ nodes: [ProxyNode]) -> [String: DelayRecord] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.runtimeTag, DelayRecord(delay: nil)) })
    }

    private static func waitUntilReady(client: NativeControlClient, process: Process) async -> Bool {
        for _ in 0 ..< 50 {
            guard process.isRunning, !Task.isCancelled else { return false }
            if await client.isReady() { return true }
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

import Darwin
import Foundation

public actor URLTester {
    // Keep this probe aligned with NekoPilot Android so latency values remain
    // comparable across devices. The result is an end-to-end URL Test RTT,
    // not a raw TCP ping.
    public static let testURL = "https://cp.cloudflare.com/"
    public static let timeoutMilliseconds = 3_000
    private let compiler: ConfigurationCompiler
    private let clashAPI: ClashAPIClient

    public init(compiler: ConfigurationCompiler, clashAPI: ClashAPIClient) {
        self.compiler = compiler
        self.clashAPI = clashAPI
    }

    public func test(
        nodes: [ProxyNode],
        engineRunning: Bool,
        maximumConcurrency: Int = 3
    ) async -> [String: DelayRecord] {
        guard !nodes.isEmpty else { return [:] }
        if engineRunning {
            return await concurrentTest(nodes: nodes, maximumConcurrency: maximumConcurrency) { node in
                await self.clashAPI.delay(
                    node: node.runtimeTag,
                    testURL: Self.testURL,
                    timeoutMilliseconds: Self.timeoutMilliseconds
                )
            }
        }
        guard let port = Self.availableLoopbackPort(),
              let executable = try? SingBoxLocator.executable() else {
            return Dictionary(uniqueKeysWithValues: nodes.map { ($0.runtimeTag, DelayRecord(delay: nil)) })
        }
        let secret = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        guard let config = try? await compiler.makeOfflineTestConfiguration(
            selectedNode: nodes.first?.runtimeTag,
            controllerPort: port,
            secret: secret
        ) else {
            return Dictionary(uniqueKeysWithValues: nodes.map { ($0.runtimeTag, DelayRecord(delay: nil)) })
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["run", "-c", config.path, "--disable-color"]
        process.currentDirectoryURL = config.deletingLastPathComponent()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            _ = setpgid(process.processIdentifier, process.processIdentifier)
        } catch {
            try? FileManager.default.removeItem(at: config.deletingLastPathComponent())
            return Dictionary(uniqueKeysWithValues: nodes.map { ($0.runtimeTag, DelayRecord(delay: nil)) })
        }

        let client = ClashAPIClient(controllerPort: port, secret: secret)
        return await withTaskCancellationHandler {
            defer {
                Self.stop(process)
                try? FileManager.default.removeItem(at: config.deletingLastPathComponent())
            }
            guard await Self.waitUntilReady(client: client, process: process) else {
                return Dictionary(uniqueKeysWithValues: nodes.map { ($0.runtimeTag, DelayRecord(delay: nil)) })
            }
            return await concurrentTest(nodes: nodes, maximumConcurrency: maximumConcurrency) { node in
                await client.delay(
                    node: node.runtimeTag,
                    testURL: Self.testURL,
                    timeoutMilliseconds: Self.timeoutMilliseconds
                )
            }
        } onCancel: {
            Self.stop(process)
        }
    }

    private static func waitUntilReady(client: ClashAPIClient, process: Process) async -> Bool {
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

    private static func availableLoopbackPort() -> Int? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let didBind = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard didBind == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let didRead = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard didRead == 0 else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func concurrentTest(
        nodes: [ProxyNode],
        maximumConcurrency: Int,
        operation: @escaping @Sendable (ProxyNode) async -> Int?
    ) async -> [String: DelayRecord] {
        let limit = max(1, min(maximumConcurrency, nodes.count))
        return await withTaskGroup(of: (String, DelayRecord).self) { group in
            var iterator = nodes.makeIterator()
            for _ in 0 ..< limit {
                if let node = iterator.next() {
                    group.addTask { (node.runtimeTag, DelayRecord(delay: await operation(node))) }
                }
            }
            var result: [String: DelayRecord] = [:]
            while let value = await group.next() {
                result[value.0] = value.1
                if let node = iterator.next() {
                    group.addTask { (node.runtimeTag, DelayRecord(delay: await operation(node))) }
                }
            }
            return result
        }
    }
}

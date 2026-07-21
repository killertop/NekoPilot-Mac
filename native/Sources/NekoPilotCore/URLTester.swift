import Foundation

public actor URLTester {
    public static let testURL = "https://www.google.com/generate_204"
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
                await self.clashAPI.delay(node: node.runtimeTag)
            }
        }
        guard let config = try? await compiler.makeOfflineTestConfiguration(selectedNode: nodes.first?.runtimeTag),
              let executable = try? SingBoxLocator.executable() else {
            return Dictionary(uniqueKeysWithValues: nodes.map { ($0.runtimeTag, DelayRecord(delay: nil)) })
        }
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
        return await concurrentTest(nodes: nodes, maximumConcurrency: maximumConcurrency) { node in
            let clock = ContinuousClock()
            let start = clock.now
            guard let result = try? await CommandRunner.run(
                executable: executable,
                arguments: [
                    "tools", "-c", config.path, "-o", node.runtimeTag,
                    "fetch", Self.testURL, "--disable-color",
                ],
                timeout: 7
            ), result.status == 0 else { return nil }
            let duration = start.duration(to: clock.now)
            return Int(duration.components.seconds * 1_000) +
                Int(duration.components.attoseconds / 1_000_000_000_000_000)
        }
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

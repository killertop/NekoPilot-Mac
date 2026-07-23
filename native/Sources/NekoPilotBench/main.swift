import Darwin
import Foundation
import NekoPilotCore

/// Deterministic, offline-only performance measurements for NekoPilot core
/// paths. The runner uses synthetic `.invalid` endpoints and temporary files;
/// it never launches sing-box, contacts a subscription endpoint, or applies a
/// system proxy. Keep the raw JSONL output with every performance report so a
/// later change can use the exact same workload and sample count.
@main
enum NekoPilotBench {
    static func main() async {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            let writer = try JSONLWriter(output: options.output)
            defer { writer.close() }

            try writer.write(Metadata(options: options))
            let runner = BenchmarkRunner(options: options, writer: writer)
            let samples = try await runner.run()
            try runner.writeSummaries(for: samples)
        } catch {
            fputs("NekoPilotBench failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

private struct Options {
    let sizes: [Int]
    let runs: Int
    let loggerRecords: Int
    let output: URL?

    init(arguments: [String]) throws {
        var sizes = [1, 100, 1_000, 5_000]
        var runs = 5
        var loggerRecords = 10_000
        var output: URL?
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--sizes":
                index += 1
                guard index < arguments.count else { throw BenchError.usage("--sizes requires comma-separated positive integers") }
                let parsed = arguments[index].split(separator: ",").compactMap { Int($0) }
                guard !parsed.isEmpty, parsed.allSatisfy({ $0 > 0 }) else {
                    throw BenchError.usage("--sizes requires comma-separated positive integers")
                }
                sizes = Array(Set(parsed)).sorted()
            case "--runs":
                index += 1
                guard index < arguments.count, let parsed = Int(arguments[index]), parsed >= 5 else {
                    throw BenchError.usage("--runs must be at least 5")
                }
                runs = parsed
            case "--logger-records":
                index += 1
                guard index < arguments.count, let parsed = Int(arguments[index]), parsed > 0 else {
                    throw BenchError.usage("--logger-records must be positive")
                }
                loggerRecords = parsed
            case "--output":
                index += 1
                guard index < arguments.count else { throw BenchError.usage("--output requires a path") }
                output = URL(fileURLWithPath: arguments[index])
            case "--help", "-h":
                throw BenchError.usage(
                    "usage: NekoPilotBench [--sizes 1,100,1000,5000] [--runs 5] [--logger-records 10000] [--output results.jsonl]"
                )
            default:
                throw BenchError.usage("unknown argument: \(argument)")
            }
            index += 1
        }

        self.sizes = sizes
        self.runs = runs
        self.loggerRecords = loggerRecords
        self.output = output
    }
}

private enum BenchError: LocalizedError {
    case usage(String)
    case invalidIsolatedConfiguration(URL)

    var errorDescription: String? {
        switch self {
        case let .usage(message): message
        case let .invalidIsolatedConfiguration(url): "refusing to remove unexpected isolated configuration: \(url.path)"
        }
    }
}

private struct Metadata: Codable {
    let kind: String
    let timestamp: String
    let operatingSystem: String
    let activeProcessorCount: Int
    let physicalMemoryBytes: UInt64
    let sizes: [Int]
    let measuredRuns: Int
    let warmupRuns: Int
    let loggerRecords: Int
    let sourceCommit: String?
    let sourceVersion: String?

    init(options: Options) {
        kind = "metadata"
        timestamp = ISO8601DateFormatter().string(from: Date())
        operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
        activeProcessorCount = ProcessInfo.processInfo.activeProcessorCount
        physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
        sizes = options.sizes
        measuredRuns = options.runs
        warmupRuns = 1
        loggerRecords = options.loggerRecords
        sourceCommit = ProcessInfo.processInfo.environment["NEKOPILOT_BENCH_COMMIT"]
        sourceVersion = ProcessInfo.processInfo.environment["NEKOPILOT_BENCH_VERSION"]
    }
}

private struct BenchmarkSample: Codable {
    let kind: String
    let timestamp: String
    let scenario: String
    let nodes: Int
    let run: Int
    let warmup: Bool
    let wallMilliseconds: Double
    let userCPUMilliseconds: Double
    let systemCPUMilliseconds: Double
    let processMaxResidentBytesSinceStart: Int64
    var outputBytes: Int

    init(
        timestamp: String,
        scenario: String,
        nodes: Int,
        run: Int,
        warmup: Bool,
        wallMilliseconds: Double,
        userCPUMilliseconds: Double,
        systemCPUMilliseconds: Double,
        processMaxResidentBytesSinceStart: Int64,
        outputBytes: Int
    ) {
        kind = "sample"
        self.timestamp = timestamp
        self.scenario = scenario
        self.nodes = nodes
        self.run = run
        self.warmup = warmup
        self.wallMilliseconds = wallMilliseconds
        self.userCPUMilliseconds = userCPUMilliseconds
        self.systemCPUMilliseconds = systemCPUMilliseconds
        self.processMaxResidentBytesSinceStart = processMaxResidentBytesSinceStart
        self.outputBytes = outputBytes
    }
}

private struct Summary: Codable {
    let kind: String
    let scenario: String
    let nodes: Int
    let samples: Int
    let wallMilliseconds: Distribution
    let userCPUMilliseconds: Distribution
    let systemCPUMilliseconds: Distribution
    let processMaxResidentBytesSinceStart: Distribution
    let outputBytes: Distribution

    init(
        scenario: String,
        nodes: Int,
        samples: Int,
        wallMilliseconds: Distribution,
        userCPUMilliseconds: Distribution,
        systemCPUMilliseconds: Distribution,
        processMaxResidentBytesSinceStart: Distribution,
        outputBytes: Distribution
    ) {
        kind = "summary"
        self.scenario = scenario
        self.nodes = nodes
        self.samples = samples
        self.wallMilliseconds = wallMilliseconds
        self.userCPUMilliseconds = userCPUMilliseconds
        self.systemCPUMilliseconds = systemCPUMilliseconds
        self.processMaxResidentBytesSinceStart = processMaxResidentBytesSinceStart
        self.outputBytes = outputBytes
    }
}

private struct Distribution: Codable {
    let minimum: Double
    let median: Double
    let p95: Double
    let maximum: Double

    init(_ values: [Double]) {
        let sorted = values.sorted()
        guard !sorted.isEmpty else {
            minimum = 0
            median = 0
            p95 = 0
            maximum = 0
            return
        }
        minimum = sorted[0]
        maximum = sorted[sorted.count - 1]
        if sorted.count.isMultiple(of: 2) {
            let upper = sorted.count / 2
            median = (sorted[upper - 1] + sorted[upper]) / 2
        } else {
            median = sorted[sorted.count / 2]
        }
        let p95Index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1))
        p95 = sorted[p95Index]
    }
}

private final class JSONLWriter {
    private let handle: FileHandle

    init(output: URL?) throws {
        if let output {
            let parent = output.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: output.path, contents: nil)
            handle = try FileHandle(forWritingTo: output)
        } else {
            handle = .standardOutput
        }
    }

    func write<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    func close() {
        guard handle !== FileHandle.standardOutput else { return }
        try? handle.close()
    }
}

private final class BenchmarkRunner {
    private let options: Options
    private let writer: JSONLWriter
    private let fileManager = FileManager.default

    init(options: Options, writer: JSONLWriter) {
        self.options = options
        self.writer = writer
    }

    func run() async throws -> [BenchmarkSample] {
        var samples: [BenchmarkSample] = []
        for nodes in options.sizes {
            let fixture = try Fixture(nodes: nodes)
            samples += try measureSeries(scenario: "node_rows", nodes: nodes) {
                NodeListPresentation.rows(fixture.proxyNodes, using: fixture.delays).count
            }
            samples += try measureSeries(scenario: "payload_parse_json", nodes: nodes) {
                let parsed = try SubscriptionPayloadParser.parse(fixture.jsonPayload)
                return parsed["outbounds"]?.arrayValue?.count ?? 0
            }
            samples += try measureSeries(scenario: "payload_parse_base64_links", nodes: nodes) {
                let parsed = try SubscriptionPayloadParser.parse(fixture.base64LinksPayload)
                return parsed["outbounds"]?.arrayValue?.count ?? 0
            }
            let repositorySamples = try await measureRepository(fixture: fixture)
            samples += repositorySamples.upsert
            samples += repositorySamples.coldNodes
            samples += repositorySamples.warmNodes
            samples += try await measureConfigurations(fixture: fixture)
        }
        samples += try measureLogger(scenario: "logger_plain", message: "benchmark lifecycle event state=running", records: options.loggerRecords)
        samples += try measureLogger(
            scenario: "logger_redaction_heavy",
            message: "vless://00000000-0000-0000-0000-000000000001@node.example.invalid:443?token=benchmark-token&uuid=00000000-0000-4000-8000-000000000001 Authorization: Bearer benchmark-token",
            records: options.loggerRecords
        )
        return samples
    }

    func writeSummaries(for samples: [BenchmarkSample]) throws {
        let groups = Dictionary(grouping: samples.filter { !$0.warmup }) { "\($0.scenario)|\($0.nodes)" }
        for group in groups.values {
            guard let first = group.first else { continue }
            let summary = Summary(
                scenario: first.scenario,
                nodes: first.nodes,
                samples: group.count,
                wallMilliseconds: Distribution(group.map(\.wallMilliseconds)),
                userCPUMilliseconds: Distribution(group.map(\.userCPUMilliseconds)),
                systemCPUMilliseconds: Distribution(group.map(\.systemCPUMilliseconds)),
                processMaxResidentBytesSinceStart: Distribution(group.map { Double($0.processMaxResidentBytesSinceStart) }),
                outputBytes: Distribution(group.map { Double($0.outputBytes) })
            )
            try writer.write(summary)
        }
    }

    private func measureSeries(
        scenario: String,
        nodes: Int,
        operation: () throws -> Int
    ) throws -> [BenchmarkSample] {
        var samples: [BenchmarkSample] = []
        for run in 0 ... options.runs {
            let warmup = run == 0
            let sample = try measure(
                scenario: scenario,
                nodes: nodes,
                run: run,
                warmup: warmup,
                operation: operation
            )
            try writer.write(sample)
            samples.append(sample)
        }
        return samples
    }

    private func measureAsyncSeries(
        scenario: String,
        nodes: Int,
        operation: @escaping () async throws -> Int
    ) async throws -> [BenchmarkSample] {
        var samples: [BenchmarkSample] = []
        for run in 0 ... options.runs {
            let warmup = run == 0
            let sample = try await measureAsync(
                scenario: scenario,
                nodes: nodes,
                run: run,
                warmup: warmup,
                operation: operation
            )
            try writer.write(sample)
            samples.append(sample)
        }
        return samples
    }

    private func measureRepository(
        fixture: Fixture
    ) async throws -> (
        upsert: [BenchmarkSample],
        coldNodes: [BenchmarkSample],
        warmNodes: [BenchmarkSample]
    ) {
        var upsert: [BenchmarkSample] = []
        var coldNodes: [BenchmarkSample] = []
        var warmNodes: [BenchmarkSample] = []
        for run in 0 ... options.runs {
            let root = temporaryRoot(prefix: "NekoPilotBench-Repository")
            let warmup = run == 0
            do {
                let repository = try SubscriptionRepository(databaseURL: root.appendingPathComponent("nodes.sqlite3"))
                let upsertSample = try await measureAsync(
                    scenario: "repository_upsert",
                    nodes: fixture.nodes,
                    run: run,
                    warmup: warmup
                ) {
                    let identifier = try await repository.upsert(
                        url: nil,
                        name: "Synthetic nodes",
                        sourceType: .localLink,
                        config: fixture.configuration
                    )
                    return identifier.utf8.count
                }
                try writer.write(upsertSample)
                upsert.append(upsertSample)

                let coldNodeSample = try await measureAsync(
                    scenario: "repository_nodes_cold",
                    nodes: fixture.nodes,
                    run: run,
                    warmup: warmup
                ) {
                    try await repository.nodes().count
                }
                try writer.write(coldNodeSample)
                coldNodes.append(coldNodeSample)

                // A refresh consumes the first snapshot. The automatic health
                // cycle and repeated presentation reads use the next snapshot,
                // so keep a separate measurement for that real steady-state
                // path instead of hiding it inside the cold parse result.
                let warmNodeSample = try await measureAsync(
                    scenario: "repository_nodes_warm",
                    nodes: fixture.nodes,
                    run: run,
                    warmup: warmup
                ) {
                    try await repository.nodes().count
                }
                try writer.write(warmNodeSample)
                warmNodes.append(warmNodeSample)
            } catch {
                try? fileManager.removeItem(at: root)
                throw error
            }
            try? fileManager.removeItem(at: root)
        }
        return (upsert, coldNodes, warmNodes)
    }

    private func measureConfigurations(fixture: Fixture) async throws -> [BenchmarkSample] {
        var samples: [BenchmarkSample] = []
        for run in 0 ... options.runs {
            let root = self.temporaryRoot(prefix: "NekoPilotBench-Configuration")
            let warmup = run == 0
            do {
                let paths = AppPaths(
                    applicationSupport: root.appendingPathComponent("Support", isDirectory: true),
                    logs: root.appendingPathComponent("Logs", isDirectory: true)
                )
                try fileManager.createDirectory(at: paths.applicationSupport, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: paths.logs, withIntermediateDirectories: true)
                let settings = try SettingsStore(fileURL: paths.settings)
                let repository = try SubscriptionRepository(databaseURL: paths.database)
                _ = try await repository.upsert(
                    url: nil,
                    name: "Synthetic nodes",
                    sourceType: .localLink,
                    config: fixture.configuration
                )
                guard let selectedNode = try await repository.nodes().first?.runtimeTag else {
                    throw NekoPilotError.noNodes
                }
                let compiler = ConfigurationCompiler(paths: paths, settings: settings, repository: repository)
                let endpoint = try LocalAPIEndpoint.make()
                var configurations: [URL] = []
                var sample = try await measureAsync(
                    scenario: "offline_config_generation",
                    nodes: fixture.nodes,
                    run: run,
                    warmup: warmup
                ) {
                    configurations = try await compiler.makeOfflineTestConfigurations(
                        selectedNodeGroups: [[selectedNode]],
                        apiEndpoints: [endpoint]
                    )
                    return configurations.count
                }
                defer {
                    for configuration in configurations {
                        try? self.removeIsolatedConfiguration(configuration)
                    }
                }
                sample.outputBytes = try configurations.reduce(into: 0) { bytes, configuration in
                    bytes += try Data(contentsOf: configuration).count
                }
                try writer.write(sample)
                samples.append(sample)
            } catch {
                try? fileManager.removeItem(at: root)
                throw error
            }
            try? fileManager.removeItem(at: root)
        }
        return samples
    }

    private func measureLogger(scenario: String, message: String, records: Int) throws -> [BenchmarkSample] {
        try measureSeries(scenario: scenario, nodes: records) { [fileManager] in
            let root = self.temporaryRoot(prefix: "NekoPilotBench-Logger")
            defer { try? fileManager.removeItem(at: root) }
            let log = root.appendingPathComponent("NekoPilot.log")
            do {
                let logger = AppLogger()
                logger.configure(destination: log)
                for index in 0 ..< records {
                    logger.info("\(message) record=\(index)")
                }
                logger.configure(destination: root.appendingPathComponent("closed.log"))
            }
            return (try? fileManager.attributesOfItem(atPath: log.path)[.size] as? NSNumber)?.intValue ?? 0
        }
    }

    private func measure(
        scenario: String,
        nodes: Int,
        run: Int,
        warmup: Bool,
        operation: () throws -> Int
    ) throws -> BenchmarkSample {
        let before = ResourceUsage.current
        let started = DispatchTime.now().uptimeNanoseconds
        let outputBytes = try operation()
        let elapsed = DispatchTime.now().uptimeNanoseconds &- started
        let after = ResourceUsage.current
        return BenchmarkSample(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            scenario: scenario,
            nodes: nodes,
            run: run,
            warmup: warmup,
            wallMilliseconds: Double(elapsed) / 1_000_000,
            userCPUMilliseconds: (after.userSeconds - before.userSeconds) * 1_000,
            systemCPUMilliseconds: (after.systemSeconds - before.systemSeconds) * 1_000,
            processMaxResidentBytesSinceStart: after.maxResidentBytes,
            outputBytes: outputBytes
        )
    }

    private func measureAsync(
        scenario: String,
        nodes: Int,
        run: Int,
        warmup: Bool,
        operation: () async throws -> Int
    ) async throws -> BenchmarkSample {
        let before = ResourceUsage.current
        let started = DispatchTime.now().uptimeNanoseconds
        let outputBytes = try await operation()
        let elapsed = DispatchTime.now().uptimeNanoseconds &- started
        let after = ResourceUsage.current
        return BenchmarkSample(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            scenario: scenario,
            nodes: nodes,
            run: run,
            warmup: warmup,
            wallMilliseconds: Double(elapsed) / 1_000_000,
            userCPUMilliseconds: (after.userSeconds - before.userSeconds) * 1_000,
            systemCPUMilliseconds: (after.systemSeconds - before.systemSeconds) * 1_000,
            processMaxResidentBytesSinceStart: after.maxResidentBytes,
            outputBytes: outputBytes
        )
    }

    private func temporaryRoot(prefix: String) -> URL {
        let root = fileManager.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func removeIsolatedConfiguration(_ configuration: URL) throws {
        let directory = configuration.deletingLastPathComponent()
        guard configuration.lastPathComponent == "config.json",
              directory.lastPathComponent.hasPrefix("NekoPilot-URLTest-") else {
            throw BenchError.invalidIsolatedConfiguration(configuration)
        }
        try fileManager.removeItem(at: directory)
    }
}

private struct Fixture {
    let nodes: Int
    let configuration: [String: JSONValue]
    let proxyNodes: [ProxyNode]
    let delays: [String: DelayRecord]
    let jsonPayload: Data
    let base64LinksPayload: Data

    init(nodes: Int) throws {
        self.nodes = nodes
        let outbounds = (0 ..< nodes).map { index in Self.outbound(index: index) }
        configuration = ["outbounds": .array(outbounds)]
        jsonPayload = try JSONValue.encodeObject(configuration)
        proxyNodes = outbounds.enumerated().compactMap { index, value in
            guard let outbound = value.objectValue else { return nil }
            let tag = Self.tag(index)
            return ProxyNode(
                sourceIdentifier: "benchmark",
                sourceName: "Synthetic",
                originalTag: "VLESS · \(tag)",
                runtimeTag: "@np:benchmark:\(tag)",
                protocolName: "vless",
                outbound: outbound
            )
        }
        delays = Dictionary(uniqueKeysWithValues: proxyNodes.enumerated().map { index, node in
            (node.runtimeTag, DelayRecord(delay: (index % 400) + 10, measuredAt: Date(timeIntervalSince1970: 1_700_000_000)))
        })
        let links = (0 ..< nodes).map { index in
            "vless://00000000-0000-0000-0000-000000000001@node-\(index).example.invalid:443?security=tls#\(Self.tag(index))"
        }.joined(separator: "\n")
        base64LinksPayload = Data(links.utf8).base64EncodedData()
    }

    private static func tag(_ index: Int) -> String {
        String(format: "node-%05d", index)
    }

    private static func outbound(index: Int) -> JSONValue {
        .object([
            "type": .string("vless"),
            "tag": .string(tag(index)),
            "server": .string("node-\(index).example.invalid"),
            "server_port": .number(443),
            "uuid": .string("00000000-0000-0000-0000-000000000001"),
            "tls": .object(["enabled": .bool(true)]),
        ])
    }
}

private struct ResourceUsage {
    let userSeconds: Double
    let systemSeconds: Double
    let maxResidentBytes: Int64

    static var current: ResourceUsage {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return ResourceUsage(
            userSeconds: seconds(usage.ru_utime),
            systemSeconds: seconds(usage.ru_stime),
            maxResidentBytes: Int64(usage.ru_maxrss)
        )
    }

    private static func seconds(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }
}

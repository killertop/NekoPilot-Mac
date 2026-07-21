import Foundation

public struct NativeSelector: Sendable, Equatable {
    public let current: String
    public let nodes: [String]
}

private struct NativeGroupsResponse: Decodable {
    let group: [NativeGroup]
    private enum CodingKeys: String, CodingKey { case group }

    init(from decoder: Decoder) throws {
        group = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([NativeGroup].self, forKey: .group) ?? []
    }
}

private struct NativeGroup: Decodable {
    let tag: String
    let selected: String
    let items: [NativeGroupItem]
    private enum CodingKeys: String, CodingKey { case tag, selected, items }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tag = try values.decode(String.self, forKey: .tag)
        selected = try values.decodeIfPresent(String.self, forKey: .selected) ?? ""
        items = try values.decodeIfPresent([NativeGroupItem].self, forKey: .items) ?? []
    }
}

private struct NativeGroupItem: Decodable {
    let tag: String
    let urlTestTime: Int64?
    let urlTestDelay: Int?
}

private struct NativeOutboundsResponse: Decodable {
    let outbounds: [NativeGroupItem]
    private enum CodingKeys: String, CodingKey { case outbounds }

    init(from decoder: Decoder) throws {
        outbounds = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([NativeGroupItem].self, forKey: .outbounds) ?? []
    }
}

public actor NativeControlClient {
    private let paths: AppPaths
    public nonisolated let socketPath: URL

    public init(paths: AppPaths) {
        self.paths = paths
        socketPath = paths.nativeAPISocket
    }

    public func isReady() async -> Bool {
        (try? await request("ready")) != nil
    }

    public func selector(knownNodes: [String] = []) async throws -> NativeSelector {
        let groups: NativeGroupsResponse = try await decode("groups")
        if let group = groups.group.first(where: { $0.tag == "ExitGateway" }) {
            return NativeSelector(current: group.selected, nodes: group.items.map(\.tag))
        }
        // sing-box 1.14 intentionally omits groups with fewer than two items
        // from SubscribeGroups. The app already owns the one-node selection;
        // no synthetic gRPC data is created here.
        guard knownNodes.count == 1, let node = knownNodes.first else {
            throw NekoPilotError.processFailed("无法读取当前节点")
        }
        return NativeSelector(current: node, nodes: [node])
    }

    public func select(node: String) async throws {
        _ = try await request("select", extra: ["--group", "ExitGateway", "--node", node])
    }

    public func reload() async throws {
        _ = try await request("reload")
    }

    public func runURLTest(group: String = "ExitGateway") async throws {
        _ = try await request("url-test", extra: ["--group", group])
    }

    public func delayResults(nodes: [String]) async throws -> [String: DelayRecord] {
        let groups: NativeGroupsResponse = try await decode("groups")
        let items: [NativeGroupItem]
        if let group = groups.group.first(where: { $0.tag == "ExitGateway" }) {
            items = group.items
        } else {
            let outbounds: NativeOutboundsResponse = try await decode("outbounds")
            let expected = Set(nodes)
            items = outbounds.outbounds.filter { expected.contains($0.tag) }
        }
        return Dictionary(uniqueKeysWithValues: items.compactMap { item in
            guard let seconds = item.urlTestTime, seconds > 0 else { return nil }
            let delay = (item.urlTestDelay ?? 0) > 0 ? item.urlTestDelay : nil
            return (item.tag, DelayRecord(delay: delay, measuredAt: Date(timeIntervalSince1970: TimeInterval(seconds))))
        })
    }

    private func decode<T: Decodable>(_ command: String) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await request(command))
    }

    private func request(_ command: String, extra: [String] = []) async throws -> Data {
        let executable = try SingBoxLocator.executable()
        let result = try await CommandRunner.run(
            executable: executable,
            arguments: ["ctl", "--api-socket", paths.nativeAPISocket.path] + extra + [command],
            timeout: 10
        )
        guard result.status == 0 else {
            throw NekoPilotError.processFailed(
                (result.errorOutput.isEmpty ? result.output : result.errorOutput)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return Data(result.output.utf8)
    }
}

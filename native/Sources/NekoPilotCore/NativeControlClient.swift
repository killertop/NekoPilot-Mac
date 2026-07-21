import Foundation
import GRPC
import SwiftProtobuf

public struct NativeSelector: Sendable, Equatable {
    public let current: String
    public let nodes: [String]
}

/// Swift's direct client for sing-box 1.14's public StartedService API.
///
/// This intentionally has no command-line control shim, no Unix socket
/// protocol, and no Clash compatibility endpoint. The API endpoint is created
/// per core process and authenticated with its in-memory random secret.
public actor NativeControlClient {
    private static let startedService = "/daemon.StartedService"
    private let group = PlatformSupport.makeEventLoopGroup(loopCount: 1)
    private var endpoint: LocalAPIEndpoint?
    private var connection: ClientConnection?

    public init(endpoint: LocalAPIEndpoint? = nil) {
        self.endpoint = endpoint
        if let endpoint {
            connection = ClientConnection.insecure(group: group)
                .connect(host: endpoint.host, port: endpoint.port)
        }
    }

    deinit {
        _ = connection?.close()
        try? group.syncShutdownGracefully()
    }

    public func configure(endpoint: LocalAPIEndpoint) {
        _ = connection?.close()
        self.endpoint = endpoint
        connection = ClientConnection.insecure(group: group)
            .connect(host: endpoint.host, port: endpoint.port)
    }

    public func disconnect() {
        _ = connection?.close()
        connection = nil
        endpoint = nil
    }

    public func isReady() async -> Bool {
        do {
            let status: Nekopilot_Api_ServiceStatus = try await firstMessage(
                method: "SubscribeServiceStatus",
                request: Google_Protobuf_Empty()
            )
            return status.status == 2 // daemon.ServiceStatus.STARTED
        } catch {
            return false
        }
    }

    public func selector(knownNodes: [String] = []) async throws -> NativeSelector {
        let groups: Nekopilot_Api_Groups = try await firstMessage(
            method: "SubscribeGroups",
            request: Google_Protobuf_Empty()
        )
        if let group = groups.group.first(where: { $0.tag == "ExitGateway" }) {
            return NativeSelector(current: group.selected, nodes: group.items.map(\.tag))
        }
        // sing-box intentionally omits a selector with fewer than two items.
        guard knownNodes.count == 1, let node = knownNodes.first else {
            throw NekoPilotError.processFailed("无法读取当前节点")
        }
        return NativeSelector(current: node, nodes: [node])
    }

    public func select(node: String) async throws {
        var request = Nekopilot_Api_SelectOutboundRequest()
        request.groupTag = "ExitGateway"
        request.outboundTag = node
        _ = try await unary(method: "SelectOutbound", request: request)
    }

    public func runURLTest(group: String = "ExitGateway") async throws {
        var request = Nekopilot_Api_URLTestRequest()
        request.outboundTag = group
        _ = try await unary(method: "URLTest", request: request)
    }

    public func delayResults(nodes: [String]) async throws -> [String: DelayRecord] {
        let groups: Nekopilot_Api_Groups = try await firstMessage(
            method: "SubscribeGroups",
            request: Google_Protobuf_Empty()
        )
        let items: [Nekopilot_Api_GroupItem]
        if let group = groups.group.first(where: { $0.tag == "ExitGateway" }) {
            items = group.items
        } else {
            let outbounds: Nekopilot_Api_OutboundList = try await firstMessage(
                method: "SubscribeOutbounds",
                request: Google_Protobuf_Empty()
            )
            let expected = Set(nodes)
            items = outbounds.outbounds.filter { expected.contains($0.tag) }
        }
        return Dictionary(uniqueKeysWithValues: items.compactMap { item in
            guard item.urlTestTime > 0 else { return nil }
            let delay = item.urlTestDelay > 0 ? Int(item.urlTestDelay) : nil
            return (
                item.tag,
                DelayRecord(delay: delay, measuredAt: Date(timeIntervalSince1970: TimeInterval(item.urlTestTime)))
            )
        })
    }

    private func unary<Request: SwiftProtobuf.Message>(
        method: String,
        request: Request
    ) async throws -> Google_Protobuf_Empty {
        let call: UnaryCall<Request, Google_Protobuf_Empty> = try activeConnection().makeUnaryCall(
            path: Self.startedService + "/" + method,
            request: request,
            callOptions: options(),
            interceptors: []
        )
        return try await call.response.get()
    }

    private func firstMessage<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
        method: String,
        request: Request
    ) async throws -> Response {
        let client = APIClient(channel: try activeConnection(), defaultCallOptions: options())
        let call: GRPCAsyncServerStreamingCall<Request, Response> = client.makeAsyncServerStreamingCall(
            path: Self.startedService + "/" + method,
            request: request,
            responseType: Response.self
        )
        for try await message in call.responseStream {
            call.cancel()
            return message
        }
        throw NekoPilotError.processFailed("sing-box API 未返回 \(method) 状态")
    }

    private func activeConnection() throws -> ClientConnection {
        guard let connection else {
            throw NekoPilotError.processFailed("sing-box API 尚未连接")
        }
        return connection
    }

    private func options() -> CallOptions {
        guard let endpoint else { return CallOptions() }
        var options = CallOptions()
        options.customMetadata.add(name: "authorization", value: "Bearer \(endpoint.secret)")
        return options
    }
}

private struct APIClient: GRPCClient {
    let channel: GRPCChannel
    var defaultCallOptions: CallOptions
}

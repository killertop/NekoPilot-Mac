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
/// per core process and authenticated with a short-lived random secret stored
/// only in the owner-readable runtime configuration for that process.
public actor NativeControlClient {
    private static let startedService = "/daemon.StartedService"
    // The control plane is loopback-only, so one app-lifetime event-loop group
    // is sufficient for the main core and the short-lived URL Test workers.
    private static let sharedGroup = PlatformSupport.makeEventLoopGroup(loopCount: 1)
    private let group = NativeControlClient.sharedGroup
    private let logger: any AppLogging
    private var endpoint: LocalAPIEndpoint?
    private var connection: ClientConnection?

    public init(
        endpoint: LocalAPIEndpoint? = nil,
        logger: any AppLogging = AppLogger.shared
    ) {
        self.endpoint = endpoint
        self.logger = logger
        if let endpoint {
            connection = ClientConnection.insecure(group: group)
                .connect(host: endpoint.host, port: endpoint.port)
        }
    }

    deinit {
        _ = connection?.close()
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
            throw NekoPilotError.processFailed(CoreL10n.text(
                "无法读取当前节点",
                "Could not read the selected node"
            ))
        }
        return NativeSelector(current: node, nodes: [node])
    }

    public func select(node: String) async throws {
        var request = Nekopilot_Api_SelectOutboundRequest()
        request.groupTag = "ExitGateway"
        request.outboundTag = node
        _ = try await unary(method: "SelectOutbound", request: request)
    }

    /// Starts sing-box's asynchronous URL Test without awaiting all network
    /// probes. The daemon records results through its status stream; waiting
    /// for the unary acknowledgement can otherwise serialize polling behind
    /// slow or unreachable nodes.
    public func runURLTest(group: String = "ExitGateway") throws {
        var request = Nekopilot_Api_URLTestRequest()
        request.outboundTag = group
        let call: UnaryCall<Nekopilot_Api_URLTestRequest, Google_Protobuf_Empty> = try activeConnection().makeUnaryCall(
            path: Self.startedService + "/URLTest",
            request: request,
            callOptions: options(timeLimit: .timeout(.seconds(3))),
            interceptors: []
        )
        Task {
            do {
                _ = try await call.response.get()
            } catch {
                logger.warning("native URL Test request failed: \(error.localizedDescription)")
            }
        }
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

    /// Streams normalized one-second traffic rates grouped by the concrete
    /// runtime outbound used by each connection. Samples are sparse and replace
    /// the previous sample: an absent node has zero traffic for that interval.
    public func nodeTrafficStream(
        nodes: Set<String>,
        interval: TimeInterval = 1
    ) throws -> AsyncThrowingStream<[String: NodeTrafficSnapshot], Error> {
        let intervalNanoseconds = Self.trafficIntervalNanoseconds(interval)
        var request = Nekopilot_Api_SubscribeConnectionsRequest()
        request.interval = Int64(intervalNanoseconds)
        let client = APIClient(
            channel: try activeConnection(),
            defaultCallOptions: options()
        )
        let call: GRPCAsyncServerStreamingCall<
            Nekopilot_Api_SubscribeConnectionsRequest,
            Nekopilot_Api_ConnectionEvents
        > = client.makeAsyncServerStreamingCall(
            path: Self.startedService + "/SubscribeConnections",
            request: request,
            responseType: Nekopilot_Api_ConnectionEvents.self
        )

        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let meter = NodeTrafficMeter(validOutbounds: nodes)
            let task = Task {
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            defer { call.cancel() }
                            for try await events in call.responseStream {
                                try Task.checkCancellation()
                                await meter.apply(events)
                            }
                        }
                        group.addTask {
                            var previousTick = DispatchTime.now().uptimeNanoseconds
                            while !Task.isCancelled {
                                try await Task.sleep(nanoseconds: intervalNanoseconds)
                                let currentTick = DispatchTime.now().uptimeNanoseconds
                                let elapsed = max(1, currentTick &- previousTick)
                                previousTick = currentTick
                                let snapshot = await meter.takeSnapshot(
                                    elapsedNanoseconds: elapsed,
                                    measuredAt: Date()
                                )
                                if case .terminated = continuation.yield(snapshot) { return }
                            }
                        }

                        // Either the daemon stream ended or the consumer stopped.
                        // Cancel the sibling and wait for both tasks to unwind so
                        // the gRPC call cannot outlive its AsyncSequence.
                        _ = try await group.next()
                        group.cancelAll()
                        while let _ = try await group.next() { }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func unary<Request: SwiftProtobuf.Message>(
        method: String,
        request: Request
    ) async throws -> Google_Protobuf_Empty {
        let call: UnaryCall<Request, Google_Protobuf_Empty> = try activeConnection().makeUnaryCall(
            path: Self.startedService + "/" + method,
            request: request,
            callOptions: options(timeLimit: .timeout(.seconds(3))),
            interceptors: []
        )
        return try await call.response.get()
    }

    private func firstMessage<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
        method: String,
        request: Request
    ) async throws -> Response {
        let client = APIClient(
            channel: try activeConnection(),
            defaultCallOptions: options(timeLimit: .timeout(.milliseconds(400)))
        )
        let call: GRPCAsyncServerStreamingCall<Request, Response> = client.makeAsyncServerStreamingCall(
            path: Self.startedService + "/" + method,
            request: request,
            responseType: Response.self
        )
        for try await message in call.responseStream {
            call.cancel()
            return message
        }
        throw NekoPilotError.processFailed(CoreL10n.text(
            "sing-box API 未返回 \(method) 状态",
            "The sing-box API returned no \(method) status"
        ))
    }

    private func activeConnection() throws -> ClientConnection {
        guard let connection else {
            throw NekoPilotError.processFailed(CoreL10n.text(
                "sing-box API 尚未连接",
                "The sing-box API is not connected"
            ))
        }
        return connection
    }

    private func options(timeLimit: TimeLimit = .none) -> CallOptions {
        guard let endpoint else { return CallOptions(timeLimit: timeLimit) }
        var options = CallOptions()
        options.timeLimit = timeLimit
        options.customMetadata.add(name: "authorization", value: "Bearer \(endpoint.secret)")
        return options
    }

    private static func trafficIntervalNanoseconds(_ interval: TimeInterval) -> UInt64 {
        guard interval.isFinite, interval > 0 else { return 1_000_000_000 }
        let bounded = min(max(interval, 0.1), 60)
        return UInt64((bounded * 1_000_000_000).rounded())
    }
}

private struct APIClient: GRPCClient {
    let channel: GRPCChannel
    var defaultCallOptions: CallOptions
}

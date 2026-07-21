import Foundation

public enum EngineStatus: Equatable, Sendable {
    case stopped
    case starting
    case running
    case stopping
    case failed(String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var isBusy: Bool {
        switch self {
        case .starting, .stopping: true
        default: false
        }
    }
}

public struct Subscription: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let identifier: String
    public var name: String
    public let subscriptionURL: String?
    public let lastUpdateTime: Date
    public let sourceType: SourceType

    public enum SourceType: String, Sendable {
        case subscription
        case localLink = "local_link"
    }

    public init(
        id: Int64,
        identifier: String,
        name: String,
        subscriptionURL: String?,
        lastUpdateTime: Date,
        sourceType: SourceType
    ) {
        self.id = id
        self.identifier = identifier
        self.name = name
        self.subscriptionURL = subscriptionURL
        self.lastUpdateTime = lastUpdateTime
        self.sourceType = sourceType
    }
}

public struct ProxyNode: Identifiable, Equatable, Sendable {
    public let sourceIdentifier: String
    public let sourceName: String
    public let originalTag: String
    public let runtimeTag: String
    public let protocolName: String
    public let outbound: [String: JSONValue]

    public var id: String { runtimeTag }

    public init(
        sourceIdentifier: String,
        sourceName: String,
        originalTag: String,
        runtimeTag: String,
        protocolName: String,
        outbound: [String: JSONValue]
    ) {
        self.sourceIdentifier = sourceIdentifier
        self.sourceName = sourceName
        self.originalTag = originalTag
        self.runtimeTag = runtimeTag
        self.protocolName = protocolName
        self.outbound = outbound
    }
}

public enum RuleAction: String, CaseIterable, Codable, Sendable {
    case direct
    case proxy
}

public enum RuleKind: String, CaseIterable, Codable, Sendable {
    case domain
    case domainSuffix = "domain_suffix"
    case ipCIDR = "ip_cidr"
}

public struct RoutingRule: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var action: RuleAction
    public var kind: RuleKind
    public var value: String

    public init(id: UUID = UUID(), action: RuleAction, kind: RuleKind, value: String) {
        self.id = id
        self.action = action
        self.kind = kind
        self.value = value
    }
}

public struct DelayRecord: Codable, Equatable, Sendable {
    public let delay: Int?
    public let measuredAt: Date

    public init(delay: Int?, measuredAt: Date = Date()) {
        self.delay = delay
        self.measuredAt = measuredAt
    }
}

public struct TrafficSnapshot: Equatable, Sendable {
    public let upload: Int64
    public let download: Int64

    public static let zero = TrafficSnapshot(upload: 0, download: 0)
}

public enum NekoPilotError: LocalizedError, Equatable {
    case noNodes
    case nodeNotFound
    case invalidLink
    case unsupportedProtocol
    case invalidSubscription
    case remoteAddressBlocked
    case responseTooLarge
    case invalidRule
    case duplicateRule
    case singBoxMissing
    case portOccupied(Int)
    case processFailed(String)
    case invalidSetting(String)

    public var errorDescription: String? {
        switch self {
        case .noNodes: "没有可用节点"
        case .nodeNotFound: "节点不存在"
        case .invalidLink: "链接格式无效"
        case .unsupportedProtocol: "暂不支持该协议"
        case .invalidSubscription: "订阅中没有可用节点"
        case .remoteAddressBlocked: "订阅地址指向本机或内网，已拒绝访问"
        case .responseTooLarge: "订阅内容过大"
        case .invalidRule: "规则格式无效"
        case .duplicateRule: "规则已存在"
        case .singBoxMissing: "缺少 sing-box 代理核心"
        case let .portOccupied(port): "端口 \(port) 已被占用"
        case let .processFailed(message): message
        case let .invalidSetting(key): "设置项无效：\(key)"
        }
    }
}

import CryptoKit
import Foundation

enum CoreL10n {
    private static var usesChinese: Bool {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
    }

    static func text(_ chinese: String, _ english: String) -> String {
        usesChinese ? chinese : english
    }
}

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
    public let locationFingerprint: String

    public var id: String { runtimeTag }

    /// A stable identity for the endpoint configuration that determines a
    /// server's location. Runtime-only values injected by NekoPilot are
    /// excluded, while recursive detour dependencies are included so relay
    /// changes cannot inherit a stale egress country.
    private static func makeLocationFingerprint(
        from outbound: [String: JSONValue],
        dependencies: [[String: JSONValue]]
    ) -> String {
        func canonicalized(_ value: [String: JSONValue]) -> JSONValue {
            var value = value
            value.removeValue(forKey: "tag")
            value.removeValue(forKey: "domain_resolver")
            return .object(value)
        }
        let material: [String: JSONValue] = [
            "outbound": canonicalized(outbound),
            "detour_chain": .array(dependencies.map(canonicalized)),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = (try? encoder.encode(material)) ?? Data()
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }

    public init(
        sourceIdentifier: String,
        sourceName: String,
        originalTag: String,
        runtimeTag: String,
        protocolName: String,
        outbound: [String: JSONValue],
        locationDependencies: [[String: JSONValue]] = []
    ) {
        self.sourceIdentifier = sourceIdentifier
        self.sourceName = sourceName
        self.originalTag = originalTag
        self.runtimeTag = runtimeTag
        self.protocolName = protocolName
        self.outbound = outbound
        locationFingerprint = Self.makeLocationFingerprint(
            from: outbound,
            dependencies: locationDependencies
        )
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

/// A cached server-location lookup for one concrete runtime node.
///
/// `countryCode == nil` represents a recent unsuccessful lookup. A separate
/// `locatedAt` timestamp lets callers retain the last successful location
/// while `lastAttemptAt` throttles retries after transient failures.
public struct NodeLocationRecord: Equatable, Sendable {
    public let countryCode: String?
    public let fingerprint: String
    public let locatedAt: Date?
    public let lastAttemptAt: Date

    public init(
        countryCode: String?,
        fingerprint: String,
        locatedAt: Date?,
        lastAttemptAt: Date
    ) {
        self.countryCode = countryCode
        self.fingerprint = fingerprint
        self.locatedAt = locatedAt
        self.lastAttemptAt = lastAttemptAt
    }
}

/// One normalized one-second traffic sample for a concrete runtime outbound.
/// Values are bytes per second, not cumulative byte counters.
public struct NodeTrafficSnapshot: Equatable, Sendable {
    public let upload: Int64
    public let download: Int64
    public let measuredAt: Date

    public init(upload: Int64, download: Int64, measuredAt: Date = Date()) {
        self.upload = max(0, upload)
        self.download = max(0, download)
        self.measuredAt = measuredAt
    }

    public static let zero = NodeTrafficSnapshot(upload: 0, download: 0)
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
        case .noNodes: CoreL10n.text("没有可用节点", "No nodes are available")
        case .nodeNotFound: CoreL10n.text("节点不存在", "The node no longer exists")
        case .invalidLink: CoreL10n.text("链接格式无效", "The link format is invalid")
        case .unsupportedProtocol: CoreL10n.text("暂不支持该协议", "This protocol is not supported")
        case .invalidSubscription: CoreL10n.text("订阅中没有可用节点", "The subscription contains no usable nodes")
        case .remoteAddressBlocked: CoreL10n.text(
            "订阅地址指向本机或内网，已拒绝访问",
            "The subscription points to this Mac or a private network and was blocked"
        )
        case .responseTooLarge: CoreL10n.text("订阅内容过大", "The subscription response is too large")
        case .invalidRule: CoreL10n.text("规则格式无效", "The rule format is invalid")
        case .duplicateRule: CoreL10n.text("规则已存在", "The rule already exists")
        case .singBoxMissing: CoreL10n.text("缺少 sing-box 代理核心", "The sing-box core is missing")
        case let .portOccupied(port): CoreL10n.text("端口 \(port) 已被占用", "Port \(port) is already in use")
        case let .processFailed(message): message
        case let .invalidSetting(key): CoreL10n.text("设置项无效：\(key)", "Invalid setting: \(key)")
        }
    }
}

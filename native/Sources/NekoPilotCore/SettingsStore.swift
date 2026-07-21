import Foundation
import Darwin

public actor SettingsStore {
    public enum Key {
        public static let allowLAN = "allow_lan"
        public static let autoSelect = "auto_select"
        public static let showProtocol = "show_protocol"
        public static let skipSystemProxy = "skip_system_proxy"
        public static let proxyPort = "proxy_port"
        public static let directDNS = "direct_dns"
        public static let userAgent = "user_agent"
        public static let selectedNode = "selected_node"
        public static let delayHistory = "delay_history"
        public static let lastUpdateCheck = "github_release_update_last_check"
        public static let clashSecret = "clash_api_secret"
        public static let directRules = "rules_direct"
        public static let proxyRules = "rules_proxy"
    }

    public static let defaultProxyPort = 16_789
    public static let clashAPIPort = 19_191

    private let fileURL: URL
    private var values: [String: JSONValue]

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                values = try JSONValue.decodeObject(from: Data(contentsOf: fileURL))
            } catch {
                throw NekoPilotError.invalidSetting("preferences.json")
            }
        } else {
            values = [:]
        }
    }

    public func bool(_ key: String, default defaultValue: Bool = false) -> Bool {
        values[key]?.boolValue ?? defaultValue
    }

    public func string(_ key: String, default defaultValue: String = "") -> String {
        values[key]?.stringValue ?? defaultValue
    }

    public func integer(_ key: String, default defaultValue: Int) -> Int {
        guard let value = values[key]?.numberValue,
              value.isFinite,
              value.rounded() == value,
              value >= Double(Int.min), value <= Double(Int.max) else { return defaultValue }
        return Int(value)
    }

    public func value(_ key: String) -> JSONValue? { values[key] }

    public func set(_ value: JSONValue?, for key: String) throws {
        try validate(value, for: key)
        try commit {
            values[key] = value
            if value == nil { values.removeValue(forKey: key) }
        }
    }

    public func proxyPort() -> Int {
        let port = integer(Key.proxyPort, default: Self.defaultProxyPort)
        return (1 ... 65_535).contains(port) ? port : Self.defaultProxyPort
    }

    public func clashSecret() throws -> String {
        if let existing = values[Key.clashSecret]?.stringValue,
           (16 ... 256).contains(existing.count) {
            return existing
        }
        let secret = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try commit { values[Key.clashSecret] = .string(secret) }
        return secret
    }

    public func delayHistory() -> [String: DelayRecord] {
        guard let history = values[Key.delayHistory]?.objectValue else { return [:] }
        var result: [String: DelayRecord] = [:]
        for (node, raw) in history.prefix(2_000) {
            guard let entry = raw.objectValue,
                  let measured = entry["measuredAt"]?.numberValue else { continue }
            let delay: Int?
            if let numeric = entry["delay"]?.numberValue,
               numeric.isFinite,
               numeric >= Double(Int.min), numeric <= Double(Int.max) {
                delay = Int(numeric)
            } else {
                delay = nil
            }
            result[node] = DelayRecord(
                delay: delay,
                measuredAt: Date(timeIntervalSince1970: measured)
            )
        }
        return result
    }

    public func replaceDelayHistory(_ history: [String: DelayRecord]) throws {
        let entries = history.prefix(2_000).reduce(into: [String: JSONValue]()) { output, item in
            output[item.key] = .object([
                "delay": item.value.delay.map { .number(Double($0)) } ?? .string("-"),
                "measuredAt": .number(item.value.measuredAt.timeIntervalSince1970),
            ])
        }
        try commit { values[Key.delayHistory] = .object(entries) }
    }

    public func rules() -> [RoutingRule] {
        var result: [RoutingRule] = []
        for action in RuleAction.allCases {
            let key = action == .direct ? Key.directRules : Key.proxyRules
            guard let object = values[key]?.objectValue else { continue }
            for kind in RuleKind.allCases {
                let entries = object[kind.rawValue]?.arrayValue ?? []
                result.append(contentsOf: entries.compactMap(\.stringValue).map {
                    RoutingRule(action: action, kind: kind, value: $0)
                })
            }
        }
        return result
    }

    public func replaceRules(_ rules: [RoutingRule]) throws {
        try commit {
            for action in RuleAction.allCases {
                var object: [String: JSONValue] = [:]
                for kind in RuleKind.allCases {
                    let entries = Array(Set(rules
                        .filter { $0.action == action && $0.kind == kind }
                        .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }))
                        .sorted()
                        .map(JSONValue.string)
                    object[kind.rawValue] = .array(entries)
                }
                values[action == .direct ? Key.directRules : Key.proxyRules] = .object(object)
            }
        }
    }

    private func persist() throws {
        try AtomicFile.write(try JSONValue.encodeObject(values, pretty: true), to: fileURL)
    }

    private func commit(_ mutation: () throws -> Void) throws {
        let previous = values
        do {
            try mutation()
            try persist()
        } catch {
            values = previous
            throw error
        }
    }

    private func validate(_ value: JSONValue?, for key: String) throws {
        guard key.count <= 256 else { throw NekoPilotError.invalidSetting(key) }
        guard let value else { return }
        switch key {
        case Key.proxyPort:
            guard let number = value.numberValue,
                  number.isFinite,
                  number.rounded() == number,
                  number >= 1, number <= 65_535 else {
                throw NekoPilotError.invalidSetting(key)
            }
        case Key.lastUpdateCheck:
            guard let number = value.numberValue, number.isFinite, number >= 0 else {
                throw NekoPilotError.invalidSetting(key)
            }
        case Key.allowLAN, Key.autoSelect, Key.showProtocol, Key.skipSystemProxy:
            guard value.boolValue != nil else { throw NekoPilotError.invalidSetting(key) }
        case Key.selectedNode, Key.clashSecret:
            guard let string = value.stringValue, string.utf8.count <= 16 * 1024 else {
                throw NekoPilotError.invalidSetting(key)
            }
        case Key.directDNS:
            guard let string = value.stringValue,
                  string.utf8.count <= 64,
                  Self.isIPAddress(string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw NekoPilotError.invalidSetting(key)
            }
        case Key.userAgent:
            guard let string = value.stringValue,
                  !string.isEmpty,
                  string.utf8.count <= 512,
                  !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw NekoPilotError.invalidSetting(key)
            }
        default:
            let data = try JSONEncoder().encode(value)
            guard data.count <= 2 * 1024 * 1024 else { throw NekoPilotError.invalidSetting(key) }
        }
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return value.withCString {
            inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1
        }
    }
}

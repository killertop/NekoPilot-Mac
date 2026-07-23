import Foundation

/// Converts subscription response payloads into structurally valid sing-box
/// outbound configurations. This type is deliberately stateless: importing,
/// candidate validation, and persistence remain owned by `SubscriptionImporter`.
public enum SubscriptionPayloadParser {
    static let maximumPayloadBytes = 8 * 1024 * 1024
    private static let maximumOutbounds = 20_000
    private static let maximumTagBytes = 1_024
    private static let maximumTypeBytes = 64

    public static func parse(_ data: Data) throws -> [String: JSONValue] {
        guard data.count <= maximumPayloadBytes else { throw NekoPilotError.responseTooLarge }
        if let object = try? JSONValue.decodeObject(from: data), hasUsableNode(object) {
            return try validate(object)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw NekoPilotError.invalidSubscription
        }
        let candidates = [text, decodeBase64Text(text)].compactMap { $0 }
        for candidate in candidates {
            let links = candidate
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            var outbounds: [[String: JSONValue]] = []
            var seenTags = Set<String>()
            for link in links {
                guard let scheme = URLComponents(string: link)?.scheme?.lowercased(),
                      ProxyLinkParser.supportedSchemes.contains(scheme),
                      let config = try? ProxyLinkParser.parse(link),
                      let outbound = config["outbounds"]?.arrayValue?.first?.objectValue else { continue }
                var unique = outbound
                let baseTag = outbound["tag"]?.stringValue ?? CoreL10n.text("节点", "Node")
                var tag = baseTag
                var index = 2
                while !seenTags.insert(tag).inserted {
                    tag = "\(baseTag) (\(index))"
                    index += 1
                }
                unique["tag"] = .string(tag)
                outbounds.append(unique)
            }
            if !outbounds.isEmpty {
                return try validate([
                    "outbounds": .array(outbounds.map(JSONValue.object)),
                ])
            }
        }
        throw NekoPilotError.invalidSubscription
    }

    /// Performs deterministic structural checks that do not launch sing-box or
    /// touch persistent state. Full sing-box validation still belongs at the
    /// compiled configuration boundary, but malformed subscriptions must not be
    /// allowed to poison the shared node pool before reaching that boundary.
    @discardableResult
    public static func validate(
        _ object: [String: JSONValue]
    ) throws -> [String: JSONValue] {
        let encoded = try JSONValue.encodeObject(object)
        guard encoded.count <= maximumPayloadBytes,
              let outbounds = object["outbounds"]?.arrayValue,
              !outbounds.isEmpty,
              outbounds.count <= maximumOutbounds else {
            throw NekoPilotError.invalidSubscription
        }

        let ignored = Set(["selector", "urltest", "direct", "block", "dns"])
        let endpointTypes = Set([
            "vless", "trojan", "anytls", "hysteria", "hysteria2", "tuic", "vmess",
            "shadowsocks", "socks", "http", "ssh", "shadowtls", "naive",
        ])
        var seenTags = Set<String>()
        var usableNodes = 0
        for value in outbounds {
            guard let outbound = value.objectValue,
                  let type = outbound["type"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !type.isEmpty, type.utf8.count <= maximumTypeBytes else {
                throw NekoPilotError.invalidSubscription
            }
            if let tag = outbound["tag"]?.stringValue {
                let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty,
                      normalized.utf8.count <= maximumTagBytes,
                      seenTags.insert(tag).inserted else {
                    throw NekoPilotError.invalidSubscription
                }
            }
            if let server = outbound["server"] {
                guard let server = server.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !server.isEmpty, server.utf8.count <= 4_096 else {
                    throw NekoPilotError.invalidSubscription
                }
            }
            if let rawPort = outbound["server_port"] {
                guard let port = rawPort.numberValue,
                      port.isFinite, port.rounded() == port,
                      port >= 1, port <= 65_535 else {
                    throw NekoPilotError.invalidSubscription
                }
            }
            guard !ignored.contains(type) else { continue }
            guard let tag = outbound["tag"]?.stringValue, !tag.isEmpty else {
                throw NekoPilotError.invalidSubscription
            }
            if endpointTypes.contains(type) {
                guard outbound["server"]?.stringValue?.isEmpty == false,
                      let port = outbound["server_port"]?.numberValue,
                      port.isFinite, port.rounded() == port,
                      port >= 1, port <= 65_535 else {
                    throw NekoPilotError.invalidSubscription
                }
            }
            usableNodes += 1
        }
        guard usableNodes > 0 else { throw NekoPilotError.invalidSubscription }
        return object
    }

    private static func hasUsableNode(_ object: [String: JSONValue]) -> Bool {
        let ignored = Set(["selector", "urltest", "direct", "block", "dns"])
        return (object["outbounds"]?.arrayValue ?? []).contains {
            guard let outbound = $0.objectValue,
                  let type = outbound["type"]?.stringValue,
                  let tag = outbound["tag"]?.stringValue else { return false }
            return !ignored.contains(type) && !tag.isEmpty
        }
    }

    private static func decodeBase64Text(_ raw: String) -> String? {
        var normalized = raw
            .filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let data = Data(base64Encoded: normalized) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

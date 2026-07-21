import Foundation
import Darwin

public enum ProxyLinkParser {
    private static let maximumLinkBytes = 64 * 1024

    public static let supportedSchemes = Set([
        "vless", "trojan", "anytls", "hysteria2", "hy2", "tuic", "vmess", "ss",
    ])

    public static func parse(_ input: String) throws -> [String: JSONValue] {
        let link = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty,
              link.utf8.count <= maximumLinkBytes,
              let scheme = URLComponents(string: link)?.scheme?.lowercased(),
              supportedSchemes.contains(scheme) else {
            throw NekoPilotError.unsupportedProtocol
        }
        let outbound: [String: JSONValue]
        switch scheme {
        case "vless", "trojan": outbound = try parseVLESSOrTrojan(link, protocolName: scheme)
        case "anytls": outbound = try parseAnyTLS(link)
        case "hysteria2", "hy2": outbound = try parseHysteria2(link)
        case "tuic": outbound = try parseTUIC(link)
        case "vmess": outbound = try parseVMess(link)
        case "ss": outbound = try parseShadowsocks(link)
        default: throw NekoPilotError.unsupportedProtocol
        }
        return ["outbounds": .array([.object(outbound)])]
    }

    private static func parseVLESSOrTrojan(
        _ link: String,
        protocolName: String
    ) throws -> [String: JSONValue] {
        let parts = try parts(link, defaultPort: nil)
        guard !parts.user.isEmpty else { throw NekoPilotError.invalidLink }
        var outbound: [String: JSONValue] = [
            "type": .string(protocolName),
            "tag": .string(nodeTag(protocolName, label: parts.label, server: parts.host)),
            "server": .string(parts.host),
            "server_port": .number(Double(parts.port)),
        ]
        outbound[protocolName == "vless" ? "uuid" : "password"] = .string(parts.user)
        if let flow = parts.query["flow"], !flow.isEmpty { outbound["flow"] = .string(flow) }
        if protocolName == "vless",
           let packetEncoding = nonempty(parts.query["packetEncoding"] ?? parts.query["packet_encoding"]) {
            outbound["packet_encoding"] = .string(packetEncoding)
        }
        try addTLS(&outbound, query: parts.query, server: parts.host, defaultEnabled: protocolName == "trojan")
        addTransport(&outbound, query: parts.query)
        return outbound
    }

    private static func parseAnyTLS(_ link: String) throws -> [String: JSONValue] {
        let parts = try parts(link, defaultPort: 443)
        guard !parts.user.isEmpty else { throw NekoPilotError.invalidLink }
        var query = parts.query
        query["security"] = "tls"
        var outbound: [String: JSONValue] = [
            "type": .string("anytls"),
            "tag": .string(nodeTag("anytls", label: parts.label, server: parts.host)),
            "server": .string(parts.host),
            "server_port": .number(Double(parts.port)),
            "password": .string(parts.user),
        ]
        try addTLS(&outbound, query: query, server: parts.host, defaultEnabled: true)
        return outbound
    }

    private static func parseHysteria2(_ link: String) throws -> [String: JSONValue] {
        let parts = try parts(link, defaultPort: 443)
        guard !parts.user.isEmpty else { throw NekoPilotError.invalidLink }
        var outbound: [String: JSONValue] = [
            "type": .string("hysteria2"),
            "tag": .string(nodeTag("hysteria2", label: parts.label, server: parts.host)),
            "server": .string(parts.host),
            "server_port": .number(Double(parts.port)),
            "password": .string(parts.user),
        ]
        if let obfs = parts.query["obfs"], !obfs.isEmpty {
            var obfsObject: [String: JSONValue] = ["type": .string(obfs)]
            if let password = parts.query["obfs-password"] ?? parts.query["obfsPassword"] {
                obfsObject["password"] = .string(password)
            }
            outbound["obfs"] = .object(obfsObject)
        }
        var query = parts.query
        query["security"] = "tls"
        try addTLS(&outbound, query: query, server: parts.host, defaultEnabled: true)
        return outbound
    }

    private static func parseTUIC(_ link: String) throws -> [String: JSONValue] {
        guard let components = URLComponents(string: link),
              let host = components.host,
              !host.isEmpty,
              let port = validatedPort(components.port),
              let user = components.user?.removingPercentEncoding,
              let password = components.password?.removingPercentEncoding,
              !user.isEmpty, !password.isEmpty else { throw NekoPilotError.invalidLink }
        let query = queryItems(components)
        let label = components.fragment?.removingPercentEncoding
        var outbound: [String: JSONValue] = [
            "type": .string("tuic"),
            "tag": .string(nodeTag("tuic", label: label, server: host)),
            "server": .string(host),
            "server_port": .number(Double(port)),
            "uuid": .string(user),
            "password": .string(password),
            "congestion_control": .string(
                nonempty(query["congestion_control"] ?? query["congestion-control"]) ?? "bbr"
            ),
        ]
        var tlsQuery = query
        tlsQuery["security"] = "tls"
        try addTLS(&outbound, query: tlsQuery, server: host, defaultEnabled: true)
        return outbound
    }

    private static func parseVMess(_ link: String) throws -> [String: JSONValue] {
        let encoded = String(link.dropFirst("vmess://".count))
        guard encoded.utf8.count <= maximumLinkBytes,
              let data = decodeBase64(encoded),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = nonempty(string(raw["add"])),
              let port = validatedPort(int(raw["port"])),
              let uuid = nonempty(string(raw["id"])),
              !host.isEmpty, !uuid.isEmpty else { throw NekoPilotError.invalidLink }
        let label = nonempty(string(raw["ps"]))
        var outbound: [String: JSONValue] = [
            "type": .string("vmess"),
            "tag": .string(nodeTag("vmess", label: label, server: host)),
            "server": .string(host),
            "server_port": .number(Double(port)),
            "uuid": .string(uuid),
            "security": .string(string(raw["scy"]) ?? "auto"),
            "alter_id": .number(Double(int(raw["aid"]) ?? 0)),
        ]
        var query: [String: String] = [:]
        if let network = nonempty(string(raw["net"])) { query["type"] = network }
        if let path = nonempty(string(raw["path"])) { query["path"] = path }
        if let hostHeader = nonempty(string(raw["host"])) { query["host"] = hostHeader }
        if let sni = nonempty(string(raw["sni"])) { query["sni"] = sni }
        if nonempty(string(raw["tls"]))?.lowercased() == "tls" { query["security"] = "tls" }
        if let fingerprint = nonempty(string(raw["fp"])) { query["fp"] = fingerprint }
        if let alpn = nonempty(string(raw["alpn"])) { query["alpn"] = alpn }
        if let insecure = nonempty(string(raw["insecure"] ?? raw["allowInsecure"])) {
            query["insecure"] = insecure
        }
        try addTLS(&outbound, query: query, server: host, defaultEnabled: false)
        addTransport(&outbound, query: query)
        return outbound
    }

    private static func parseShadowsocks(_ link: String) throws -> [String: JSONValue] {
        guard var components = URLComponents(string: link),
              components.queryItems?.first(where: { $0.name == "plugin" }) == nil else {
            throw NekoPilotError.unsupportedProtocol
        }
        let label = components.fragment?.removingPercentEncoding
        components.fragment = nil
        var host = components.host
        var port = components.port
        var credential = (components.percentEncodedUser ?? "").removingPercentEncoding ?? components.user ?? ""
        if let encodedPassword = components.percentEncodedPassword,
           let password = encodedPassword.removingPercentEncoding,
           !credential.isEmpty, !password.isEmpty {
            credential += ":\(password)"
        }
        if let decoded = decodeBase64String(credential), decoded.contains(":") {
            credential = decoded
        }
        if host == nil || port == nil {
            let payload = String(link.dropFirst("ss://".count)).split(separator: "#", maxSplits: 1)[0]
            guard let decoded = decodeBase64String(String(payload)),
                  let at = decoded.lastIndex(of: "@") else { throw NekoPilotError.invalidLink }
            credential = String(decoded[..<at])
            let address = String(decoded[decoded.index(after: at)...])
            guard let colon = address.lastIndex(of: ":") else { throw NekoPilotError.invalidLink }
            host = String(address[..<colon])
            port = Int(address[address.index(after: colon)...])
        }
        guard let host, !host.isEmpty,
              let port = validatedPort(port),
              let separator = credential.firstIndex(of: ":") else { throw NekoPilotError.invalidLink }
        let method = String(credential[..<separator])
        let password = String(credential[credential.index(after: separator)...])
        guard !method.isEmpty, !password.isEmpty else { throw NekoPilotError.invalidLink }
        return [
            "type": .string("shadowsocks"),
            "tag": .string(nodeTag("shadowsocks", label: label, server: host)),
            "server": .string(host),
            "server_port": .number(Double(port)),
            "method": .string(method),
            "password": .string(password),
        ]
    }

    private struct Parts {
        let host: String
        let port: Int
        let user: String
        let label: String?
        let query: [String: String]
    }

    private static func parts(_ link: String, defaultPort: Int?) throws -> Parts {
        guard let components = URLComponents(string: link),
              let host = components.host,
              !host.isEmpty,
              let port = validatedPort(components.port ?? defaultPort),
              let encodedUser = components.percentEncodedUser,
              let user = encodedUser.removingPercentEncoding else { throw NekoPilotError.invalidLink }
        return Parts(
            host: host,
            port: port,
            user: user,
            label: components.fragment?.removingPercentEncoding,
            query: queryItems(components)
        )
    }

    private static func queryItems(_ components: URLComponents) -> [String: String] {
        (components.queryItems ?? []).reduce(into: [:]) { output, item in
            output[item.name] = item.value ?? ""
        }
    }

    private static func addTLS(
        _ outbound: inout [String: JSONValue],
        query: [String: String],
        server: String,
        defaultEnabled: Bool
    ) throws {
        let security = (nonempty(query["security"]) ?? (defaultEnabled ? "tls" : "none")).lowercased()
        guard security == "tls" || security == "reality" else { return }
        var tls: [String: JSONValue] = ["enabled": .bool(true)]
        let serverName = nonempty(query["sni"]) ?? server
        if !isIPAddress(serverName) { tls["server_name"] = .string(serverName) }
        if ["1", "true"].contains((query["insecure"] ?? query["allowInsecure"] ?? "").lowercased()) {
            tls["insecure"] = .bool(true)
        }
        if let alpn = query["alpn"] {
            let values = alpn
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map(JSONValue.string)
            if !values.isEmpty { tls["alpn"] = .array(values) }
        }
        if let fingerprint = query["fp"], !fingerprint.isEmpty {
            tls["utls"] = .object(["enabled": .bool(true), "fingerprint": .string(fingerprint)])
        }
        if security == "reality" {
            guard let publicKey = nonempty(query["pbk"]) else { throw NekoPilotError.invalidLink }
            var reality: [String: JSONValue] = ["enabled": .bool(true), "public_key": .string(publicKey)]
            if let shortID = nonempty(query["sid"]) { reality["short_id"] = .string(shortID) }
            tls["reality"] = .object(reality)
        }
        outbound["tls"] = .object(tls)
    }

    private static func addTransport(
        _ outbound: inout [String: JSONValue],
        query: [String: String]
    ) {
        let type = (query["type"] ?? "tcp").lowercased()
        switch type {
        case "ws", "websocket":
            var transport: [String: JSONValue] = [
                "type": .string("ws"), "path": .string(nonempty(query["path"]) ?? "/"),
            ]
            if let host = query["host"]?.split(separator: ",").first {
                let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalizedHost.isEmpty {
                    transport["headers"] = .object(["Host": .string(normalizedHost)])
                }
            }
            outbound["transport"] = .object(transport)
        case "grpc":
            outbound["transport"] = .object([
                "type": .string("grpc"),
                "service_name": .string(query["serviceName"] ?? query["service_name"] ?? ""),
            ])
        case "httpupgrade":
            outbound["transport"] = .object([
                "type": .string("httpupgrade"),
                "path": .string(nonempty(query["path"]) ?? "/"),
                "host": .string(nonempty(query["host"]) ?? ""),
            ])
        default: break
        }
    }

    private static func nodeTag(_ protocolName: String, label: String?, server: String) -> String {
        let display = nonempty(label) ?? server
        return "\(protocolName.uppercased()) · \(display.prefix(96))"
    }

    private static func decodeBase64String(_ input: String) -> String? {
        guard let data = decodeBase64(input) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeBase64(_ input: String) -> Data? {
        var normalized = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .filter { !$0.isWhitespace }
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        return Data(base64Encoded: normalized)
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func nonempty(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func validatedPort(_ port: Int?) -> Int? {
        guard let port, (1 ... 65_535).contains(port) else { return nil }
        return port
    }

    private static func isIPAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return host.withCString {
            inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

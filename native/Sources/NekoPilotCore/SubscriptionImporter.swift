import Foundation
import Darwin
import Network
import Security

public typealias SubscriptionCandidateValidator = @Sendable ([String: JSONValue]) async throws -> Void

public enum SubscriptionReplacement: Sendable, Equatable {
    case renamed
    case contentChanged
}

public actor SubscriptionImporter {
    private static let maximumResponseBytes = 8 * 1024 * 1024
    private static let maximumURLBytes = 16 * 1024
    private static let maximumOutbounds = 20_000
    private static let maximumTagBytes = 1_024
    private static let maximumTypeBytes = 64
    private let repository: SubscriptionRepository
    private let settings: SettingsStore?
    private let candidateValidator: SubscriptionCandidateValidator

    public init(
        repository: SubscriptionRepository,
        settings: SettingsStore? = nil,
        candidateValidator: SubscriptionCandidateValidator? = nil
    ) {
        self.repository = repository
        self.settings = settings
        if let candidateValidator {
            self.candidateValidator = candidateValidator
        } else {
            self.candidateValidator = { config in
                try await Self.validateCandidateWithSingBox(config)
            }
        }
    }

    @discardableResult
    public func importInput(_ rawInput: String, name: String? = nil) async throws -> String {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw NekoPilotError.invalidLink }
        if let scheme = URLComponents(string: input)?.scheme?.lowercased(),
           ProxyLinkParser.supportedSchemes.contains(scheme) {
            let config = try Self.validateConfiguration(ProxyLinkParser.parse(input))
            let nodeName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = config["outbounds"]?.arrayValue?.first?["tag"]?.stringValue ?? "本地节点"
            let resolvedName = nodeName.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            try await candidateValidator(config)
            return try await repository.upsert(
                url: input,
                name: resolvedName,
                sourceType: .localLink,
                config: config
            )
        }

        guard let url = URL(string: input), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw NekoPilotError.invalidLink
        }
        let config = try await fetchConfiguration(from: url)
        let displayName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = displayName.flatMap { $0.isEmpty ? nil : $0 } ?? (url.host ?? "机场订阅")
        try await candidateValidator(config)
        return try await repository.upsert(
            url: url.absoluteString,
            name: resolvedName,
            sourceType: .subscription,
            config: config
        )
    }

    @discardableResult
    public func replace(identifier: String, rawInput: String, name: String) async throws -> SubscriptionReplacement {
        guard let existing = try await repository.subscription(identifier: identifier) else {
            throw NekoPilotError.invalidLink
        }
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !resolvedName.isEmpty else { throw NekoPilotError.invalidLink }

        // A display-name edit must remain local and instantaneous. Re-fetching
        // and validating an unchanged subscription URL made a simple rename
        // depend on the airport's availability and unnecessarily reloaded the
        // running proxy engine.
        if input == existing.subscriptionURL {
            try await repository.rename(identifier: identifier, name: resolvedName)
            return .renamed
        }

        let config: [String: JSONValue]
        let sourceURL: String
        switch existing.sourceType {
        case .localLink:
            guard let scheme = URLComponents(string: input)?.scheme?.lowercased(),
                  ProxyLinkParser.supportedSchemes.contains(scheme) else {
                throw NekoPilotError.invalidLink
            }
            config = try Self.validateConfiguration(ProxyLinkParser.parse(input))
            sourceURL = input
        case .subscription:
            guard let url = URL(string: input),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw NekoPilotError.invalidLink
            }
            config = try await fetchConfiguration(from: url)
            sourceURL = url.absoluteString
        }

        try await candidateValidator(config)
        _ = try await repository.upsert(
            url: sourceURL,
            name: resolvedName,
            sourceType: existing.sourceType,
            config: config,
            identifier: identifier
        )
        return .contentChanged
    }

    public func refresh(identifier: String) async throws {
        guard let subscription = try await repository.subscription(identifier: identifier),
              subscription.sourceType == .subscription,
              let rawURL = subscription.subscriptionURL,
              let url = URL(string: rawURL) else { throw NekoPilotError.invalidLink }
        let config = try await fetchConfiguration(from: url)
        try await candidateValidator(config)
        _ = try await repository.upsert(
            url: rawURL,
            name: subscription.name,
            sourceType: .subscription,
            config: config,
            identifier: identifier
        )
    }

    public func fetchConfiguration(from url: URL) async throws -> [String: JSONValue] {
        guard url.absoluteString.utf8.count <= Self.maximumURLBytes else {
            throw NekoPilotError.invalidLink
        }
        let configuredUserAgent = await settings?.string(SettingsStore.Key.userAgent)
        let userAgent = Self.validUserAgent(configuredUserAgent) ?? "sing-box 1.14.0-alpha.26"
        let data = try await PinnedHTTPClient.fetch(
            url: url,
            maximumBodyBytes: Self.maximumResponseBytes,
            maximumURLBytes: Self.maximumURLBytes,
            userAgent: userAgent
        )
        return try Self.parsePayload(data)
    }

    public static func parsePayload(_ data: Data) throws -> [String: JSONValue] {
        guard data.count <= maximumResponseBytes else { throw NekoPilotError.responseTooLarge }
        if let object = try? JSONValue.decodeObject(from: data), hasUsableNode(object) {
            return try validateConfiguration(object)
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
                let baseTag = outbound["tag"]?.stringValue ?? "节点"
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
                return try validateConfiguration([
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
    public static func validateConfiguration(
        _ object: [String: JSONValue]
    ) throws -> [String: JSONValue] {
        let encoded = try JSONValue.encodeObject(object)
        guard encoded.count <= maximumResponseBytes,
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

    private static func validUserAgent(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value != "default",
              value.utf8.count <= 512,
              !value.contains("\r"), !value.contains("\n") else { return nil }
        return value
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

    private static func validateCandidateWithSingBox(
        _ config: [String: JSONValue]
    ) async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("NekoPilot-Candidate-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let logs = root.appendingPathComponent("Logs", isDirectory: true)
        let paths = AppPaths(applicationSupport: support, logs: logs)
        let isolatedSettings = try SettingsStore(fileURL: paths.settings)
        let isolatedRepository = try SubscriptionRepository(databaseURL: paths.database)
        _ = try await isolatedRepository.upsert(
            url: nil,
            name: "Candidate",
            sourceType: .localLink,
            config: config
        )
        guard let selectedNode = try await isolatedRepository.nodes().first?.runtimeTag else {
            throw NekoPilotError.invalidSubscription
        }
        let compiler = ConfigurationCompiler(
            paths: paths,
            settings: isolatedSettings,
            repository: isolatedRepository
        )
        let fullConfiguration = try await compiler.compile(selectedNode: selectedNode)
        try await SingBoxValidator.validate(configuration: fullConfiguration)
    }
}

struct ResolvedPublicEndpoint: Sendable, Equatable {
    let address: String
    let serverName: String
    let port: UInt16
    let useTLS: Bool
}

enum NetworkAddressPolicy {
    static func isPublic(url: URL) -> Bool {
        (try? resolvePublicEndpoint(url: url)) != nil
    }

    static func resolvePublicEndpoint(url: URL) throws -> ResolvedPublicEndpoint {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.user == nil, url.password == nil,
              let rawHost = url.host?.lowercased(),
              !rawHost.isEmpty else { throw NekoPilotError.remoteAddressBlocked }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let portValue = url.port ?? (scheme == "https" ? 443 : 80)
        guard !host.isEmpty, host.utf8.count <= 253,
              host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local"),
              (1 ... 65_535).contains(portValue) else {
            throw NekoPilotError.remoteAddressBlocked
        }

        let addresses = resolvedAddresses(host: host).filter { isPublicAddress($0.data) }
        guard let selected = addresses.first(where: { $0.data.count == 4 }) ?? addresses.first else {
            throw NekoPilotError.remoteAddressBlocked
        }
        return ResolvedPublicEndpoint(
            address: selected.numericHost,
            serverName: host,
            port: UInt16(portValue),
            useTLS: scheme == "https"
        )
    }

    struct ResolvedAddress: Sendable, Equatable {
        let numericHost: String
        let data: Data
    }

    static func resolvedAddresses(host: String) -> [ResolvedAddress] {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0 else { return [] }
        defer { freeaddrinfo(result) }
        var addresses: [ResolvedAddress] = []
        var seen = Set<String>()
        var cursor = result
        while let current = cursor {
            let family = current.pointee.ai_family
            let data: Data?
            if family == AF_INET {
                data = current.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    Data(bytes: &$0.pointee.sin_addr, count: MemoryLayout<in_addr>.size)
                }
            } else if family == AF_INET6 {
                data = current.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    Data(bytes: &$0.pointee.sin6_addr, count: MemoryLayout<in6_addr>.size)
                }
            } else {
                data = nil
            }
            if let data {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    current.pointee.ai_addr,
                    current.pointee.ai_addrlen,
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    let numericHost = String(cString: buffer)
                    if seen.insert(numericHost).inserted {
                        addresses.append(ResolvedAddress(numericHost: numericHost, data: data))
                    }
                }
            }
            cursor = current.pointee.ai_next
        }
        return addresses
    }

    static func isPublicAddress(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        if bytes.count == 4 {
            let a = bytes[0], b = bytes[1], c = bytes[2], d = bytes[3]
            if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
            if a == 100 && (64 ... 127).contains(b) { return false }
            if a == 169 && b == 254 { return false }
            if a == 172 && (16 ... 31).contains(b) { return false }
            if a == 192 && b == 168 { return false }
            if a == 192 && b == 0 && (c == 0 || c == 2) { return false }
            if a == 192 && b == 88 && c == 99 { return false }
            if a == 198 && (b == 18 || b == 19) { return false }
            if a == 198 && b == 51 && c == 100 { return false }
            if a == 203 && b == 0 && c == 113 { return false }
            if a == 168 && b == 63 && c == 129 && d == 16 { return false }
            return true
        }
        guard bytes.count == 16 else { return false }
        if Array(bytes.prefix(12)) == [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF] {
            return isPublicAddress(Data(bytes.suffix(4)))
        }
        // Restrict subscriptions to currently globally-routable IPv6 unicast
        // space (2000::/3), then remove documentation, benchmarking/ORCHID and
        // 6to4 ranges that can embed non-public destinations.
        guard bytes[0] & 0xE0 == 0x20 else { return false }
        if Array(bytes.prefix(4)) == [0x20, 0x01, 0x00, 0x00] { return false }
        if Array(bytes.prefix(4)) == [0x20, 0x01, 0x0D, 0xB8] { return false }
        if Array(bytes.prefix(4)) == [0x20, 0x01, 0x00, 0x02] { return false }
        if Array(bytes.prefix(4)) == [0x20, 0x01, 0x00, 0x10] { return false }
        if Array(bytes.prefix(3)) == [0x20, 0x01, 0x00], bytes[3] & 0xF0 == 0x20 { return false }
        if Array(bytes.prefix(2)) == [0x20, 0x02] { return false }
        if Array(bytes.prefix(2)) == [0x3F, 0xFF], bytes[2] & 0xF0 == 0 { return false }
        return true
    }
}

struct PinnedHTTPResponse: Sendable, Equatable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

enum HTTPWireResponseParser {
    private static let headerDelimiter = Data("\r\n\r\n".utf8)
    private static let lineDelimiter = Data("\r\n".utf8)
    private static let maximumHeaderBytes = 64 * 1024

    static func parse(
        _ data: Data,
        streamComplete: Bool,
        maximumBodyBytes: Int
    ) throws -> PinnedHTTPResponse? {
        guard let delimiter = data.range(of: headerDelimiter) else {
            if data.count > maximumHeaderBytes { throw NekoPilotError.responseTooLarge }
            if streamComplete { throw NekoPilotError.processFailed("订阅响应无效") }
            return nil
        }
        guard delimiter.lowerBound <= maximumHeaderBytes,
              let rawHead = String(data: data[..<delimiter.lowerBound], encoding: .isoLatin1) else {
            throw NekoPilotError.processFailed("订阅响应头无效")
        }
        let lines = rawHead.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw NekoPilotError.processFailed("订阅响应无效") }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2,
              statusParts[0].hasPrefix("HTTP/1."),
              let statusCode = Int(statusParts[1]) else {
            throw NekoPilotError.processFailed("订阅响应状态无效")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                throw NekoPilotError.processFailed("订阅响应头无效")
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw NekoPilotError.processFailed("订阅响应头无效") }
            headers[name] = headers[name].map { "\($0),\(value)" } ?? value
        }

        // Redirect and error responses do not need their bodies. Returning as
        // soon as the bounded header arrives also prevents a redirect endpoint
        // from wasting memory with an oversized response body.
        if !(200 ... 299).contains(statusCode) {
            return PinnedHTTPResponse(statusCode: statusCode, headers: headers, body: Data())
        }
        if let encoding = headers["content-encoding"]?.lowercased(),
           !encoding.isEmpty, encoding != "identity" {
            throw NekoPilotError.processFailed("订阅响应压缩格式不受支持")
        }

        let bodyStart = delimiter.upperBound
        let transferCodings = headers["transfer-encoding"]?
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        guard transferCodings.isEmpty || transferCodings == ["chunked"] else {
            throw NekoPilotError.processFailed("订阅响应传输格式不受支持")
        }
        let chunked = transferCodings == ["chunked"]
        if chunked, headers["content-length"] != nil {
            throw NekoPilotError.processFailed("订阅响应长度冲突")
        }
        if chunked {
            // We explicitly request `Connection: close`. Waiting for the end of
            // the bounded wire response avoids reparsing and recopying every
            // preceding chunk on each 64 KiB receive callback.
            guard streamComplete else { return nil }
            return try decodeChunked(
                Data(data[bodyStart...]),
                statusCode: statusCode,
                headers: headers,
                maximumBodyBytes: maximumBodyBytes,
                streamComplete: streamComplete
            )
        }
        let availableBody = data[bodyStart...]
        if let rawLength = headers["content-length"] {
            guard let length = Int(rawLength), length >= 0 else {
                throw NekoPilotError.processFailed("订阅响应长度无效")
            }
            guard length <= maximumBodyBytes else { throw NekoPilotError.responseTooLarge }
            guard availableBody.count >= length else {
                if streamComplete { throw NekoPilotError.processFailed("订阅响应提前结束") }
                return nil
            }
            return PinnedHTTPResponse(
                statusCode: statusCode,
                headers: headers,
                body: Data(availableBody.prefix(length))
            )
        }
        guard availableBody.count <= maximumBodyBytes else { throw NekoPilotError.responseTooLarge }
        guard streamComplete else { return nil }
        return PinnedHTTPResponse(statusCode: statusCode, headers: headers, body: Data(availableBody))
    }

    private static func decodeChunked(
        _ encoded: Data,
        statusCode: Int,
        headers: [String: String],
        maximumBodyBytes: Int,
        streamComplete: Bool
    ) throws -> PinnedHTTPResponse? {
        var cursor = encoded.startIndex
        var decoded = Data()
        while true {
            guard let lineRange = encoded.range(of: lineDelimiter, in: cursor ..< encoded.endIndex) else {
                if streamComplete { throw NekoPilotError.processFailed("订阅分块响应无效") }
                return nil
            }
            guard let sizeLine = String(data: encoded[cursor ..< lineRange.lowerBound], encoding: .ascii),
                  let rawSize = sizeLine.split(separator: ";", maxSplits: 1).first,
                  let size = Int(rawSize.trimmingCharacters(in: .whitespaces), radix: 16),
                  size >= 0 else {
                throw NekoPilotError.processFailed("订阅分块响应无效")
            }
            cursor = lineRange.upperBound
            if size == 0 {
                if encoded.distance(from: cursor, to: encoded.endIndex) >= 2,
                   encoded[cursor ..< encoded.index(cursor, offsetBy: 2)] == lineDelimiter {
                    return PinnedHTTPResponse(statusCode: statusCode, headers: headers, body: decoded)
                }
                guard encoded.range(of: headerDelimiter, in: cursor ..< encoded.endIndex) != nil else {
                    if streamComplete { throw NekoPilotError.processFailed("订阅分块响应无效") }
                    return nil
                }
                return PinnedHTTPResponse(statusCode: statusCode, headers: headers, body: decoded)
            }
            guard decoded.count <= maximumBodyBytes - min(size, maximumBodyBytes + 1) else {
                throw NekoPilotError.responseTooLarge
            }
            guard encoded.distance(from: cursor, to: encoded.endIndex) >= size + 2 else {
                if streamComplete { throw NekoPilotError.processFailed("订阅分块响应提前结束") }
                return nil
            }
            let end = encoded.index(cursor, offsetBy: size)
            guard encoded[end ..< encoded.index(end, offsetBy: 2)] == lineDelimiter else {
                throw NekoPilotError.processFailed("订阅分块响应无效")
            }
            decoded.append(encoded[cursor ..< end])
            cursor = encoded.index(end, offsetBy: 2)
        }
    }
}

enum PinnedHTTPClient {
    private static let maximumRedirects = 5
    private static let timeoutNanoseconds: UInt64 = 30_000_000_000
    private static let receiveChunkBytes = 64 * 1024
    private static let wireOverheadBytes = 1024 * 1024
    private static let queue = DispatchQueue(label: "dev.nekopilot.subscription-http", qos: .utility)

    static func fetch(
        url: URL,
        maximumBodyBytes: Int,
        maximumURLBytes: Int,
        userAgent: String
    ) async throws -> Data {
        var current = url
        var visited = Set<String>()
        for redirectCount in 0 ... maximumRedirects {
            guard current.absoluteString.utf8.count <= maximumURLBytes,
                  visited.insert(current.absoluteString).inserted else {
                throw NekoPilotError.invalidLink
            }
            let endpoint = try NetworkAddressPolicy.resolvePublicEndpoint(url: current)
            let response = try await requestWithTimeout(
                url: current,
                endpoint: endpoint,
                maximumBodyBytes: maximumBodyBytes,
                userAgent: userAgent
            )
            if (300 ... 399).contains(response.statusCode) {
                guard redirectCount < maximumRedirects,
                      let location = response.headers["location"],
                      let redirected = URL(string: location, relativeTo: current)?.absoluteURL,
                      ["http", "https"].contains(redirected.scheme?.lowercased() ?? "") else {
                    throw NekoPilotError.processFailed("订阅重定向无效")
                }
                if current.scheme?.lowercased() == "https", redirected.scheme?.lowercased() != "https" {
                    throw NekoPilotError.processFailed("订阅重定向不允许降低安全级别")
                }
                current = redirected
                continue
            }
            guard (200 ... 299).contains(response.statusCode) else {
                throw NekoPilotError.processFailed("订阅下载失败")
            }
            return response.body
        }
        throw NekoPilotError.processFailed("订阅重定向次数过多")
    }

    private static func requestWithTimeout(
        url: URL,
        endpoint: ResolvedPublicEndpoint,
        maximumBodyBytes: Int,
        userAgent: String
    ) async throws -> PinnedHTTPResponse {
        try await withThrowingTaskGroup(of: PinnedHTTPResponse.self) { group in
            group.addTask {
                try await request(
                    url: url,
                    endpoint: endpoint,
                    maximumBodyBytes: maximumBodyBytes,
                    userAgent: userAgent
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw NekoPilotError.processFailed("订阅下载超时")
            }
            guard let first = try await group.next() else {
                throw NekoPilotError.processFailed("订阅下载失败")
            }
            group.cancelAll()
            return first
        }
    }

    private static func request(
        url: URL,
        endpoint: ResolvedPublicEndpoint,
        maximumBodyBytes: Int,
        userAgent: String
    ) async throws -> PinnedHTTPResponse {
        let parameters: NWParameters
        if endpoint.useTLS {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, endpoint.serverName)
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            parameters = .tcp
        }
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw NekoPilotError.remoteAddressBlocked
        }
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.address), port: port, using: parameters)
        return try await withTaskCancellationHandler(operation: {
            defer { connection.cancel() }
            try await start(connection)
            try await send(requestBytes(url: url, endpoint: endpoint, userAgent: userAgent), on: connection)
            var buffer = Data()
            let maximumWireBytes = maximumBodyBytes + wireOverheadBytes
            while true {
                let received = try await receive(on: connection)
                buffer.append(received.data)
                guard buffer.count <= maximumWireBytes else { throw NekoPilotError.responseTooLarge }
                if let response = try HTTPWireResponseParser.parse(
                    buffer,
                    streamComplete: received.complete,
                    maximumBodyBytes: maximumBodyBytes
                ) {
                    return response
                }
                if received.complete { throw NekoPilotError.processFailed("订阅响应提前结束") }
            }
        }, onCancel: {
            connection.cancel()
        })
    }

    private static func requestBytes(
        url: URL,
        endpoint: ResolvedPublicEndpoint,
        userAgent: String
    ) -> Data {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let encodedPath = components?.percentEncodedPath ?? ""
        let target = (encodedPath.isEmpty ? "/" : encodedPath) +
            (components?.percentEncodedQuery).map { "?\($0)" }.orEmpty
        let defaultPort: UInt16 = endpoint.useTLS ? 443 : 80
        let host = endpoint.serverName.contains(":") ? "[\(endpoint.serverName)]" : endpoint.serverName
        let authority = endpoint.port == defaultPort ? host : "\(host):\(endpoint.port)"
        let request = "GET \(target) HTTP/1.1\r\n" +
            "Host: \(authority)\r\n" +
            "User-Agent: \(userAgent)\r\n" +
            "Accept: application/json,text/plain,*/*\r\n" +
            "Accept-Encoding: identity\r\n" +
            "Connection: close\r\n\r\n"
        return Data(request.utf8)
    }

    private static func start(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = VoidContinuationGate(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.resume()
                case let .failed(error): gate.resume(throwing: error)
                case .cancelled: gate.resume(throwing: CancellationError())
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private struct ReceivedChunk: Sendable {
        let data: Data
        let complete: Bool
    }

    private static func receive(on connection: NWConnection) async throws -> ReceivedChunk {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: receiveChunkBytes) {
                data, _, complete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ReceivedChunk(data: data ?? Data(), complete: complete))
                }
            }
        }
    }
}

private final class VoidContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume() {
        take()?.resume()
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let value = continuation
        continuation = nil
        return value
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

import Foundation

public struct ClashSelector: Sendable, Equatable {
    public let current: String
    public let nodes: [String]
}

public actor ClashAPIClient {
    private let session: URLSession
    private let settings: SettingsStore?
    private let controllerPort: Int
    private let fixedSecret: String?

    public init(settings: SettingsStore) {
        self.settings = settings
        controllerPort = SettingsStore.clashAPIPort
        fixedSecret = nil
        session = Self.makeSession()
    }

    public init(controllerPort: Int, secret: String) {
        settings = nil
        self.controllerPort = controllerPort
        fixedSecret = secret
        session = Self.makeSession()
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }

    public func isReady() async -> Bool {
        do {
            let (_, response) = try await request(path: "/version")
            return (200 ... 299).contains(response.statusCode)
        } catch {
            return false
        }
    }

    public func selector() async throws -> ClashSelector {
        let (data, response) = try await request(path: "/proxies/ExitGateway")
        guard response.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = object["now"] as? String,
              let nodes = object["all"] as? [String] else {
            throw NekoPilotError.processFailed("无法读取当前节点")
        }
        return ClashSelector(current: current, nodes: nodes)
    }

    public func select(node: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["name": node])
        let (_, response) = try await request(path: "/proxies/ExitGateway", method: "PUT", body: body)
        guard (200 ... 299).contains(response.statusCode) else {
            throw NekoPilotError.processFailed("节点切换失败")
        }
    }

    public func delay(
        node: String,
        testURL: String = "https://www.google.com/generate_204",
        timeoutMilliseconds: Int = 5_000
    ) async -> Int? {
        guard let path = Self.delayRequestPath(
            node: node,
            testURL: testURL,
            timeoutMilliseconds: timeoutMilliseconds
        ) else { return nil }
        do {
            let (data, response) = try await request(path: path)
            guard response.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let delay = object["delay"] as? NSNumber else { return nil }
            return delay.intValue
        } catch {
            return nil
        }
    }

    static func delayRequestPath(
        node: String,
        testURL: String,
        timeoutMilliseconds: Int
    ) -> String? {
        // A proxy name is one path *segment*. URLComponents.path deliberately
        // preserves '/', which turns names such as "HK/US" into two segments
        // and makes the Clash endpoint return 404. Encode the segment first,
        // then assign it as percentEncodedPath so %2F remains intact.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encodedNode = node.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        var components = URLComponents()
        components.percentEncodedPath = "/proxies/\(encodedNode)/delay"
        components.queryItems = [
            URLQueryItem(name: "url", value: testURL),
            URLQueryItem(name: "timeout", value: String(timeoutMilliseconds)),
        ]
        return components.string
    }

    public func hasLongLivedConnection(minimumAge: TimeInterval = 60) async -> Bool? {
        do {
            let (data, response) = try await request(path: "/connections")
            guard response.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let connections = object["connections"] as? [[String: Any]] else { return nil }
            let now = Date()
            return connections.contains { connection in
                guard let raw = connection["start"] else { return false }
                let start: Date?
                if let value = raw as? NSNumber {
                    let seconds = value.doubleValue > 10_000_000_000 ? value.doubleValue / 1_000 : value.doubleValue
                    start = Date(timeIntervalSince1970: seconds)
                } else if let value = raw as? String {
                    start = ISO8601DateFormatter().date(from: value)
                } else {
                    start = nil
                }
                return start.map { now.timeIntervalSince($0) >= minimumAge } ?? false
            }
        } catch {
            return nil
        }
    }

    public func trafficStream() -> AsyncThrowingStream<TrafficSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let secret = try await controllerSecret()
                    let url = URL(string: "http://127.0.0.1:\(controllerPort)/traffic")!
                    var request = URLRequest(url: url)
                    request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw NekoPilotError.processFailed("流量接口不可用")
                    }
                    for try await line in bytes.lines {
                        guard !Task.isCancelled,
                              let data = line.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let up = object["up"] as? NSNumber,
                              let down = object["down"] as? NSNumber else { continue }
                        continuation.yield(TrafficSnapshot(upload: up.int64Value, download: down.int64Value))
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

    private func request(
        path: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let secret = try await controllerSecret()
        guard let url = URL(string: "http://127.0.0.1:\(controllerPort)\(path)") else {
            throw NekoPilotError.processFailed("控制接口地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw NekoPilotError.processFailed("控制接口响应无效")
        }
        return (data, response)
    }

    private func controllerSecret() async throws -> String {
        if let fixedSecret { return fixedSecret }
        guard let settings else { throw NekoPilotError.invalidSetting(SettingsStore.Key.clashSecret) }
        return try await settings.clashSecret()
    }
}

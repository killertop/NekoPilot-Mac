import Darwin
import Foundation
import Security

/// Ephemeral, loopback-only credentials for the official sing-box 1.14 API.
/// The value exists only for a running core session and is never persisted.
public struct LocalAPIEndpoint: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let secret: String

    public init(host: String = "127.0.0.1", port: Int, secret: String) {
        self.host = host
        self.port = port
        self.secret = secret
    }

    public static func make() throws -> LocalAPIEndpoint {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NekoPilotError.processFailed("无法生成 sing-box API 会话密钥")
        }
        return LocalAPIEndpoint(port: try availableLoopbackPort(), secret: Data(bytes).base64EncodedString())
    }

    private static func availableLoopbackPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NekoPilotError.processFailed("无法分配 sing-box API 端口") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw NekoPilotError.processFailed("无法绑定 sing-box API 端口") }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let fetched = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard fetched == 0 else { throw NekoPilotError.processFailed("无法读取 sing-box API 端口") }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }
}

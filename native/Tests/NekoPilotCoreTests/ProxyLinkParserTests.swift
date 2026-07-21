import Foundation
import Testing
@testable import NekoPilotCore

@Suite("Proxy link parser")
struct ProxyLinkParserTests {
    @Test("VLESS normalizes TLS and transport fields")
    func vlessNormalizesTLSAndTransportFields() throws {
        let outbound = try firstOutbound(
            "vless://uuid@example.com:443?security=tls&sni=%20%20&alpn=h2,%20http/1.1,%20&type=ws&path=&host=%20cdn.example.com%20&packetEncoding=xudp#%20Tokyo%20"
        )

        #expect(outbound["tag"]?.stringValue == "VLESS · Tokyo")
        #expect(outbound["packet_encoding"]?.stringValue == "xudp")
        let tls = try #require(outbound["tls"]?.objectValue)
        #expect(tls["server_name"]?.stringValue == "example.com")
        #expect(tls["alpn"]?.arrayValue?.compactMap(\.stringValue) == ["h2", "http/1.1"])
        let transport = try #require(outbound["transport"]?.objectValue)
        #expect(transport["path"]?.stringValue == "/")
        #expect(transport["headers"]?["Host"]?.stringValue == "cdn.example.com")
    }

    @Test("VLESS rejects invalid ports", arguments: [0, 65_536])
    func vlessRejectsInvalidPorts(_ port: Int) {
        #expect(throws: (any Error).self) {
            try ProxyLinkParser.parse("vless://uuid@example.com:\(port)")
        }
    }

    @Test("VMess maps TLS and WebSocket options")
    func vmessMapsTLSAndWebSocketOptions() throws {
        let payload: [String: Any] = [
            "add": "example.com",
            "port": "443",
            "id": "uuid",
            "ps": " VMess ",
            "net": "ws",
            "path": "",
            "host": "cdn.example.com",
            "sni": "edge.example.com",
            "tls": "tls",
            "fp": "chrome",
            "alpn": "h2,http/1.1",
            "allowInsecure": 1,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let encoded = data.base64EncodedString().replacingOccurrences(of: "=", with: "")
        let outbound = try firstOutbound("vmess://\(encoded)")

        #expect(outbound["tag"]?.stringValue == "VMESS · VMess")
        let tls = try #require(outbound["tls"]?.objectValue)
        #expect(tls["server_name"]?.stringValue == "edge.example.com")
        #expect(tls["insecure"]?.boolValue == true)
        #expect(tls["alpn"]?.arrayValue?.compactMap(\.stringValue) == ["h2", "http/1.1"])
        #expect(tls["utls"]?["fingerprint"]?.stringValue == "chrome")
        #expect(outbound["transport"]?["path"]?.stringValue == "/")
    }

    @Test("Plaintext Shadowsocks credentials are accepted")
    func plaintextShadowsocksCredentialsAreAccepted() throws {
        let outbound = try firstOutbound("ss://aes-128-gcm:secret@example.com:8388#Home")
        #expect(outbound["method"]?.stringValue == "aes-128-gcm")
        #expect(outbound["password"]?.stringValue == "secret")
        #expect(outbound["server_port"]?.numberValue == 8_388)
    }

    @Test("Malformed Base64 is rejected")
    func malformedBase64IsRejected() {
        #expect(throws: (any Error).self) {
            try ProxyLinkParser.parse("vmess://not+valid%%")
        }
    }

    private func firstOutbound(_ link: String) throws -> [String: JSONValue] {
        let config = try ProxyLinkParser.parse(link)
        return try #require(config["outbounds"]?.arrayValue?.first?.objectValue)
    }
}

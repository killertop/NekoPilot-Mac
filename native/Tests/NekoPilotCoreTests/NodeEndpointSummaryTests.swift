import Testing
@testable import NekoPilotCore

@Suite("Node endpoint presentation boundary")
struct NodeEndpointSummaryTests {
    @Test("TLS endpoint exposes only typed presentation fields")
    func tlsEndpoint() {
        let outbound: [String: JSONValue] = [
            "type": .string("trojan"),
            "server": .string("tls.example.com"),
            "server_port": .number(443),
            "password": .string("core-only-secret"),
            "tls": .object([
                "enabled": .bool(true),
                "server_name": .string("edge.example.com"),
            ]),
        ]

        let node = node(outbound: outbound)

        #expect(node.endpointSummary.server == "tls.example.com")
        #expect(node.endpointSummary.port == 443)
        #expect(node.endpointSummary.security == .tls)
        #expect(node.endpointSummary.sni == "edge.example.com")
        #expect(node.outbound == outbound)
    }

    @Test("Reality endpoint is distinguished from standard TLS")
    func realityEndpoint() {
        let node = node(outbound: [
            "server": .string("reality.example.com"),
            "server_port": .number(8443),
            "tls": .object([
                "enabled": .bool(true),
                "server_name": .string("www.example.com"),
                "reality": .object([
                    "public_key": .string("core-only-public-key"),
                ]),
            ]),
        ])

        #expect(node.endpointSummary.server == "reality.example.com")
        #expect(node.endpointSummary.port == 8443)
        #expect(node.endpointSummary.security == .reality)
        #expect(node.endpointSummary.sni == "www.example.com")
    }

    @Test("Plain endpoint reports no transport security or SNI")
    func plainEndpoint() {
        let node = node(outbound: [
            "server": .string("plain.example.com"),
            "server_port": .number(1080),
        ])

        #expect(node.endpointSummary.server == "plain.example.com")
        #expect(node.endpointSummary.port == 1080)
        #expect(node.endpointSummary.security == .none)
        #expect(node.endpointSummary.sni == nil)
    }

    private func node(outbound: [String: JSONValue]) -> ProxyNode {
        ProxyNode(
            sourceIdentifier: "source",
            sourceName: "Source",
            originalTag: "Node",
            runtimeTag: "@np:source:Node",
            protocolName: "vless",
            outbound: outbound
        )
    }
}

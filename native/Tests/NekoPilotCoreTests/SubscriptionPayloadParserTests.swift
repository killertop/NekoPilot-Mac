import Foundation
import Testing
@testable import NekoPilotCore

@Suite("Subscription payload parser")
struct SubscriptionPayloadParserTests {
    @Test("Parses a sing-box JSON payload without importer state")
    func parsesJSONPayload() throws {
        let data = try JSONValue.encodeObject(configuration([
            endpoint(tag: "json-node", server: "json.example", port: 443),
        ]))

        let parsed = try SubscriptionPayloadParser.parse(data)

        #expect(parsed["outbounds"]?.arrayValue?.first?["tag"]?.stringValue == "json-node")
    }

    @Test("Parses base64 links and makes duplicate tags deterministic")
    func parsesBase64LinksWithDuplicateTags() throws {
        let link = "vless://00000000-0000-0000-0000-000000000001@example.com:443?security=tls#Same"
        let encoded = Data("\(link)\n\(link)".utf8).base64EncodedData()

        let parsed = try SubscriptionPayloadParser.parse(encoded)
        let tags = parsed["outbounds"]?.arrayValue?.compactMap { $0["tag"]?.stringValue }

        #expect(tags == ["VLESS · Same", "VLESS · Same (2)"])
    }

    @Test("Direct structural validation rejects a subscription with no usable node")
    func rejectsPayloadWithoutUsableNode() {
        let selectorOnly = configuration([
            .object([
                "type": .string("selector"),
                "tag": .string("proxy"),
                "outbounds": .array([]),
            ]),
        ])

        #expect(throws: NekoPilotError.invalidSubscription) {
            try SubscriptionPayloadParser.validate(selectorOnly)
        }
    }

    private func configuration(_ outbounds: [JSONValue]) -> [String: JSONValue] {
        ["outbounds": .array(outbounds)]
    }

    private func endpoint(tag: String, server: String, port: Double) -> JSONValue {
        .object([
            "type": .string("vless"),
            "tag": .string(tag),
            "server": .string(server),
            "server_port": .number(port),
            "uuid": .string("uuid"),
        ])
    }
}

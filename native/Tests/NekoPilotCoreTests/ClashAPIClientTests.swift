import Testing
@testable import NekoPilotCore

@Suite("Clash API client")
struct ClashAPIClientTests {
    @Test("Default probe uses the macOS-verified lightweight 204 endpoint")
    func defaultProbeBaseline() {
        #expect(URLTester.testURL == "https://www.gstatic.com/generate_204")
        #expect(URLTester.timeoutMilliseconds == 3_000)
    }

    @Test("Delay endpoint encodes node as one path segment")
    func delayEndpointEncodesNodeAsSinglePathSegment() throws {
        let path = try #require(ClashAPIClient.delayRequestPath(
            node: "@np:source:HK/US 节点",
            testURL: "https://example.com/generate_204?x=1&y=2",
            timeoutMilliseconds: 5_000
        ))

        #expect(path.hasPrefix("/proxies/%40np%3Asource%3AHK%2FUS%20"))
        #expect(!path.contains("HK/US"))
        #expect(path.contains("/delay?"))
        #expect(path.contains("timeout=5000"))
    }
}

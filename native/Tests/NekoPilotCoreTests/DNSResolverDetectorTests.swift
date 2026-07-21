import Testing
@testable import NekoPilotCore

@Suite("macOS DNS resolver detection")
struct DNSResolverDetectorTests {
    @Test("Resolver parser preserves macOS order and removes duplicates")
    func parsesScutilResolverOrder() {
        let output = """
        DNS configuration

        resolver #1
          nameserver[0] : 192.168.1.1
          nameserver[1] : 2606:4700:4700::1111%en0
        resolver #2
          nameserver[0] : 192.168.1.1
        resolver #3
          nameserver[0] : 224.0.0.251
        """

        #expect(DNSResolverDetector.parseResolvers(from: output) == [
            "192.168.1.1", "2606:4700:4700::1111",
        ])
    }

    @Test("Invalid, unspecified, and multicast resolvers are rejected")
    func rejectsUnusableResolvers() {
        #expect(!DNSResolverDetector.isUsableIPAddress(""))
        #expect(!DNSResolverDetector.isUsableIPAddress("0.0.0.0"))
        #expect(!DNSResolverDetector.isUsableIPAddress("224.0.0.251"))
        #expect(!DNSResolverDetector.isUsableIPAddress("::"))
        #expect(!DNSResolverDetector.isUsableIPAddress("ff02::fb"))
        #expect(DNSResolverDetector.isUsableIPAddress("1.1.1.1"))
        #expect(DNSResolverDetector.isUsableIPAddress("2606:4700:4700::1111"))
    }
}

@testable import NekoPilotCore
import Testing

@Suite("Log redaction")
struct AppLoggerTests {
    @Test("Proxy credentials and subscription tokens never reach persistent logs")
    func sensitiveValuesAreRedacted() {
        let input = """
        failed vless://user-secret@example.com:443?token=airport-secret#node \
        authorization=Bearer bearer-secret password=hunter2 \
        uuid=01234567-89ab-4def-8123-456789abcdef \
        https://example.com/sub?token=0123456789abcdef0123456789abcdef
        """

        let output = AppLogger.redacted(input)

        #expect(!output.contains("user-secret"))
        #expect(!output.contains("airport-secret"))
        #expect(!output.contains("bearer-secret"))
        #expect(!output.contains("hunter2"))
        #expect(!output.contains("01234567-89ab-4def-8123-456789abcdef"))
        #expect(!output.contains("0123456789abcdef0123456789abcdef"))
        #expect(output.contains("<redacted-proxy-link>"))
        #expect(output.contains("token=<redacted>"))
    }
}

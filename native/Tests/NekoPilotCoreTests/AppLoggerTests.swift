@testable import NekoPilotCore
import Testing

import Foundation

@Suite("Log redaction", .serialized)
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

    @Test("Independent logger instances never share destinations")
    func loggerInstancesAreIsolated() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Logger-Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let firstURL = directory.appendingPathComponent("first.log")
        let secondURL = directory.appendingPathComponent("second.log")
        let first = AppLogger()
        let second = AppLogger()
        first.configure(destination: firstURL)
        second.configure(destination: secondURL)

        first.info("first-only")
        second.warning("second-only")

        let firstLog = try String(contentsOf: firstURL, encoding: .utf8)
        let secondLog = try String(contentsOf: secondURL, encoding: .utf8)
        #expect(firstLog.contains("first-only"))
        #expect(!firstLog.contains("second-only"))
        #expect(secondLog.contains("second-only"))
        #expect(!secondLog.contains("first-only"))
    }
}

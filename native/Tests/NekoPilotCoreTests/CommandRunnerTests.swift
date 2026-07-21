import Foundation
import Testing
@testable import NekoPilotCore

@Suite("External command lifecycle")
struct CommandRunnerTests {
    @Test("A short command reaches EOF and returns its output")
    func shortCommandCompletes() async throws {
        let result = try await CommandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["NekoPilot"],
            timeout: 2
        )

        #expect(result.status == 0)
        #expect(result.output == "NekoPilot")
        #expect(result.errorOutput.isEmpty)
    }
}

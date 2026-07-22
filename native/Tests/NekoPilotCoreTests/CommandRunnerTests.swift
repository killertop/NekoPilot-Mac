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

    @Test("A timed out command returns without waiting for Foundation process reaping")
    func timedOutCommandReturnsPromptly() async {
        let startedAt = Date()
        do {
            _ = try await CommandRunner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: 0.05
            )
            Issue.record("Expected the sleeping command to time out")
        } catch {
            #expect(Date().timeIntervalSince(startedAt) < 1)
        }
    }

    @Test("Repeated timeouts leave active pipe readers to finish at EOF")
    func repeatedTimeoutsDoNotRacePipeReaders() async {
        let startedAt = Date()
        for _ in 0 ..< 12 {
            do {
                _ = try await CommandRunner.run(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "printf stdout; printf stderr >&2; exec /bin/sleep 5"],
                    timeout: 0.02
                )
                Issue.record("Expected the sleeping command to time out")
            } catch {
                // Returning an ordinary Swift error is the expected timeout
                // path. An unsafe concurrent FileHandle close aborts the test
                // process instead, so completing every iteration is the
                // regression assertion.
            }
        }
        #expect(Date().timeIntervalSince(startedAt) < 4)
    }
}

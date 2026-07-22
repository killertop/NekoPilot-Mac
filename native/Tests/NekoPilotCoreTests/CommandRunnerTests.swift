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

    @Test("Caller cancellation remains CancellationError")
    func callerCancellationIsPreserved() async {
        let task = Task {
            try await CommandRunner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: 10
            )
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        let startedAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(Date().timeIntervalSince(startedAt) < 1)
        } catch {
            Issue.record("Expected CancellationError, received \(error)")
        }
    }

    @Test("Inherited pipe writers are covered by the command timeout")
    func inheritedWriterCannotExtendTimeout() async {
        let startedAt = Date()
        do {
            _ = try await CommandRunner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "(trap '' TERM; sleep 5) & printf parent-exited"],
                timeout: 0.1
            )
            Issue.record("Expected inherited writer to time out")
        } catch {
            #expect(!(error is CancellationError))
            #expect(Date().timeIntervalSince(startedAt) < 1)
        }
    }

    @Test("A concurrent command does not inherit another command's pipe writers")
    func concurrentSpawnDoesNotInheritPipeWriters() async throws {
        for index in 0 ..< 12 {
            let quickTask = Task {
                try await CommandRunner.run(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "sleep 0.03; printf quick-\(index)"],
                    timeout: 0.5
                )
            }
            let longTask = Task {
                try await CommandRunner.run(
                    executable: URL(fileURLWithPath: "/bin/sleep"),
                    arguments: ["5"],
                    timeout: 5
                )
            }

            let result: CommandResult
            do {
                result = try await quickTask.value
            } catch {
                longTask.cancel()
                _ = try? await longTask.value
                throw error
            }
            longTask.cancel()
            _ = try? await longTask.value
            #expect(result.status == 0)
            #expect(result.output == "quick-\(index)")
        }
    }
}

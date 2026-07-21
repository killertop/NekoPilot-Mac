import Foundation

public enum SingBoxValidator {
    public static func validate(configuration: URL) async throws {
        let result = try await CommandRunner.run(
            executable: SingBoxLocator.executable(),
            arguments: ["check", "-c", configuration.path, "--disable-color"],
            timeout: 20
        )
        guard result.status == 0 else {
            throw NekoPilotError.processFailed(
                (result.errorOutput.isEmpty ? result.output : result.errorOutput)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}

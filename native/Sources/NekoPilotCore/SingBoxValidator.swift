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

    /// Validate an external binary asset using the exact embedded sing-box
    /// version before it is atomically promoted into the active rule-set path.
    public static func validate(ruleSet: URL, tag: String) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-RuleSet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = directory.appendingPathComponent("validate.json")
        let payload: [String: Any] = [
            "route": [
                "rule_set": [[
                    "tag": tag,
                    "type": "local",
                    "format": "binary",
                    "path": ruleSet.path,
                ]],
                "rules": [["rule_set": [tag], "outbound": "direct"]],
            ],
            "outbounds": [["tag": "direct", "type": "direct"]],
        ]
        try AtomicFile.write(JSONSerialization.data(withJSONObject: payload), to: configuration)
        try await validate(configuration: configuration)
    }
}

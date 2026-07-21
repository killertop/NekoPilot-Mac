import Foundation

public enum SingBoxLocator {
    public static func executable() throws -> URL {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["NEKOPILOT_SING_BOX"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("sing-box"))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("sing-box"))
        }
        let current = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        candidates.append(current.appendingPathComponent("src-tauri/binaries/sing-box-aarch64-apple-darwin"))
        candidates.append(current.appendingPathComponent("../src-tauri/binaries/sing-box-aarch64-apple-darwin"))
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate.standardizedFileURL
        }
        throw NekoPilotError.singBoxMissing
    }
}

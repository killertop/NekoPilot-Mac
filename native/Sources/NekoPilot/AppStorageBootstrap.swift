import Foundation
import NekoPilotCore

/// Composition-root storage setup and safe-mode recovery. Keeping filesystem
/// recovery out of AppModel leaves the view model responsible for observable
/// application state rather than constructing persistence fallbacks.
struct AppStorageBootstrap {
    let paths: AppPaths
    let settings: SettingsStore
    let repository: SubscriptionRepository
    let isPersistent: Bool
    let recoveryMessage: String?

    static func resolve() throws -> AppStorageBootstrap {
        do {
            let paths = try AppPaths.live()
            do {
                return AppStorageBootstrap(
                    paths: paths,
                    settings: try SettingsStore(fileURL: paths.settings),
                    repository: try SubscriptionRepository(databaseURL: paths.database),
                    isPersistent: true,
                    recoveryMessage: nil
                )
            } catch {
                return try recovery(
                    message: L10n.text(
                        "本地数据无法读取，应用已进入安全恢复模式；原文件没有被覆盖。\n\(error.localizedDescription)",
                        "Local data could not be read. NekoPilot opened in safe recovery mode without overwriting the original files.\n\(error.localizedDescription)"
                    )
                )
            }
        } catch {
            return try recovery(
                message: L10n.text(
                    "无法访问应用数据目录，连接功能已停用。\n\(error.localizedDescription)",
                    "The application data directory is unavailable, so connection features are disabled.\n\(error.localizedDescription)"
                )
            )
        }
    }

    private static func recovery(message: String) throws -> AppStorageBootstrap {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Recovery-\(UUID().uuidString)", isDirectory: true)
        let paths = AppPaths(applicationSupport: root, logs: root.appendingPathComponent("logs", isDirectory: true))
        try FileManager.default.createDirectory(at: paths.applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        return AppStorageBootstrap(
            paths: paths,
            settings: try SettingsStore(fileURL: paths.settings),
            repository: try SubscriptionRepository(databaseURL: paths.database),
            isPersistent: false,
            recoveryMessage: message
        )
    }
}

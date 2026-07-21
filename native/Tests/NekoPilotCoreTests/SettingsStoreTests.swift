import Foundation
import Testing
@testable import NekoPilotCore

@Suite("Settings store", .serialized)
struct SettingsStoreTests {
    @Test("Legacy delay history migrates once and is removed from preferences")
    func legacyDelayHistoryMigratesOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Settings-Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("preferences.json")
        let settings = try SettingsStore(fileURL: file)
        let record = DelayRecord(delay: 73, measuredAt: Date(timeIntervalSince1970: 1_234))

        try await settings.replaceDelayHistory(["node": record])
        let migrated = try await settings.takeLegacyDelayHistory()
        #expect(migrated["node"] == record)

        let reopened = try SettingsStore(fileURL: file)
        #expect(await reopened.delayHistory().isEmpty)
        #expect(try await reopened.takeLegacyDelayHistory().isEmpty)
    }
}

import Foundation
import Testing
@testable import NekoPilotCore

@Suite("Node location probe")
struct NodeLocationProbeTests {
    @Test("Worker budget stays low for small and large node sets")
    func workerBudget() {
        #expect(NodeLocationProbe.workerCount(for: 0) == 0)
        #expect(NodeLocationProbe.workerCount(for: 1) == 1)
        #expect(NodeLocationProbe.workerCount(for: 12) == 1)
        #expect(NodeLocationProbe.workerCount(for: 13) == 2)
        #expect(NodeLocationProbe.workerCount(for: 500) == 2)
    }

    @Test("Trace parser accepts only ISO alpha-2 country codes")
    func traceParser() {
        #expect(parse("fl=1\nip=203.0.113.1\nloc=US\ncolo=SJC\n") == "US")
        #expect(parse("loc=jp\r\n") == "JP")
        #expect(parse("loc=XX\n") == nil)
        #expect(parse("loc=T1\n") == nil)
        #expect(parse("loc=A1\n") == nil)
        #expect(parse("loc=A2\n") == nil)
        #expect(parse("loc=ZZ\n") == nil)
        #expect(parse("loc=USA\n") == nil)
        #expect(parse("loc=US=unexpected\n") == nil)
        #expect(parse("country=US\n") == nil)
        #expect(NodeLocationProbe.parseCountryCode(from: Data([0xFF, 0xFE])) == nil)
    }

    @Test("Trace parser rejects responses over eight KiB")
    func responseLimit() {
        var response = Data("loc=US\n".utf8)
        response.append(Data(repeating: 0x20, count: NodeLocationProbe.maximumResponseBytes))
        #expect(NodeLocationProbe.parseCountryCode(from: response) == nil)
    }

    @Test("Abandoned credential directories are removed without touching recent work")
    func abandonedWorkerCleanup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Location-Cleanup-Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = root.appendingPathComponent("NekoPilot-LocationProbe-stale", isDirectory: true)
        let recent = root.appendingPathComponent("NekoPilot-LocationProbe-recent", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-11 * 60)],
            ofItemAtPath: stale.path
        )

        await NodeLocationProbe.recoverAbandonedWorkers(in: root)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
    }

    private func parse(_ value: String) -> String? {
        NodeLocationProbe.parseCountryCode(from: Data(value.utf8))
    }
}

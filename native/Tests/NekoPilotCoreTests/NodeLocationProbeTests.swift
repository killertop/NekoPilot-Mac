import Darwin
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

    @Test("Worker starts only after its ownership marker is committed")
    func ownershipMarkerGatesWorkerStart() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = directory.appendingPathComponent("worker-started")
        var markerWasWritten = false

        let process = try NodeLocationProbe.launchOwnedWorker(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf started > \"$1\"", "worker", sentinel.path],
            directory: directory,
            ownershipWriter: { process, _, _, _ in
                #expect(getpgid(process.pid) == process.pid)
                #expect(!FileManager.default.fileExists(atPath: sentinel.path))
                markerWasWritten = true
            }
        )
        process.waitUntilExit()

        #expect(markerWasWritten)
        #expect((try? String(contentsOf: sentinel, encoding: .utf8)) == "started")
    }

    @Test("Marker write failure stops the launcher without starting the worker")
    func ownershipMarkerFailureStopsWorker() throws {
        struct MarkerWriteFailure: Error {}

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = directory.appendingPathComponent("worker-started")
        var launcherPID: Int32?
        var didThrow = false

        do {
            _ = try NodeLocationProbe.launchOwnedWorker(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf started > \"$1\"", "worker", sentinel.path],
                directory: directory,
                ownershipWriter: { process, _, _, _ in
                    launcherPID = process.processIdentifier
                    #expect(getpgid(process.pid) == process.pid)
                    throw MarkerWriteFailure()
                }
            )
        } catch is MarkerWriteFailure {
            didThrow = true
        }

        #expect(didThrow)
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
        if let launcherPID {
            #expect(ProcessIdentity.record(pid: launcherPID) == nil)
        }
    }

    @Test("Launcher exit turns the gate write into an error without SIGPIPE")
    func launcherExitDoesNotRaiseSIGPIPE() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var didThrow = false

        do {
            _ = try NodeLocationProbe.launchOwnedWorker(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                directory: directory,
                ownershipWriter: { process, _, _, _ in
                    process.stop()
                }
            )
        } catch {
            didThrow = true
        }

        #expect(didThrow)
    }

    @Test("Worker stop kills its owned group and reaps the leader")
    func workerStopReapsOwnedGroup() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = try NodeLocationProbe.launchOwnedWorker(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            directory: directory,
            ownershipWriter: { process, _, _, _ in
                #expect(getpgid(process.pid) == process.pid)
            }
        )
        let pid = process.pid
        #expect(process.isRunning)

        process.stop()

        #expect(!process.isRunning)
        var rawStatus: Int32 = 0
        errno = 0
        #expect(waitpid(pid, &rawStatus, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }

    @Test("Guardian remains identifiable and cleans descendants after worker exit")
    func guardianCleansGroupAfterWorkerExit() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let descendantPIDFile = directory.appendingPathComponent("descendant-pid")
        let releaseWorkerFile = directory.appendingPathComponent("release-worker")
        let process = try NodeLocationProbe.launchOwnedWorker(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                "-c",
                "/bin/sh -c 'trap \"\" TERM; while :; do sleep 1; done' & " +
                    "printf '%d' \"$!\" > \"$1\"; " +
                    "while [ ! -f \"$2\" ]; do sleep 0.01; done; exit 0",
                "worker",
                descendantPIDFile.path,
                releaseWorkerFile.path,
            ],
            directory: directory,
            ownershipWriter: { _, _, _, _ in }
        )
        defer { process.stop() }
        let descendantPID = try #require(waitForPID(at: descendantPIDFile))
        let descendantIdentity = try #require(ProcessIdentity.record(pid: descendantPID))
        let marker = LocationWorkerOwnership(
            ownerProcess: nil,
            childProcess: process.launchIdentity,
            expectedExecutablePath: "/bin/bash",
            ownsProcessGroup: true
        )

        #expect(process.isRunning)
        #expect(NodeLocationProbe.workerIdentityMatches(marker))
        #expect(NodeLocationProbe.processGroupExists(pid: process.pid))

        try Data().write(to: releaseWorkerFile)
        for _ in 0 ..< 100 where process.isRunning { usleep(10_000) }
        for _ in 0 ..< 100 where ProcessIdentity.matches(descendantIdentity) { usleep(10_000) }

        #expect(!process.isRunning)
        #expect(!ProcessIdentity.matches(descendantIdentity))
        process.waitUntilExit()
        var rawStatus: Int32 = 0
        errno = 0
        #expect(waitpid(process.pid, &rawStatus, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }

    @Test("Recovery escalates when a descendant survives TERM")
    func recoveryStopsMarkedOrphanGroup() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(
            "NekoPilot-LocationProbe-orphan",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descendantPIDFile = directory.appendingPathComponent("descendant-pid")
        let process = try NodeLocationProbe.launchOwnedWorker(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                "-c",
                "trap '' TERM; " +
                    "/bin/sh -c 'trap \"\" TERM; while :; do sleep 1; done' & " +
                    "printf '%d' \"$!\" > \"$1\"; wait",
                "worker",
                descendantPIDFile.path,
            ],
            directory: directory,
            ownershipWriter: { process, _, executable, directory in
                let marker = LocationWorkerOwnership(
                    ownerProcess: nil,
                    childProcess: process.launchIdentity,
                    expectedExecutablePath: executable.path,
                    ownsProcessGroup: true
                )
                try JSONEncoder().encode(marker).write(
                    to: directory.appendingPathComponent(LocationWorkerOwnership.filename)
                )
            }
        )
        defer { process.stop() }
        let descendantPID = try #require(waitForPID(at: descendantPIDFile))
        let descendantIdentity = try #require(ProcessIdentity.record(pid: descendantPID))
        let markerData = try Data(
            contentsOf: directory.appendingPathComponent(LocationWorkerOwnership.filename)
        )
        let marker = try JSONDecoder().decode(LocationWorkerOwnership.self, from: markerData)

        #expect(process.isRunning)
        #expect(NodeLocationProbe.workerIdentityMatches(marker))

        await NodeLocationProbe.recoverAbandonedWorkers(in: root)
        for _ in 0 ..< 100 where process.isRunning {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        for _ in 0 ..< 100 where ProcessIdentity.matches(descendantIdentity) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(!process.isRunning)
        #expect(!ProcessIdentity.matches(descendantIdentity))
        // This test still owns the exited leader, so its zombie keeps the
        // PGID alive. Recovery must retain credentials until that group is
        // genuinely gone rather than treating leader exit as group exit.
        #expect(FileManager.default.fileExists(atPath: directory.path))

        process.stop()
        await NodeLocationProbe.recoverAbandonedWorkers(in: root)

        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("Recovery does not kill a live process with a mismatched identity")
    func recoveryRejectsReusedProcessIdentity() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(
            "NekoPilot-LocationProbe-forged",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["5"]
        try unrelated.run()
        defer {
            if unrelated.isRunning { unrelated.terminate() }
            unrelated.waitUntilExit()
        }
        let actual = try #require(ProcessIdentity.record(
            pid: unrelated.processIdentifier,
            expectedExecutablePath: "/bin/sleep"
        ))
        let reusedIdentity = ProcessIdentityRecord(
            pid: actual.pid,
            executablePath: actual.executablePath,
            startSeconds: actual.startSeconds + 1,
            startMicroseconds: actual.startMicroseconds
        )
        let marker = LocationWorkerOwnership(
            ownerProcess: nil,
            childProcess: reusedIdentity,
            expectedExecutablePath: "/bin/sleep",
            ownsProcessGroup: false
        )
        try JSONEncoder().encode(marker).write(
            to: directory.appendingPathComponent(LocationWorkerOwnership.filename)
        )

        await NodeLocationProbe.recoverAbandonedWorkers(in: root)

        #expect(unrelated.isRunning)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    private func parse(_ value: String) -> String? {
        NodeLocationProbe.parseCountryCode(from: Data(value.utf8))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-Location-Test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func waitForPID(at url: URL) -> Int32? {
        for _ in 0 ..< 100 {
            if let value = try? String(contentsOf: url, encoding: .utf8),
               let pid = Int32(value) {
                return pid
            }
            usleep(10_000)
        }
        return nil
    }
}
